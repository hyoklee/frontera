#!/bin/bash
#SBATCH -J miv-construct
#SBATCH -p normal
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 04:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/construct-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/construct-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Generate the MiV Microcircuit_Small case-6 input dataset by reproducing the
# case-1 construction pipeline inside the miv-stack container, writing large
# HDF5 to /scratch2. Produces (under $WORKDIR/datasets/):
#   MiV_Small_h5types.h5, Microcircuit_Small_coords.h5, {PYR,PVBC,OLM}_forest_Small.h5,
#   Microcircuit_Small_connections.h5, input features/spikes, and the assembled
#   MiV_Cells_Microcircuit_Small_20220410.h5 + MiV_Connections_..._20220410.h5,
#   then stages them into datasets/Microcircuit_Small/ for case 6.

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
CASE1=/work2/11623/hyoklee/Miv-Simulator-Cases/1-construction
WORKDIR=/scratch2/11623/hyoklee/miv-case6

# Fresh working dir every run: make-h5types and friends refuse to overwrite
# committed datatypes / existing datasets left by a prior partial run.
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/datasets" "$WORKDIR/morphology"

# Stage config/templates/mechanisms + SWC morphologies into the scratch workdir.
cp -r "$CASE1/config" "$WORKDIR/"
cp -r "$CASE1/templates" "$WORKDIR/"
cp -r "$CASE1/mechanisms" "$WORKDIR/"
cp "$CASE1"/datasets/*.swc "$WORKDIR/morphology/"

# The whole pipeline runs inside the container from $WORKDIR.
apptainer exec --cleanenv --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    --bind /scratch2/11623/hyoklee:/scratch2/11623/hyoklee \
    "$SIF" bash -c '
set -e
. /opt/miv-venv/bin/activate
export PATH=/opt/hdf5/bin:/opt/neuroh5/bin:$PATH
export LD_LIBRARY_PATH=/opt/hdf5/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1
export NEUROH5_CHUNK_SIZE=1073741824
cd '"$WORKDIR"'

# neuroh5 C++ tools were built in-source into the read-only SIF and may lack a
# usable exec bit there; stage them to the (executable) scratch workdir.
mkdir -p tools
cp /opt/neuroh5/bin/* tools/ 2>/dev/null || true
chmod +x tools/* 2>/dev/null || true
ls -la /opt/neuroh5/bin/neurotrees_import tools/neurotrees_import

# NOTE: do NOT pre-run `nrnivmodl mechanisms` here. MiV@vista-arm-fix compiles
# and loads mechanisms itself (compile_and_load); a cwd ./x86_64 from a manual
# nrnivmodl gets auto-loaded by NEURON too, causing a double-load
# ("user defined name already exists: Gfluct3").

echo "===== [2] make-h5types ====="
make-h5types --config-prefix config -c Microcircuit_Small.yaml \
    --output-path datasets/MiV_Small_h5types.h5

echo "===== [3] generate-soma-coordinates ====="
generate-soma-coordinates -v --config=Microcircuit_Small.yaml --config-prefix=config \
    --types-path=datasets/MiV_Small_h5types.h5 \
    --output-path=datasets/Microcircuit_Small_coords.h5 \
    --output-namespace="Generated Coordinates"

echo "===== [3b] measure-distances (writes Arc Distances namespace) ====="
# Required: generate-distance-connections reads soma Arc Distances from here.
mpirun -np 1 measure-distances -v -i PYR -i PVBC -i OLM -i STIM \
    --config=Microcircuit_Small.yaml --config-prefix=config \
    --coords-path=datasets/Microcircuit_Small_coords.h5

NT=$PWD/tools; H5=/opt/hdf5/bin
echo "===== [4] neurotrees_import (SWC -> trees) + H5Types ====="
$NT/neurotrees_import PVBC datasets/PVBC_tree.h5 morphology/PVBC.swc
$NT/neurotrees_import PYR  datasets/PYR_tree.h5  morphology/PYR.swc
$NT/neurotrees_import OLM  datasets/OLM_tree.h5  morphology/OLM.swc
for P in PVBC PYR OLM; do
    $H5/h5copy -p -s "/H5Types" -d "/H5Types" -i datasets/MiV_Small_h5types.h5 -o datasets/${P}_tree.h5
done

echo "===== [5] neurotrees_copy --fill (replicate to forest) ====="
$NT/neurotrees_copy --fill --output datasets/PYR_forest_Small.h5  datasets/PYR_tree.h5  PYR 10
$NT/neurotrees_copy --fill --output datasets/PVBC_forest_Small.h5 datasets/PVBC_tree.h5 PVBC 90
$NT/neurotrees_copy --fill --output datasets/OLM_forest_Small.h5  datasets/OLM_tree.h5  OLM 143

echo "===== [6] distribute-synapse-locs (per population) ====="
for P in PYR PVBC OLM; do
    mpirun -np 1 distribute-synapse-locs --template-path templates \
        --config=Microcircuit_Small.yaml --config-prefix=config \
        --populations $P --forest-path=./datasets/${P}_forest_Small.h5 \
        --output-path=./datasets/${P}_forest_Small.h5 \
        --distribution=poisson --io-size=1 --write-size=0 -v
done

echo "===== [7] generate-distance-connections ====="
for P in PYR PVBC OLM; do
    mpirun -np 4 generate-distance-connections \
        --config=Microcircuit_Small.yaml --config-prefix=config \
        --forest-path=datasets/${P}_forest_Small.h5 \
        --connectivity-path=datasets/Microcircuit_Small_connections.h5 \
        --connectivity-namespace=Connections \
        --coords-path=datasets/Microcircuit_Small_coords.h5 \
        --coords-namespace="Generated Coordinates" \
        --io-size=1 --cache-size=20 --write-size=100 -v
done

echo "===== [8] input features + spike trains (STIM) ====="
mpirun -np 1 generate-input-features -p STIM \
    --config=Microcircuit_Small.yaml --config-prefix=config \
    --coords-path=datasets/Microcircuit_Small_coords.h5 \
    --output-path=datasets/Microcircuit_Small_input_features.h5 -v
mpirun -np 2 generate-input-spike-trains \
    --config=Microcircuit_Small.yaml --config-prefix=config \
    --selectivity-path=datasets/Microcircuit_Small_input_features.h5 \
    --output-path=datasets/Microcircuit_Small_input_spikes.h5 \
    --n-trials=3 -p STIM -v

echo "===== [9] assemble combined Cells + Connections files ====="
cd datasets
python3 - <<PY
import os, h5py, pathlib
def cp(src,dst,path):
    parent=str(pathlib.Path(path).parent)
    with h5py.File(src,"r") as s, h5py.File(dst,"a") as d:
        s.copy(s[path], d[parent])
h5t="MiV_Small_h5types.h5"; cells="MiV_Cells_Microcircuit_Small_20220410.h5"
conns="MiV_Connections_Microcircuit_Small_20220410.h5"; coords="Microcircuit_Small_coords.h5"
pops=["PYR","OLM","PVBC","STIM"]
forest={"PYR":"PYR_forest_Small.h5","PVBC":"PVBC_forest_Small.h5","OLM":"OLM_forest_Small.h5"}
conn={"PYR":"Microcircuit_Small_connections.h5","PVBC":"Microcircuit_Small_connections.h5","OLM":"Microcircuit_Small_connections.h5"}
vecstim={"Input Spikes A Diag":"Microcircuit_Small_input_spikes.h5"}
# --- cells file ---
if os.path.exists(cells): os.remove(cells)
with h5py.File(cells,"w") as f, h5py.File(h5t,"r") as s: s.copy(s["/H5Types"], f["/"])
with h5py.File(cells,"a") as f:
    g=f.create_group("Populations")
    for p in pops: g.create_group(p)
for p in pops:
    cp(coords, cells, f"/Populations/{p}/Generated Coordinates")
    cp(coords, cells, f"/Populations/{p}/Arc Distances")
for p,ff in forest.items():
    os.system(f"/opt/hdf5/bin/h5copy -p -s \"/Populations/{p}/Trees\" -d \"/Populations/{p}/Trees\" -i {ff} -o {cells}")
    os.system(f"/opt/hdf5/bin/h5copy -p -s \"/Populations/{p}/Synapse Attributes\" -d \"/Populations/{p}/Synapse Attributes\" -i {ff} -o {cells}")
for ns,vf in vecstim.items():
    os.system(f"/opt/hdf5/bin/h5copy -p -s \"/Populations/STIM/{ns}\" -d \"/Populations/STIM/{ns}\" -i {vf} -o {cells}")
os.system(f"/opt/hdf5/bin/h5copy -p -s \"/Populations/STIM/Generated Coordinates\" -d \"/Populations/STIM/Coordinates\" -i {cells} -o {cells}")
# --- connections file ---
if os.path.exists(conns): os.remove(conns)
with h5py.File(conns,"w") as f, h5py.File(h5t,"r") as s: s.copy(s["/H5Types"], f["/"])
for p,cf in conn.items():
    os.system(f"/opt/hdf5/bin/h5copy -p -s \"/Projections/{p}\" -d \"/Projections/{p}\" -i {cf} -o {conns}")
print("ASSEMBLY DONE")
PY
cd ..

echo "===== [10] stage into case-6 layout datasets/Microcircuit_Small/ ====="
mkdir -p datasets/Microcircuit_Small
cp datasets/MiV_Cells_Microcircuit_Small_20220410.h5 datasets/Microcircuit_Small/
cp datasets/MiV_Connections_Microcircuit_Small_20220410.h5 datasets/Microcircuit_Small/
ls -la datasets datasets/Microcircuit_Small
echo "CONSTRUCTION_DONE"
'
echo "===== construct job finished @ $(date) ====="
