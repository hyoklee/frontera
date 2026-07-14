#!/bin/bash
#SBATCH -J clio-gpu-bench
#SBATCH -p rtx
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 06:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/clio-gpu-bench-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/clio-gpu-bench-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Build clio-core with CUDA and run its GPU benchmarks on ONE Frontera rtx
# node (4x NVIDIA Quadro RTX 5000, Turing / sm_75), INSIDE an Apptainer
# container.
#
# Why a container: Frontera compute nodes run an el7 kernel with glibc 2.17,
# so a native / conda-forge toolchain compiles but cannot load
# ("GLIBC_2.38 not found"). The CPU recipe (clio-build-ctest.slurm) solves
# this with the Ubuntu-24.04 iowarp/deps-cpu image. That image has NO CUDA
# toolkit, so here we build a sibling GPU image, clio-deps-gpu.sif, by taking
# iowarp/deps-cpu itself (which already ships every clio dependency -- boost,
# cereal, msgpack, yaml-cpp, nlohmann_json, libaio, cmake, gcc 13) and adding
# the CUDA 12.6 toolkit from NVIDIA's apt repo. This mirrors the repo's own
# GPU CI recipe (.github/workflows/gpu-tests.yml: cuda-keyring + cuda-toolkit-
# 12-6 on ubuntu-24.04) and guarantees dependency parity with the working CPU
# build. Binaries built inside run inside via `apptainer exec --nv`,
# regardless of the el7 host.
#
# NOTE on GPU allocation: Frontera's rtx nodes report Gres=(null) -- GPUs are
# NOT requested with --gres. Each rtx node carries 4x RTX 5000 that come with
# the (whole-node) allocation and are exposed to the container via `--nv`.
# Adding `#SBATCH --gres=gpu:N` makes sbatch reject the job ("Invalid generic
# resource (gres) specification").
#
# Apptainer cannot run on Frontera login nodes, and its unprivileged (proot)
# `build` is likewise blocked there -- so the SIF build, the CUDA build, and
# the benchmark run all live in this batch job. Frontera compute nodes DO
# have internet egress (verified), so `apptainer build` and CMake FetchContent
# work from within the job.

set -eo pipefail
module load tacc-apptainer/1.4.1

SIF=/work2/11623/hyoklee/frontera/clio-deps-gpu.sif
DEF=/work2/11623/hyoklee/frontera/clio-deps-gpu.def
SRC=/work2/11623/hyoklee/clio-core
BUILD_DIR=/work2/11623/hyoklee/frontera/build/clio-core-gpu
export APPTAINER_CACHEDIR=$SCRATCH/apptainer-cache

