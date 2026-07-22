#!/bin/bash
#SBATCH -J clio-gpu-cdash
#SBATCH -p rtx
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 08:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/clio-gpu-cdash-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/clio-gpu-cdash-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Run `ctest -D Continuous` on the LATEST dev branch of clio-core on one
# Frontera rtx node (4x NVIDIA Quadro RTX 5000, Turing / sm_75), inside an
# Apptainer container, and submit the Configure/Build/Test results to the
# HERMES project on my.cdash.org.
#
#   - Build:      Debug, GPU tests enabled (CLIO_CORE_ENABLE_CUDA=ON)
#   - Dashboard:  SITE=frontera, BUILDNAME=d/gpu, model=Continuous
#   - Submit:     the repo's own CTestConfig.cmake already targets
#                 my.cdash.org  ->  /submit.php?project=HERMES (https), so the
#                 ContinuousSubmit step routes there with no override needed.
#
# The container reuses the GPU deps image built by clio-gpu-bench.slurm
# (iowarp/deps-cpu + CUDA 12.6 toolkit on Ubuntu 24.04 / glibc 2.39). See
# clio-gpu-bench-findings.md for why a container is required on Frontera's
# el7 / glibc-2.17 host and for the CUDA gotchas reused below:
#   * no --gres on rtx (GPUs come with the node, exposed via `apptainer --nv`)
#   * Boost coroutines OFF for the CUDA build (nvcc device pass breaks with it)
#   * CMAKE_CUDA_RUNTIME_LIBRARY=Shared (single cudart -> no CUDA Error 35;
#     also gives minor-version compat: 12.6 toolkit on the 12.2 host driver)
#   * io_uring OFF (el7 3.10 kernel has none, even inside a container)
#   * APPEND LD_LIBRARY_PATH incl. /.singularity.d/libs so the --nv driver
#     libs (libcuda.so, libnvidia-ml.so) stay visible
#
# Apptainer is blocked on Frontera login nodes; compute nodes DO have internet
# egress, so the git clone, CMake FetchContent, and the CDash submit all run
# from within this batch job.

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/clio-deps-gpu.sif
DEF=/work2/11623/hyoklee/frontera/clio-deps-gpu.def
SRC=/work2/11623/hyoklee/frontera/dashboard/clio-core
BUILD_DIR=/work2/11623/hyoklee/frontera/dashboard/build
export APPTAINER_CACHEDIR=$SCRATCH/apptainer-cache

echo "===== clio GPU CDash dashboard job starting $(date) on $(hostname) ====="
nvidia-smi -L || { echo "no GPU on this node -- are we on the rtx partition?"; exit 1; }

# ---------------------------------------------------------------------------
# 0. Ensure the CUDA-enabled deps image exists (built from iowarp/deps-cpu +
#    the CUDA 12.6 toolkit). Identical recipe to clio-gpu-bench.slurm.
# ---------------------------------------------------------------------------
if [ ! -f "$SIF" ]; then
    echo "===== Building $SIF ====="
    cat > "$DEF" <<'DEFEOF'
Bootstrap: docker
From: iowarp/deps-cpu:latest

