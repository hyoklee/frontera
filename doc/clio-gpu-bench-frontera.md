# clio-core GPU benchmark on TACC Frontera (Apptainer, single node)

Running the clio-core CUDA GPU benchmarks on **one Frontera `rtx` node**
(4× NVIDIA Quadro RTX 5000, Turing / sm_75) inside an Apptainer container.
Job script: [`clio-gpu-bench.slurm`](../bin/clio-gpu-bench.slurm). Verified working
end-to-end on 2026-07-14 (Slurm job 7857462, exit 0).

## Why a container

Frontera compute nodes run an el7 kernel with **glibc 2.17**. A native or
conda-forge toolchain compiles but cannot load (`GLIBC_2.38 not found`). The
CPU recipe (`clio-build-ctest.slurm`) solves this with the Ubuntu-24.04
`iowarp/deps-cpu` image; binaries built inside run inside regardless of the
host OS. Apptainer is blocked on Frontera login nodes (and so is its
unprivileged `build`), so the whole flow — SIF build, CUDA compile, benchmark
run — happens in the batch job. Frontera compute nodes have internet egress,
so `apptainer build` and CMake FetchContent work from within the job.

## The recipe (what finally works)

1. **Partition / GPUs.** `-p rtx -N 1`. **No `--gres`** — Frontera rtx nodes
   report `Gres=(null)`; the 4 GPUs come with the whole-node allocation and
   reach the container via `apptainer exec --nv`. Adding `--gres=gpu:N` makes
   `sbatch` reject the job.
2. **GPU deps image.** Build `clio-deps-gpu.sif` **from `iowarp/deps-cpu`**
   (all clio deps: boost, cereal, msgpack, yaml-cpp, nlohmann_json, libaio,
   cmake, gcc 13) **+ the CUDA 12.6 toolkit** from NVIDIA's apt repo. This
   mirrors the repo's own GPU CI (`.github/workflows/gpu-tests.yml`). A bare
   `nvidia/cuda` base is **not** enough — it lacks cereal/msgpack/etc.
3. **Configure** (GNU + nvcc), key flags:
   - `-DCLIO_CORE_ENABLE_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75`
   - `-DCMAKE_CUDA_RUNTIME_LIBRARY=Shared` — **required** (see gotcha 4)
   - `-DCLIO_CORE_ENABLE_IO_URING=OFF` — el7 3.10 kernel has no io_uring
   - **Boost coroutines OFF** (default C++20 backend) — see gotcha 2
   - build only the GPU targets to keep it fast
4. **Run** the benchmarks with `--nv`, appending (never overwriting)
   `LD_LIBRARY_PATH` and including the `--nv` driver dir `/.singularity.d/libs`.
   Each benchmark self-inits a runtime (`CLIO_INIT(kServer)`), so give it a
   fresh `CLIO_RESTART_LOG` per job (stale-WAL replay trap).

## Results (RTX 5000, 64 MiB working set, 1 MiB pages)

| Benchmark | Write | Read | End-to-end |
|---|---|---|---|
| **`clio_cte_gpu_vector_bench`** (CTE GPU Vector) | **109,589 MiB/s** (~107 GiB/s) | 46,818 MiB/s | **32,804 MiB/s** |
| `clio_traditional_oom_bench` (sync D2H + PutBlob) | 1,328 MiB/s | 1,721 MiB/s | 750 MiB/s |
| `clio_uvm_bench` (cudaMallocManaged + PutBlob) | 882 MiB/s | 1,366 MiB/s | 536 MiB/s |
| `clio_kernel_pinned_bench` | HBM 188 GiB/s, pinned 12.3 GiB/s | — | — |
| `clio_memcpy_d2h_bench` | up to 12.3 GiB/s (PCIe-bound) | — | — |

The CTE GPU-Vector write path (~107 GiB/s, GPU-direct into the CTE RAM tier)
outperforms the traditional-OOM and UVM baselines by ~80–120×, which is the
whole point of the `gpu_vector` adapter. The correctness test
`cte_gpu_vector_cuda` also passes (write→read round-trip).

> Note: benchmark throughput prints to **stderr** (interleaved with build
> warnings), while the raw-kernel and memcpy baselines print to stdout.

## Gotchas hit (root cause → fix)

1. **`sbatch` rejects `--gres`.** Frontera rtx allocates GPUs by partition,
   not GRES (`Gres=(null)`). → Remove `--gres`; GPUs arrive via `--nv`.
2. **nvcc fails to compile `clio_run_cxx_gpu` with Boost coroutines.**
   `boost_await()` in `context-runtime/include/clio_runtime/task.h` is guarded
   only by `#ifdef CLIO_ENABLE_BOOST_COROUTINES` (not also `CTP_IS_HOST`) yet
   calls host-only `Task` members (`SetYielded`/`SetYieldTimeUs`/
   `FiberStateRef`) that don't exist in nvcc's device pass. Boost+CUDA is a
   broken/untested combination. → Leave Boost **OFF** (default C++20 stackless
   backend, GNU + `-fcoroutines`), matching the `cuda-release` preset. (Boost is
   force-ON only for the NVHPC compiler, not GNU.)
3. **`nvidia-smi`/CUDA can't find `libnvidia-ml.so` / `libcuda.so`.** The run
   block overwrote `LD_LIBRARY_PATH`, clobbering the driver libs that
   `apptainer --nv` injects into `/.singularity.d/libs`. → **Append**
   `:${LD_LIBRARY_PATH}` and add `/.singularity.d/libs` explicitly.
4. **`cudaSetDevice` → `CUDA Error 35: driver version insufficient`.**
   `add_cuda_executable()` (cmake/ClioCoreCommon.cmake) never sets cudart
   linkage → executables default to **static** cudart, while the GPU `.so`s use
   **shared** cudart. A benchmark linking those `.so`s then holds **two cudart
   instances** in one process, and the runtime's worker-thread `cudaSetDevice`
   fails. → `-DCMAKE_CUDA_RUNTIME_LIBRARY=Shared` unifies the process on one
   `libcudart.so`. This also enables CUDA **minor-version compatibility**: the
   12.6 toolkit runs on Frontera's driver **535.113.01 (CUDA 12.2)**. This
   matters because the `ubuntu2404` NVIDIA repo's earliest toolkit is 12.5
   (no 12.2/12.3/12.4), so you cannot version-match on the 24.04 base.
5. **The `ctest` re-triggers Error 35.** `ctest` injects the test's
   `ENVIRONMENT` property, whose `LD_LIBRARY_PATH` is baked at configure time
   and omits `/.singularity.d/libs`. → Run the `test_gpu_vector` **binary
   directly** with the same env as the benchmarks, not via `ctest`.

## Environment reference

- Host: Frontera `c199-*` rtx nodes, driver **535.113.01** (max CUDA 12.2),
  4× Quadro RTX 5000 (16 GB, Turing sm_75), 16 cores / 128 GB per node.
- Container: `iowarp/deps-cpu` (Ubuntu 24.04, glibc 2.39, gcc 13.3) + CUDA
  toolkit 12.6.2. SIF cached at `/work2/11623/hyoklee/frontera/clio-deps-gpu.sif`.
- Build dir: `/work2/11623/hyoklee/frontera/build/clio-core-gpu`.
- Allocation: `IBN22011`. First run builds SIF + full CUDA build (~15 min);
  reruns reuse both (~15 s).
