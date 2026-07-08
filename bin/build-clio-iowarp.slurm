#!/bin/bash
#SBATCH -J clio-iowarp
#SBATCH -p normal
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 02:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/clio-iowarp-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/clio-iowarp-%j.err
#
# Build clio-core WITH the CTE POSIX adapter (CLIO_CORE_ENABLE_ELF=ON) so we can
# LD_PRELOAD libclio_cte_posix.so into run-network for the IOWarp-vs-native
# comparison. Built inside miv-stack.sif (has clio deps + libelf), so the .so is
# glibc-2.39 compatible and loadable at case-6 run time in the same container.

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
SRC=/work2/11623/hyoklee/clio-core
BUILD_DIR=/work2/11623/hyoklee/frontera/build/clio-core-iowarp
rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

apptainer exec --cleanenv --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
set -e
unset CC CXX FC CFLAGS CXXFLAGS LDFLAGS
# Put /opt/hdf5 (the HDF5 neuroh5/run-network link, libhdf5.so.310) FIRST so the
# VOL connector links THAT, not the base image HDF5 at /usr/local (so.320) --
# two HDF5s in run-network segfaults in H5CX_get_vol_connector_prop.
export PATH=/opt/hdf5/bin:$PATH
export LD_LIBRARY_PATH=/opt/hdf5/lib:/usr/lib/x86_64-linux-gnu
export PKG_CONFIG_PATH=/opt/hdf5/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
git config --global --add safe.directory '"$SRC"'
cmake -S '"$SRC"' -B '"$BUILD_DIR"' -G "Unix Makefiles" \
    -DCMAKE_C_COMPILER=mpicc -DCMAKE_CXX_COMPILER=mpicxx \
    -DCMAKE_BUILD_TYPE=Release \
    -DCLIO_CORE_ENABLE_RUNTIME=ON \
    -DCLIO_CORE_ENABLE_CTE=ON \
    -DCLIO_CORE_ENABLE_CAE=OFF \
    -DCLIO_CORE_ENABLE_CEE=OFF \
    -DCLIO_CORE_ENABLE_TESTS=OFF \
    -DCLIO_CORE_ENABLE_ELF=ON \
    -DCLIO_CTE_ENABLE_POSIX_ADAPTER=ON \
    -DCLIO_CTE_ENABLE_HDF5_VOL=ON \
    -DHDF5_ROOT=/opt/hdf5 -DHDF5_PREFER_PARALLEL=ON \
    -DCMAKE_IGNORE_PATH=/usr/local/cmake \
    -DCLIO_CTE_ENABLE_COMPRESS=OFF \
    -DCLIO_CTE_ENABLE_ADIOS2_ADAPTER=OFF \
    -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
    -DCLIO_CORE_ENABLE_PYTHON=OFF \
    -DCLIO_CORE_ENABLE_BOOST_COROUTINES=ON \
    -DCLIO_CTE_ENABLE_FILESYSTEM=ON \
    -DCLIO_CORE_ENABLE_CONDA=OFF \
    -DCLIO_CORE_ENABLE_IO_URING=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build '"$BUILD_DIR"' -j"$(nproc)"
echo "===== built artifacts ====="
find '"$BUILD_DIR"' -name "libclio_cte_posix.so" -o -name "libiowarp_hdf5_vol.so" -o -name "clio_run" | head
echo "===== VOL connector HDF5 link (must be /opt/hdf5, NOT /usr/local) ====="
VS=$(find '"$BUILD_DIR"' -name libiowarp_hdf5_vol.so | head -1)
ldd "$VS" | grep -iE "hdf5|libhdf5" || echo "(no direct hdf5 dep listed)"
chmod -R a+rX '"$BUILD_DIR"' || true
echo "CLIO_IOWARP_BUILD_OK"
'
echo "===== clio-iowarp build finished @ $(date) ====="
