#!/bin/bash
#SBATCH -J probe-newsif
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:20:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/probenew-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/probenew-%j.err
# Confirm the neuroh5 fix in the rebuilt SIF: read_cell_attribute_info native
# vs clio VOL. Success = both return all 4 pops (VOL no longer empty).
set -eo pipefail
module load tacc-apptainer/1.4.1
SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
CLIO_IOWARP=/work2/11623/hyoklee/frontera/build/clio-core-iowarp
CONF=/work2/11623/hyoklee/frontera.hyoklee/bin/chimaera_case6.yaml
SRC=/scratch2/11623/hyoklee/miv-case6/datasets/Microcircuit_Small/MiV_Cells_Microcircuit_Small_20220410.h5
RUNDIR=/scratch2/11623/hyoklee/miv-probenew
rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"
cp "$SRC" "$RUNDIR/cells.h5"; cp "$CONF" "$RUNDIR/chimaera_case6.yaml"
VOL_SO=$(find "$CLIO_IOWARP" -name libclio_hdf5_vol.so 2>/dev/null | head -1)
CLIO_RUN=$(find "$CLIO_IOWARP" -name clio_run -type f 2>/dev/null | head -1)
VOL_DIR=$(dirname "$VOL_SO")

apptainer exec --cleanenv --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    --bind /scratch2/11623/hyoklee:/scratch2/11623/hyoklee "$SIF" bash -c '
set -e
. /opt/miv-venv/bin/activate
export PATH=/opt/hdf5/bin:/opt/neuroh5/bin:$PATH
export LD_LIBRARY_PATH=/opt/hdf5/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1
cd '"$RUNDIR"'
VOL_DIR='"$VOL_DIR"'; CLIO_RUN='"$CLIO_RUN"'
cat > np.py <<PY
from neuroh5.io import read_cell_attribute_info, read_population_names
pops = sorted(read_population_names("cells.h5"))
info = read_cell_attribute_info("cells.h5", pops)
print("pops =", pops, "| attr_info keys =", sorted(info.keys()), flush=True)
print("RESULT_OK" if set(pops) <= set(info.keys()) else "RESULT_EMPTY", flush=True)
PY
echo "===== NATIVE ====="; python3 np.py || echo "native rc=$?"
rm -f /dev/shm/chi_* 2>/dev/null || true
export CLIO_SERVER_CONF='"$RUNDIR"'/chimaera_case6.yaml
export LD_LIBRARY_PATH=$VOL_DIR:/opt/hdf5/lib:$LD_LIBRARY_PATH
"$CLIO_RUN" runtime start > runtime.log 2>&1 &
RTPID=$!
for i in $(seq 1 40); do
  if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/9413" 2>/dev/null; then echo "runtime up"; break; fi
  kill -0 $RTPID 2>/dev/null || { echo "RUNTIME DIED"; tail -20 runtime.log; break; }
  sleep 1
done
echo "===== VOL (clio) ====="
HDF5_PLUGIN_PATH=$VOL_DIR HDF5_VOL_CONNECTOR=clio timeout 90 python3 np.py || echo "vol rc=$?"
"$CLIO_RUN" runtime stop 2>/dev/null || kill $RTPID 2>/dev/null || true
rm -f /dev/shm/chi_* 2>/dev/null || true
echo "PROBE_DONE"
'
