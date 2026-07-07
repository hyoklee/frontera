# MiV-Simulator Case 6 (gap junctions) on TACC Frontera

End-to-end run of **MiV-Simulator case 6 (`6-gapjunctions`)** on Frontera, using
**MiV-Simulator + neuroh5 + NEURON** with native parallel HDF5, all inside an
Apptainer container (Frontera's el7/glibc-2.17 host cannot run modern
conda-forge/manylinux binaries natively — see
[clio-core-on-frontera.md](clio-core-on-frontera.md)).

**Status: PASS** — dataset generated and the simulation ran to completion.

## Software stack (container `miv-stack.sif`, 2.3 GB)

Built on top of `clio-deps-cpu.sif` (Ubuntu 24.04, glibc 2.39) via
[`../bin/miv-stack.def`](../bin/miv-stack.def):

| Component | Version / source |
|---|---|
| MPI | MPICH (apt) |
| Parallel HDF5 | 1.14.6, built from source (`--enable-parallel`) into `/opt/hdf5` |
| Python | 3.12 venv `/opt/miv-venv` |
| numpy | **1.26.4** (pinned `<2`; MiV uses `np.row_stack`/`np.float_`, removed in NumPy 2) |
| mpi4py | 4.1.2 (from source vs MPICH) |
| h5py | 3.16.0, **parallel** (`mpi=True`, from source vs `/opt/hdf5`) |
| NEURON | pip wheel (`neuron>=9.0a0`) |
| neuroh5 | `hyoklee/neuroh5@master` (carries the alltoallv int-overflow fix) |
| MiV-Simulator | `hyoklee/MiV-Simulator@vista-arm-fix` (carries the case-6 gap-junction mechanism fix) |

Key build gotchas (all resolved in the def):
- Ubuntu multiarch apt HDF5 makes CMake/h5py pick the **serial** variant → build
  parallel HDF5 from source into a clean prefix.
- `%files`-copied repos inherited host `0700` perms → unreadable by the runtime
  (non-root) user → `chmod -R a+rX /opt` in `%post`.
- neuroh5 C++ tools run by absolute path from an executable scratch copy.

## Dataset (generated on `/scratch2`, [`../bin/construct-case6-data.slurm`](../bin/construct-case6-data.slurm))

The case-6 input cells file is not in the repo (the prior copy lives on Aurora),
so it is regenerated from the `.swc` morphologies via the case-1 construction
pipeline: `make-h5types` → `generate-soma-coordinates` → **`measure-distances`**
(writes the Arc Distances the connection generator needs) → `neurotrees_import`
→ `neurotrees_copy --fill` → `distribute-synapse-locs` → `generate-distance-connections`
→ input features/spikes → h5py/h5copy **assembly** into the combined files.

| File | Size | Matches ares reference |
|---|---|---|
| `MiV_Cells_Microcircuit_Small_20220410.h5` | 36.5 MB | ✓ (36 MB) |
| `MiV_Connections_Microcircuit_Small_20220410.h5` | 8.9 MB | ✓ (8.9 MB) |

Circuit: Microcircuit_Small — PYR/PVBC/OLM/STIM, ~177 cells, + gap junctions.

## Case-6 run ([`../bin/run-case6.slurm`](../bin/run-case6.slurm), 1 node, 8 MPI ranks)

`make-h5types --gap-junctions` → `generate-gapjunctions` → `run-network`
(native parallel HDF5, `tstop=50` validation run):

| Phase | Time |
|---|---:|
| generate-gapjunctions (8 ranks) | 22 s |
| **run-network total (tstop=50)** | **65 s** |
| — created cells | 0.78 s |
| — connected cells | 45.04 s |
| — created gap junctions | 0.02 s |
| — ran simulation (50 ms) | 15.41 s |

Load balance 0.98. Output: `results/runs/Microcircuit_Small_results.h5`.

For scale, the ares baseline (native HDF5, tstop=50, 4 ranks/node) reported
created 6.5 s / connected 215 s / sim 52 s / total 305 s; Frontera (8 ranks on
one Cascade-Lake node) is substantially faster on this small circuit.

## clio-core (IOWarp) comparison — status

The `NeuroFAIR/claude.md` goal is to compare wall time **with vs without**
clio-core's CTE POSIX adapter (`LD_PRELOAD=libclio_cte_posix.so` + chimaera
runtime). This Frontera run establishes the **native-HDF5 baseline**. The
IOWarp arm is not yet built here: the current `clio-deps-cpu.sif`/boost build
does not include the POSIX adapter (`CLIO_CORE_ENABLE_ELF=ON`). Prior end-to-end
work on **ares** ([miv_iowarp_ares_case6.md](../../NeuroFAIR/wiki/miv_iowarp_ares_case6.md))
found IOWarp ~15% *slower* for this **compute-bound, ~45 MB read-once** workload
and hanging multi-node — the wrong regime for a bandwidth-oriented I/O
accelerator. Reproducing that comparison on Frontera is the natural next step
but is expected to confirm the negative result.

## Reproduce

```bash
cd /work2/11623/hyoklee/frontera.hyoklee/bin
sbatch build-miv-sif.slurm        # build miv-stack.sif (once)
sbatch construct-case6-data.slurm # generate dataset onto /scratch2
sbatch run-case6.slurm            # run case 6 (TSTOP=50 default; TSTOP=2000 for full)
```
