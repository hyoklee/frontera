#!/bin/bash
#SBATCH -J miv-case6-vol
#SBATCH -p normal
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 02:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/case6vol-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/case6vol-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Case-6 run-network: NATIVE parallel HDF5 vs clio-core HDF5 VOL connector.
# The VOL connector (iowarp) is a passthrough that intercepts H5Dwrite/H5Dread
# -> CTE PutBlob/GetBlob (falls back to native VOL for collective MPI-IO). It is
# loaded by HDF5 itself via HDF5_VOL_CONNECTOR + HDF5_PLUGIN_PATH -- no
# LD_PRELOAD. Both arms same node, back-to-back. 8 ranks, tstop=50 (I/O phases
# created/connected are tstop-independent, so this suffices to measure I/O).

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
CASE6=/work2/11623/hyoklee/Miv-Simulator-Cases/6-gapjunctions
CONSTRUCT=/scratch2/11623/hyoklee/miv-case6/datasets/Microcircuit_Small
CLIO_IOWARP=/work2/11623/hyoklee/frontera/build/clio-core-iowarp
CONF=/work2/11623/hyoklee/frontera.hyoklee/bin/chimaera_case6.yaml
RUNDIR=/scratch2/11623/hyoklee/miv-case6-vol
TSTOP=${TSTOP:-50}
NR=${NRANKS:-8}

rm -rf "$RUNDIR"
mkdir -p "$RUNDIR/datasets/Microcircuit_Small" "$RUNDIR/results/native" "$RUNDIR/results/vol"
cp -r "$CASE6/config" "$CASE6/templates" "$CASE6/mechanisms" "$RUNDIR/"
cp "$CONSTRUCT"/MiV_Cells_Microcircuit_Small_20220410.h5 "$RUNDIR/datasets/Microcircuit_Small/"
cp "$CONSTRUCT"/MiV_Connections_Microcircuit_Small_20220410.h5 "$RUNDIR/datasets/Microcircuit_Small/"
cp "$CONF" "$RUNDIR/chimaera_case6.yaml"

VOL_SO=$(find "$CLIO_IOWARP" -name libiowarp_hdf5_vol.so 2>/dev/null | head -1)
CLIO_RUN=$(find "$CLIO_IOWARP" -name clio_run -type f 2>/dev/null | head -1)
VOL_DIR=$(dirname "$VOL_SO")
echo "VOL_SO=$VOL_SO"; echo "CLIO_RUN=$CLIO_RUN"

apptainer exec --cleanenv --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    --bind /scratch2/11623/hyoklee:/scratch2/11623/hyoklee \
    "$SIF" bash -c '
set -e
. /opt/miv-venv/bin/activate
export PATH=/opt/hdf5/bin:/opt/neuroh5/bin:$PATH
export LD_LIBRARY_PATH=/opt/hdf5/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1 NEUROH5_CHUNK_SIZE=1073741824
cd '"$RUNDIR"'
NR='"$NR"'; TS='"$TSTOP"'
VOL_DIR='"$VOL_DIR"'; CLIO_RUN='"$CLIO_RUN"'
CLEAN="rm -f /dev/shm/chi_* 2>/dev/null || true"

echo "===== make-h5types + generate-gapjunctions @ $(date +%T) ====="
make-h5types --gap-junctions -c Microcircuit_Small.yaml --config-prefix config \
    --output-path datasets/MiV_h5types_gj.h5
mpirun -np $NR generate-gapjunctions --config=./config/Microcircuit_Small.yaml \
    --types-path=./datasets/MiV_h5types_gj.h5 \
    --forest-path=./datasets/Microcircuit_Small/MiV_Cells_Microcircuit_Small_20220410.h5 \
    --connectivity-path=./datasets/Microcircuit_Small/MiV_gapjunctions_20230408.h5 \
    --connectivity-namespace="Gap Junctions" \
    --coords-path=./datasets/Microcircuit_Small/MiV_Cells_Microcircuit_Small_20220410.h5 \
    --coords-namespace="Generated Coordinates" --io-size=4 -v

runnet () {  # $1=results subdir
    mpirun -n $NR run-network --verbose --arena-id A --stimulus-id Diag \
        --config-file=Microcircuit_Small.yaml --template-paths templates \
        --dt 0.01 --tstop $TS --dataset-prefix ./datasets --config-prefix config \
        --results-path results/$1
}

# --- NATIVE ---
echo "===== NATIVE run-network @ $(date +%T) ====="
t0=$SECONDS; runnet native; echo "NATIVE_SECONDS=$((SECONDS-t0))"

# --- VOL ---
eval "$CLEAN"
echo "===== start clio_run runtime @ $(date +%T) ====="
export CLIO_SERVER_CONF='"$RUNDIR"'/chimaera_case6.yaml
export LD_LIBRARY_PATH=$VOL_DIR:/opt/hdf5/lib:$LD_LIBRARY_PATH
"$CLIO_RUN" runtime start > runtime.log 2>&1 &
RTPID=$!
for i in $(seq 1 40); do
    if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/9413" 2>/dev/null; then echo "runtime up after ${i}s"; break; fi
    kill -0 $RTPID 2>/dev/null || { echo "RUNTIME DIED"; tail -30 runtime.log; break; }
    sleep 1
done
echo "===== VOL run-network (HDF5_VOL_CONNECTOR=iowarp) @ $(date +%T) ====="
t0=$SECONDS
HDF5_PLUGIN_PATH=$VOL_DIR HDF5_VOL_CONNECTOR=iowarp \
    runnet vol || echo "VOL run-network FAILED rc=$?"
echo "VOL_SECONDS=$((SECONDS-t0))"
"$CLIO_RUN" runtime stop 2>/dev/null || kill $RTPID 2>/dev/null || true
eval "$CLEAN"

echo "===== results ====="; ls -la results/native results/vol 2>/dev/null
echo "===== runtime.log tail ====="; tail -15 runtime.log 2>/dev/null
echo "VOL_CMP_DONE"
'
echo "===== VOL compare job finished @ $(date) ====="
