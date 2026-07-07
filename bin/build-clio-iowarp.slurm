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
export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
git config --global --add safe.directory '"$SRC"'
cmake -S '"$SRC"' -B '"$BUILD_DIR"' -G "Unix Makefiles" \
    -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ \
    -DCMAKE_BUILD_TYPE=Release \
    -DCLIO_CORE_ENABLE_RUNTIME=ON \
    -DCLIO_CORE_ENABLE_CTE=ON \
    -DCLIO_CORE_ENABLE_CAE=OFF \
    -DCLIO_CORE_ENABLE_CEE=OFF \
    -DCLIO_CORE_ENABLE_TESTS=OFF \
    -DCLIO_CORE_ENABLE_ELF=ON \
    -DCLIO_CTE_ENABLE_POSIX_ADAPTER=ON \
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
find '"$BUILD_DIR"' -name "libclio_cte_posix.so" -o -name "clio_run" | head
chmod -R a+rX '"$BUILD_DIR"' || true
echo "CLIO_IOWARP_BUILD_OK"
'
echo "===== clio-iowarp build finished @ $(date) ====="
