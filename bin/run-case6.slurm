#!/bin/bash
#SBATCH -J miv-case6
#SBATCH -p normal
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 02:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/case6-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/case6-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Run MiV-Simulator case 6 (6-gapjunctions) end-to-end in the miv-stack
# container, native parallel HDF5, on Frontera. 8 MPI ranks, tstop=50 (short
# validation run). Uses the dataset produced by construct-case6-data.slurm.
#
#   A) make-h5types --gap-junctions  -> MiV_h5types_gj.h5
#   B) generate-gapjunctions (8 rk)  -> MiV_gapjunctions_20230408.h5
#   C) run-network (8 rk, tstop=50)  -> results/runs/

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
CASE6=/work2/11623/hyoklee/Miv-Simulator-Cases/6-gapjunctions
CONSTRUCT=/scratch2/11623/hyoklee/miv-case6/datasets/Microcircuit_Small
RUNDIR=/scratch2/11623/hyoklee/miv-case6-run
TSTOP=${TSTOP:-50}
NRANKS=${NRANKS:-8}

# Fresh run dir: case-6 config/templates/mechanisms + the constructed cells/conns.
rm -rf "$RUNDIR"
mkdir -p "$RUNDIR/datasets/Microcircuit_Small" "$RUNDIR/results/runs"
cp -r "$CASE6/config" "$CASE6/templates" "$CASE6/mechanisms" "$RUNDIR/"
cp "$CONSTRUCT/MiV_Cells_Microcircuit_Small_20220410.h5" "$RUNDIR/datasets/Microcircuit_Small/"
cp "$CONSTRUCT/MiV_Connections_Microcircuit_Small_20220410.h5" "$RUNDIR/datasets/Microcircuit_Small/"

apptainer exec --cleanenv --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    --bind /scratch2/11623/hyoklee:/scratch2/11623/hyoklee \
    "$SIF" bash -c '
set -e
. /opt/miv-venv/bin/activate
export PATH=/opt/hdf5/bin:/opt/neuroh5/bin:$PATH
export LD_LIBRARY_PATH=/opt/hdf5/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1
export NEUROH5_CHUNK_SIZE=1073741824
cd '"$RUNDIR"'
NR='"$NRANKS"'; TS='"$TSTOP"'

echo "===== [A] make-h5types --gap-junctions @ $(date +%T) ====="
make-h5types --gap-junctions -c Microcircuit_Small.yaml --config-prefix config \
    --output-path datasets/MiV_h5types_gj.h5

echo "===== [B] generate-gapjunctions ($NR ranks) @ $(date +%T) ====="
t0=$SECONDS
mpirun -np $NR generate-gapjunctions \
    --config=./config/Microcircuit_Small.yaml \
    --types-path=./datasets/MiV_h5types_gj.h5 \
    --forest-path=./datasets/Microcircuit_Small/MiV_Cells_Microcircuit_Small_20220410.h5 \
    --connectivity-path=./datasets/Microcircuit_Small/MiV_gapjunctions_20230408.h5 \
    --connectivity-namespace="Gap Junctions" \
    --coords-path=./datasets/Microcircuit_Small/MiV_Cells_Microcircuit_Small_20220410.h5 \
    --coords-namespace="Generated Coordinates" \
    --io-size=4 -v
echo "GAPJUNCTIONS_SECONDS=$((SECONDS-t0))"

echo "===== [C] run-network ($NR ranks, tstop=$TS) @ $(date +%T) ====="
t0=$SECONDS
mpirun -n $NR run-network --verbose --arena-id A --stimulus-id Diag \
    --config-file=Microcircuit_Small.yaml --template-paths templates \
    --dt 0.01 --tstop $TS \
    --dataset-prefix ./datasets --config-prefix config \
    --results-path results/runs
echo "RUNNETWORK_SECONDS=$((SECONDS-t0))"

echo "===== results ====="; ls -la results/runs
echo "CASE6_DONE"
'
echo "===== case6 job finished @ $(date) ====="
