#!/bin/bash
#SBATCH -J probe-attrinfo
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:20:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/probe-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/probe-%j.err
#
# Fast isolated reproducer for the VOL attribute-info gap. A pure-C probe calls
# exactly what neuroh5's get_cell_attribute_name_spaces does:
#   H5Lexists("Populations")        [single-comp, WORKS]
#   H5Lexists("Populations/<pop>")  [multi-comp,  SUSPECT]
#   H5Gopen2 + H5Literate2 on the nested group  [namespace enumeration]
# native vs clio VOL, ~seconds -> tight fix/rebuild/test loop.

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
CLIO_IOWARP=/work2/11623/hyoklee/frontera/build/clio-core-iowarp
CONF=/work2/11623/hyoklee/frontera.hyoklee/bin/chimaera_case6.yaml
SRC=/scratch2/11623/hyoklee/miv-case6/datasets/Microcircuit_Small/MiV_Cells_Microcircuit_Small_20220410.h5
RUNDIR=/scratch2/11623/hyoklee/miv-probe
rm -rf "$RUNDIR"; mkdir -p "$RUNDIR"
cp "$SRC" "$RUNDIR/cells.h5"
cp "$CONF" "$RUNDIR/chimaera_case6.yaml"

VOL_SO=$(find "$CLIO_IOWARP" -name libclio_hdf5_vol.so 2>/dev/null | head -1)
CLIO_RUN=$(find "$CLIO_IOWARP" -name clio_run -type f 2>/dev/null | head -1)
VOL_DIR=$(dirname "$VOL_SO")
echo "VOL_SO=$VOL_SO"; echo "CLIO_RUN=$CLIO_RUN"

cat > "$RUNDIR/probe.c" <<'CC'
#include "hdf5.h"
#include <stdio.h>
static herr_t cb(hid_t g, const char *name, const H5L_info2_t *info, void *op) {
  (*(int*)op)++; fprintf(stderr, "    iter name=%s\n", name); return 0;
}
int main(int argc, char **argv) {
  const char *pop = argc > 2 ? argv[2] : "OLM";
  char p[256]; snprintf(p, sizeof p, "Populations/%s", pop);
  hid_t f = H5Fopen(argv[1], H5F_ACC_RDONLY, H5P_DEFAULT);
  printf("Fopen=%ld\n", (long)f);
  printf("H5Lexists Populations      = %d\n", (int)H5Lexists(f, "Populations", H5P_DEFAULT));
  printf("H5Lexists %-16s = %d\n", p, (int)H5Lexists(f, p, H5P_DEFAULT));
  char ap[256]; snprintf(ap, sizeof ap, "/Populations/%s", pop);
  printf("H5Lexists %-16s = %d\n", ap, (int)H5Lexists(f, ap, H5P_DEFAULT));
  hid_t g = H5Gopen2(f, ap, H5P_DEFAULT);
  printf("H5Gopen2 %s = %ld\n", ap, (long)g);
  if (g >= 0) {
    int n = 0; hsize_t idx = 0;
    herr_t r = H5Literate2(g, H5_INDEX_NAME, H5_ITER_NATIVE, &idx, cb, &n);
    printf("H5Literate2 rc=%d count=%d\n", (int)r, n);
    H5Gclose(g);
  }
  H5Fclose(f);
  return 0;
}
CC

apptainer exec --cleanenv --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    --bind /scratch2/11623/hyoklee:/scratch2/11623/hyoklee \
    "$SIF" bash -c '
set -e
. /opt/miv-venv/bin/activate
export PATH=/opt/hdf5/bin:/opt/neuroh5/bin:$PATH
export LD_LIBRARY_PATH=/opt/hdf5/lib:$LD_LIBRARY_PATH
export MIV_SKIP_MPI_CHECK=1
cd '"$RUNDIR"'
VOL_DIR='"$VOL_DIR"'; CLIO_RUN='"$CLIO_RUN"'
CLEAN="rm -f /dev/shm/chi_* 2>/dev/null || true"

echo "===== compile C probe (explicitly against /opt/hdf5) ====="
gcc -o probe probe.c -I/opt/hdf5/include -L/opt/hdf5/lib -lhdf5 && echo "compiled"
echo "--- probe hdf5 link ---"; ldd probe | grep -i hdf5 || true
echo "--- VOL .so hdf5 link ---"; ldd '"$VOL_DIR"'/libclio_hdf5_vol.so | grep -i hdf5 || true

echo "===== NATIVE C probe ====="
timeout 60 ./probe cells.h5 OLM || echo "NATIVE C probe rc=$?"

eval "$CLEAN"
echo "===== start clio_run runtime ====="
export CLIO_SERVER_CONF='"$RUNDIR"'/chimaera_case6.yaml
export LD_LIBRARY_PATH=$VOL_DIR:/opt/hdf5/lib:$LD_LIBRARY_PATH
"$CLIO_RUN" runtime start > runtime.log 2>&1 &
RTPID=$!
for i in $(seq 1 40); do
    if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/9413" 2>/dev/null; then echo "runtime up after ${i}s"; break; fi
    kill -0 $RTPID 2>/dev/null || { echo "RUNTIME DIED"; tail -30 runtime.log; break; }
    sleep 1
done
echo "===== VOL C probe (HDF5_VOL_CONNECTOR=clio) ====="
HDF5_PLUGIN_PATH=$VOL_DIR HDF5_VOL_CONNECTOR=clio \
    timeout 60 ./probe cells.h5 OLM || echo "VOL C probe rc=$?"

echo "===== VOL neuroh5 probe ====="
cat > np.py <<PY
from neuroh5.io import read_cell_attribute_info, read_population_names
pops = sorted(read_population_names("cells.h5"))
info = read_cell_attribute_info("cells.h5", pops)
print("NEUROH5 pops =", pops)
print("NEUROH5 attr_info keys =", sorted(info.keys()))
PY
HDF5_PLUGIN_PATH=$VOL_DIR HDF5_VOL_CONNECTOR=clio \
    timeout 60 python3 np.py || echo "VOL neuroh5 probe rc=$?"

"$CLIO_RUN" runtime stop 2>/dev/null || kill $RTPID 2>/dev/null || true
eval "$CLEAN"
echo "PROBE_DONE"
'
echo "===== probe finished @ $(date) ====="
