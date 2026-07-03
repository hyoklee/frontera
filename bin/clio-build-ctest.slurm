#!/bin/bash
#SBATCH -J clio-build
#SBATCH -p normal
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 03:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/clio-build-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/clio-build-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Build clio-core and run ctest under /work2/11623/hyoklee/frontera/build/clio-core,
# INSIDE the iowarp/deps-cpu Apptainer container.
#
# Why a container: Frontera compute nodes run an el7 kernel with glibc 2.17.
# The conda-forge toolchain targets glibc >= 2.38, so a native/conda build
# compiles but cannot load ("GLIBC_2.38 not found"). The deps-cpu image is
# Ubuntu 24.04 (glibc 2.39, gcc 13.3) and already ships every dependency
# (boost-context, nlohmann_json, yaml-cpp, libaio/liburing), so binaries built
# inside it run inside it regardless of the host OS. This mirrors the repo's
# canonical CI recipe (.github/workflows/ci-linux.yml -> boost-docker).
#
# Apptainer cannot run on Frontera login nodes -- this is why the whole flow
# (image pull + configure + build + test) lives in the batch job.

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/clio-deps-cpu.sif
SRC=/work2/11623/hyoklee/clio-core
BUILD_DIR=/work2/11623/hyoklee/frontera/build/clio-core
export APPTAINER_CACHEDIR=$SCRATCH/apptainer-cache

# Pull the deps image if it isn't cached yet (compute nodes have egress).
if [ ! -f "$SIF" ]; then
    echo "===== Pulling $SIF ====="
    apptainer pull "$SIF" docker://iowarp/deps-cpu:latest
fi

# Fresh build tree (an earlier conda attempt may have left incompatible cache).
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "===== Build + ctest starting $(date) on $(hostname) ====="

# Bind $WORK so both the source and the build dir are visible at their real
# paths inside the container. Everything below runs in the Ubuntu 24.04 image.
# --cleanenv: do NOT leak the host environment into the container. Frontera's
# default Intel oneAPI module sets CC=icx / CXX=icpx (and MKL/MPI vars) which do
# not exist in the Ubuntu image and would break CMake's compiler detection.
apptainer exec --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        set -e
        # Belt-and-suspenders: drop any inherited toolchain vars.
        unset CC CXX FC F77 F90 CFLAGS CXXFLAGS FFLAGS FCFLAGS CPPFLAGS LDFLAGS
        export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/x86_64-linux-gnu
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
        git config --global --add safe.directory '"$SRC"'

        # Configure: "boost" preset settings (release + Boost.Context coroutine
        # backend, Python bindings OFF) with io_uring OFF for the el7 3.10 kernel
        # (falls back to libaio / pread+pwrite).
        cmake -S '"$SRC"' -B '"$BUILD_DIR"' -G "Unix Makefiles" \
            -DCMAKE_C_COMPILER=gcc \
            -DCMAKE_CXX_COMPILER=g++ \
            -DCMAKE_BUILD_TYPE=Release \
            -DCLIO_CORE_ENABLE_RUNTIME=ON \
            -DCLIO_CORE_ENABLE_CTE=ON \
            -DCLIO_CORE_ENABLE_CAE=ON \
            -DCLIO_CORE_ENABLE_CEE=ON \
            -DCLIO_CORE_ENABLE_TESTS=ON \
            -DCLIO_CORE_ENABLE_ELF=OFF \
            -DCLIO_CTE_ENABLE_COMPRESS=OFF \
            -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
            -DCLIO_CTE_ENABLE_ADIOS2_ADAPTER=OFF \
            -DCLIO_CORE_ENABLE_CONDA=OFF \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DCLIO_CORE_ENABLE_ASAN=OFF \
            -DCLIO_CORE_ENABLE_COVERAGE=OFF \
            -DCLIO_CTP_LOG_LEVEL=1 \
            -DCLIO_CORE_ENABLE_PYTHON=OFF \
            -DCLIO_CORE_ENABLE_BOOST_COROUTINES=ON \
            -DCLIO_CTE_ENABLE_FILESYSTEM=ON \
            -DCLIO_CORE_ENABLE_IO_URING=OFF

        cmake --build '"$BUILD_DIR"' -j"$(nproc)"

        # ollama-labeled tests need an LLM server; ctp_async_io exercises the
        # io_uring path we disabled -- exclude both (matches CI).
        ctest --test-dir '"$BUILD_DIR"' --output-on-failure \
            --timeout 180 --repeat until-pass:3 \
            -LE ollama -E ctp_async_io
    '
rc=$?
echo "===== Finished $(date) (ctest exit code: $rc) ====="
exit $rc