%post
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends wget ca-certificates gnupg
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i cuda-keyring_1.1-1_all.deb
    rm -f cuda-keyring_1.1-1_all.deb
    apt-get update
    apt-get install -y --no-install-recommends cuda-toolkit-12-6
    apt-get clean
    rm -rf /var/lib/apt/lists/*

%environment
    export PATH=/usr/local/cuda/bin:$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
DEFEOF
    apptainer build "$SIF" "$DEF"
fi

# ---------------------------------------------------------------------------
# 1. Fetch the LATEST dev branch (fresh clone, or hard-reset an existing tree
#    to origin/dev). Done inside the container to guarantee git + submodule
#    tooling. Compute nodes have egress. The `docs` submodule is not needed to
#    build, so its update is best-effort.
# ---------------------------------------------------------------------------
mkdir -p /work2/11623/hyoklee/frontera/dashboard
echo "===== Syncing clio-core dev $(date) ====="
apptainer exec --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        set -e
        if [ -d '"$SRC"'/.git ]; then
            git config --global --add safe.directory '"$SRC"'
            git -C '"$SRC"' fetch --depth 1 origin dev
            git -C '"$SRC"' reset --hard origin/dev
        else
            rm -rf '"$SRC"'
            git clone --depth 1 --branch dev \
                https://github.com/iowarp/clio-core '"$SRC"'
        fi
        git config --global --add safe.directory '"$SRC"'
        git -C '"$SRC"' submodule update --init --recursive --depth 1 || \
            echo "WARNING: submodule update failed (docs) -- not needed to build"
        echo "dev HEAD: $(git -C '"$SRC"' rev-parse --short HEAD) \
$(git -C '"$SRC"' log -1 --format=%s)"
    '

# ---------------------------------------------------------------------------
# 2. Pre-configure the build tree so the CMake cache + DartConfiguration.tcl
#    hold ALL options (Debug, CUDA/tests ON, SITE, BUILDNAME, the drop info
#    from CTestConfig.cmake via include(CTest)). `ctest -D Continuous`'s
#    ContinuousConfigure step then reuses this cache; without it the
#    configure would run with defaults (no CUDA/tests, no dashboard config).
#    --cleanenv drops Frontera's Intel oneAPI vars (CC=icx...) that don't
#    exist in the Ubuntu image.
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "===== Configure (Debug + CUDA/GPU tests) $(date) ====="
apptainer exec --nv --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        set -e
        unset CC CXX FC F77 F90 CFLAGS CXXFLAGS FFLAGS FCFLAGS CPPFLAGS LDFLAGS
        export PATH=/usr/local/cuda/bin:$PATH
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/lib:/usr/lib/x86_64-linux-gnu
        # The full build links clio_ctp_gpu_linker against the CUDA driver
        # library (-lcuda), which is NOT in the toolkit and NOT on the linker
        # search path (the linker uses LIBRARY_PATH/-L, not LD_LIBRARY_PATH, so
        # --nv does not help at link time). Point -lcuda at the toolkit stub;
        # the real driver lib is used at runtime via --nv + /.singularity.d/libs.
        export LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH}
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
        git config --global --add safe.directory '"$SRC"'
        nvcc --version

        cmake -S '"$SRC"' -B '"$BUILD_DIR"' -G "Unix Makefiles" \
            -DCMAKE_C_COMPILER=gcc \
            -DCMAKE_CXX_COMPILER=g++ \
            -DCMAKE_BUILD_TYPE=Debug \
            -DSITE=frontera \
            -DBUILDNAME=d/gpu \
            -DCLIO_CORE_ENABLE_CUDA=ON \
            -DCMAKE_CUDA_ARCHITECTURES=75 \
            -DCMAKE_CUDA_RUNTIME_LIBRARY=Shared \
            -DCLIO_CORE_ENABLE_RUNTIME=ON \
            -DCLIO_CORE_ENABLE_CTE=ON \
            -DCLIO_CORE_ENABLE_CAE=ON \
            -DCLIO_CORE_ENABLE_CEE=ON \
            -DCLIO_CORE_ENABLE_TESTS=ON \
            -DCLIO_CORE_ENABLE_BENCHMARKS=ON \
            -DCLIO_CORE_ENABLE_ELF=OFF \
            -DCLIO_CTE_ENABLE_COMPRESS=OFF \
            -DCLIO_CORE_ENABLE_GRAY_SCOTT=OFF \
            -DCLIO_CTE_ENABLE_ADIOS2_ADAPTER=OFF \
            -DCLIO_CORE_ENABLE_CONDA=OFF \
            -DCLIO_CORE_ENABLE_PYTHON=OFF \
            -DCLIO_CTE_ENABLE_FILESYSTEM=ON \
            -DCLIO_CORE_ENABLE_IO_URING=OFF \
            -DCLIO_CTP_LOG_LEVEL=1 \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    '

# ---------------------------------------------------------------------------
# 3. Run the Continuous dashboard: Start -> Configure -> Build -> Test ->
#    Submit, all in one `ctest -D Continuous`. Runs under --nv so the
#    gpu/cuda-labelled tests see the GPUs. Parallel build via
#    CMAKE_BUILD_PARALLEL_LEVEL (CTest's default MakeCommand is `cmake --build`,
#    which honors it). Tests run serially (many bind fixed shm/ports and share
#    the GPUs) with a per-test timeout. Exclude env-incompatible tests that are
#    guaranteed false negatives on this host: `ollama` (needs an LLM server)
#    and `ctp_async_io` (exercises the io_uring path disabled for el7). The
#    Submit step still runs even if tests fail, so results always reach CDash.
# ---------------------------------------------------------------------------
echo "===== ctest -D Continuous (-> my.cdash.org / HERMES) $(date) ====="
set +e
apptainer exec --nv --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        export PATH=/usr/local/cuda/bin:$PATH
        export LD_LIBRARY_PATH='"$BUILD_DIR"'/bin:/usr/local/cuda/lib64:/usr/local/lib:/usr/lib/x86_64-linux-gnu:/.singularity.d/libs:${LD_LIBRARY_PATH}
        # ContinuousBuild links -lcuda -> point it at the toolkit stub (see
        # the configure step); runtime uses the real driver via /.singularity.d/libs.
        export LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH}
        export CLIO_REPO_PATH='"$BUILD_DIR"'/bin
        export CLIO_BIND_ADDR=127.0.0.1
        export CLIO_PORT=10500
        export CLIO_RESTART_LOG='"$BUILD_DIR"'/cdash_restart_${SLURM_JOB_ID:-0}.bin
        rm -f "$CLIO_RESTART_LOG"
        export CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)"
        cd '"$BUILD_DIR"'
        ctest -D Continuous \
            --output-on-failure \
            --timeout 300 \
            -LE ollama -E ctp_async_io
    '
rc=$?
set -e
echo "===== Finished $(date) (ctest -D Continuous exit code: $rc) ====="
echo "Dashboard: https://my.cdash.org/index.php?project=HERMES  (Site: frontera, Build: d/gpu)"
exit $rc