echo "===== clio GPU benchmark job starting $(date) on $(hostname) ====="
# Confirm the GPUs are visible on the host (rtx node -> 4x RTX 5000).
nvidia-smi || { echo "no GPU on this node -- are we on the rtx partition?"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Build the CUDA-enabled deps image once (cached at $SIF thereafter).
#    Base = iowarp/deps-cpu (all clio deps present) + CUDA 12.6 toolkit from
#    NVIDIA's apt repo (compile-only; the GPU driver comes from the host via
#    --nv). deps-cpu is Ubuntu 24.04 (noble), matching the ubuntu2404 repo.
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
# 2. Configure + build the CUDA benchmark/test targets inside the container.
#    --cleanenv: do NOT leak Frontera's Intel oneAPI env (CC=icx etc.) into
#    the Ubuntu image. Bind $WORK so source + build tree are at their real
#    paths. io_uring OFF (el7 3.10 kernel has none, even inside a container);
#    CUDA arch pinned to 75 for the Turing RTX 5000 so nvcc need not probe a
#    device at compile time. Only the GPU targets are built (not all ~258
#    test binaries) to keep the build fast.
#
#    IMPORTANT: unlike the CPU recipe (clio-build-ctest.slurm), Boost.Context
#    coroutines are LEFT OFF here. The default C++20 stackless backend is the
#    combination CUDA is tested against (cuda-release preset). With Boost ON,
#    nvcc's device pass fails to compile clio_run_cxx_gpu: boost_await() in
#    task.h is guarded only by CLIO_ENABLE_BOOST_COROUTINES (not also by
#    CTP_IS_HOST) yet calls host-only Task members (SetYielded / FiberStateRef),
#    which don't exist in the device compile. GNU + -fcoroutines works.
#
#    CMAKE_CUDA_RUNTIME_LIBRARY=Shared is REQUIRED. add_cuda_executable() (in
#    cmake/ClioCoreCommon.cmake) does not set the cudart linkage, so executables
#    default to STATIC cudart, while the runtime GPU .so's are built with SHARED
#    cudart. A benchmark that links those .so's would then hold TWO cudart
#    instances in one process, and the runtime's worker-thread cudaSetDevice
#    fails with "CUDA Error 35: driver version insufficient". Forcing Shared
#    globally makes the whole process use one libcudart.so (this also enables
#    CUDA minor-version compatibility: a 12.6 build runs on Frontera's 12.2
#    driver, 535.113.01).
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
echo "===== Configure + build (CUDA) starting $(date) ====="
apptainer exec --nv --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        set -e
        unset CC CXX FC F77 F90 CFLAGS CXXFLAGS FFLAGS FCFLAGS CPPFLAGS LDFLAGS
        export PATH=/usr/local/cuda/bin:$PATH
        export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/lib:/usr/lib/x86_64-linux-gnu
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig
        git config --global --add safe.directory '"$SRC"'
        nvcc --version

        if [ ! -f '"$BUILD_DIR"'/CMakeCache.txt ]; then
            cmake -S '"$SRC"' -B '"$BUILD_DIR"' -G "Unix Makefiles" \
                -DCMAKE_C_COMPILER=gcc \
                -DCMAKE_CXX_COMPILER=g++ \
                -DCMAKE_BUILD_TYPE=Release \
                -DCLIO_CORE_ENABLE_CUDA=ON \
                -DCMAKE_CUDA_ARCHITECTURES=75 \
                -DCMAKE_CUDA_RUNTIME_LIBRARY=Shared \
                -DCLIO_CORE_ENABLE_RUNTIME=ON \
                -DCLIO_CORE_ENABLE_CTE=ON \
                -DCLIO_CORE_ENABLE_CAE=OFF \
                -DCLIO_CORE_ENABLE_CEE=OFF \
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
                -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        fi

        cmake --build '"$BUILD_DIR"' -j"$(nproc)" --target \
            clio_kernel_pinned_bench \
            clio_memcpy_d2h_bench \
            clio_cte_gpu_vector_bench \
            clio_traditional_oom_bench \
            clio_uvm_bench \
            test_gpu_vector
    '

# ---------------------------------------------------------------------------
# 3. Run the GPU benchmarks (and the GPU-vector correctness test).
#    The benchmarks self-init a clio runtime in server mode (CLIO_INIT),
#    which REPLAYS $HOME/.clio/restart_log.bin on start. Isolate this run with
#    a fresh WAL so a stale log from a prior ctest run can't be replayed and
#    crash startup. Loopback bind/port keeps the embedded runtime local.
# ---------------------------------------------------------------------------
echo "===== Running GPU benchmarks $(date) ====="
apptainer exec --nv --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        set -e
        export PATH=/usr/local/cuda/bin:$PATH
        # APPEND to LD_LIBRARY_PATH -- never overwrite it. `apptainer --nv`
        # injects the host GPU driver libs (libcuda.so, libnvidia-ml.so) into
        # /.singularity.d/libs and adds that dir to LD_LIBRARY_PATH; clobbering
        # it makes the CUDA driver API (and nvidia-smi) invisible.
        export LD_LIBRARY_PATH='"$BUILD_DIR"'/bin:/usr/local/cuda/lib64:/usr/local/lib:/usr/lib/x86_64-linux-gnu:/.singularity.d/libs:${LD_LIBRARY_PATH}
        export CLIO_REPO_PATH='"$BUILD_DIR"'/bin
        export CLIO_BIND_ADDR=127.0.0.1
        export CLIO_PORT=10500
        export CLIO_RESTART_LOG='"$BUILD_DIR"'/gpu_bench_restart_${SLURM_JOB_ID:-0}.bin
        rm -f "$CLIO_RESTART_LOG"
        cd '"$BUILD_DIR"'/bin
        nvidia-smi -L || true

        echo "----- clio_kernel_pinned_bench (raw kernel<->DRAM bandwidth) -----"
        ./clio_kernel_pinned_bench --gpu-id 0

        echo "----- clio_memcpy_d2h_bench (cudaMemcpy D2H baseline) -----"
        ./clio_memcpy_d2h_bench --gpu-id 0

        echo "----- clio_cte_gpu_vector_bench (CTE GPU Vector write/flush/read) -----"
        ./clio_cte_gpu_vector_bench --gpu-id 0

        echo "----- clio_traditional_oom_bench (sync D2H + PutBlob baseline) -----"
        ./clio_traditional_oom_bench --gpu-id 0

        echo "----- clio_uvm_bench (cudaMallocManaged + PutBlob baseline) -----"
        ./clio_uvm_bench --gpu-id 0
    '

# ---------------------------------------------------------------------------
# 4. GPU-vector correctness test (cte_gpu_vector_cuda). Run the test BINARY
#    directly with the same environment as the benchmarks above -- NOT via
#    `ctest`. ctest injects the test's ENVIRONMENT property, whose
#    LD_LIBRARY_PATH is baked at configure time and omits the `--nv` driver
#    dir (/.singularity.d/libs); running under it reintroduces CUDA Error 35.
#    Executing the binary directly keeps the working LD_LIBRARY_PATH.
# ---------------------------------------------------------------------------
echo "===== Running GPU vector correctness test $(date) ====="
apptainer exec --nv --cleanenv \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c '
        set -e
        export PATH=/usr/local/cuda/bin:$PATH
        export LD_LIBRARY_PATH='"$BUILD_DIR"'/bin:/usr/local/cuda/lib64:/usr/local/lib:/usr/lib/x86_64-linux-gnu:/.singularity.d/libs:${LD_LIBRARY_PATH}
        export CLIO_REPO_PATH='"$BUILD_DIR"'/bin
        export CLIO_BIND_ADDR=127.0.0.1
        export CLIO_PORT=10500
        export CLIO_RESTART_LOG='"$BUILD_DIR"'/gpu_test_restart_${SLURM_JOB_ID:-0}.bin
        rm -f "$CLIO_RESTART_LOG"
        cd '"$BUILD_DIR"'/bin
        ./test_gpu_vector
    '
rc=$?
echo "===== Finished $(date) (exit code: $rc) ====="
exit $rc
