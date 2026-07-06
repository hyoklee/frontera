# Running clio-core on TACC Frontera

Findings and working recipes for building **clio-core** and forming a
multi-node cluster on TACC **Frontera**. All scripts referenced live in
[`../bin/`](../bin/).

- Source repo: `/work2/11623/hyoklee/clio-core`
- Build dir: `/work2/11623/hyoklee/frontera/build/clio-core`
- Container image (SIF): `/work2/11623/hyoklee/frontera/clio-deps-cpu.sif` (1.8 GB)
- Allocation: `IBN22011`

---

## 1. The core constraint: el7 / glibc 2.17

Frontera login and compute nodes run **CentOS 7 (el7), Linux kernel 3.10,
glibc 2.17**. This breaks the repo's default conda build path:

- The latest **Miniconda** installer requires glibc ≥ 2.28 and refuses to
  install (`Installer requires GLIBC >=2.28`).
- Even with an older Miniconda, `CI/ci-deps.sh` pulls a **conda-forge
  toolchain (gcc 15 + `sysroot_linux-64` 2.39)**. The resulting binaries
  require `GLIBC_2.34/2.38` and **cannot load** on the glibc-2.17 host
  (`ImportError: /lib64/libc.so.6: version 'GLIBC_2.38' not found`). It
  compiles but 1/258 ctest pass.

**Conclusion: do not build natively/conda on Frontera.** Build and run
inside a container whose userspace glibc is modern.

---

## 2. Build + test — [`bin/clio-build-ctest.slurm`](../bin/clio-build-ctest.slurm)

Builds and runs `ctest` **inside the `iowarp/deps-cpu` Apptainer container**
(Ubuntu 24.04, glibc 2.39, gcc 13.3, cmake 3.28). The image already ships
every dependency (boost-context, nlohmann_json, yaml-cpp, libaio, liburing),
so binaries built inside run inside regardless of the host OS. This mirrors
the repo's canonical CI recipe (`.github/workflows/ci-linux.yml` →
`boost-docker`).

```bash
sbatch bin/clio-build-ctest.slurm     # -> build/clio-build-<jobid>.out|.err
```

**Result: `100% tests passed, 0 tests failed out of 249`** (~8 min build+test).

Adaptations required for Frontera:

| Issue | Fix |
|---|---|
| Apptainer is **blocked on login nodes** | pull + configure + build + test all run in the batch job |
| Host kernel 3.10 has **no io_uring** (even in a container — syscalls hit the host kernel) | `-DCLIO_CORE_ENABLE_IO_URING=OFF` (falls back to libaio) |
| Apptainer leaks host env → CMake sees Intel `CC=icx` | `apptainer exec --cleanenv` + pin `-DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++` |
| Python bindings would `FetchContent` nanobind from GitHub | use the `boost` preset (Python OFF) |
| `$WORK` not auto-mounted in the container | `--bind /work2/11623/hyoklee:/work2/11623/hyoklee` |

> Note: Frontera **compute nodes do have internet egress** — `apptainer pull`
> and `FetchContent` work from within a job (unlike the usual TACC assumption).

---

## 3. Multi-node cluster over InfiniBand

- [`bin/clio-cluster-test.slurm`](../bin/clio-cluster-test.slurm) — 2 nodes
- [`bin/clio-cluster-test-4node.slurm`](../bin/clio-cluster-test-4node.slurm) —
  keys off `SLURM_JOB_NUM_NODES`, so `#SBATCH -N` scales it to any node count
- [`bin/clio-net-probe.slurm`](../bin/clio-net-probe.slurm) — network / ssh /
  container diagnostic

```bash
sbatch bin/clio-cluster-test.slurm         # 2-node
sbatch bin/clio-cluster-test-4node.slurm   # 4-node (change -N to scale)
```

### How a cluster forms

Each node runs `clio_run runtime start` (inside apptainer) with
`CLIO_SERVER_CONF` pointing at a config whose `networking.hostfile` lists
every node. Nodes talk via **ZeroMQ RPC on port 9413** and use the **SWIM**
membership protocol. Start all nodes **symmetrically and simultaneously**;
`networking.wait_for_restart` lets each wait for its peers before finalizing
the distributed compose.

### Forcing the InfiniBand fabric

The runtime picks "self" by matching a hostfile entry against a local NIC IP
and advertises that IP. On Frontera:

- `ib0` (IPoIB) = **192.168.x** → the fast HDR InfiniBand fabric
- `em1` = **129.114.x** → the management ethernet; this is what `hostname -i`
  returns

So the hostfile is populated with **ib0 addresses**, which routes all cluster
RPC over InfiniBand. Get the address with the absolute path
`/usr/sbin/ip -4 -o addr show ib0` (a non-interactive ssh shell omits
`/usr/sbin` from `PATH`).

### Results

| Test | Nodes | Result |
|---|---|---|
| `clio-cluster-test.slurm` | 2 (c201-014/015) | **PASS** — bidirectional ib0 links, pools with 2 containers (one per node) |
| `clio-cluster-test-4node.slurm` | 4 (c201-014..017) | **PASS** — **full mesh**, pools with 4 containers (one per node) |

The 4-node run formed a full mesh (every node connected to every other) over
ib0 in ~8 s:

| Node (ib0) | Connects to |
|---|---|
| c201-014 (192.168.46.14, bootstrap) | .15, .16, .17 |
| c201-015 (192.168.46.15) | .14, .16, .17 |
| c201-016 (192.168.46.16) | .14, .15, .17 |
| c201-017 (192.168.46.17) | .14, .15, .16 |

Both cluster pools (`admin`, `ram::chi_default_bdev`) were created "with 4
containers (one per node)", and all 4 runtimes stayed alive.

### Cluster gotchas

| Issue | Fix |
|---|---|
| `--induct` is for adding a node to an **already-running** cluster; using it for initial formation causes an admin method-24 routing failure + bootstrap abort | start all nodes symmetrically, **no `--induct`** |
| `runtime start` **replays** `$HOME/.clio/restart_log.bin`, and `$HOME` auto-mounts into the container — a stale WAL from a prior ctest run gets replayed and can crash startup | isolate per-job: `CLIO_RESTART_LOG=<fresh path>` |
| `ip` not found over ssh | absolute path `/usr/sbin/ip` |
| reading peer state | compute→compute ssh works (BatchMode/key auth); this test routes every node's log into the shared `$WORK` dir so node 0 reads them all |

**PASS signals** (not the string `Loaded 2 hosts from hostfile` — that is not
logged in server mode): bidirectional `Connection established to <peer-ib0>:9413`
in every node's log, pools created "with N containers (one per node)", and all
N runtimes still alive.

---

## 4. Quick reference

```bash
# Build + test (single node, in-container)
sbatch bin/clio-build-ctest.slurm

# Cluster over InfiniBand
sbatch bin/clio-cluster-test.slurm         # 2 nodes
sbatch bin/clio-cluster-test-4node.slurm   # 4 nodes (edit -N to scale)

# Diagnostics
sbatch bin/clio-net-probe.slurm            # ib iface, ssh, clio_run-in-container
```

Load Apptainer inside jobs with `module load tacc-apptainer/1.4.1` (or the
absolute path `/opt/apps/tacc-apptainer/1.4.1/bin/apptainer`).
