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

**Full-length run (tstop=2000, `TSTOP=2000 sbatch run-case6.slurm`):** completed
in 13m22s — generate-gapjunctions 22 s, run-network 764 s (created cells 0.72 s,
connected cells 51.23 s, ran simulation 657.40 s), load balance 0.99, output
2.87 MB. The simulation phase scales ~linearly with tstop (15.4 s → 657 s for
40× longer), confirming the full case runs cleanly.

For scale, the ares baseline (native HDF5, tstop=50, 4 ranks/node) reported
created 6.5 s / connected 215 s / sim 52 s / total 305 s; Frontera (8 ranks on
one Cascade-Lake node) is substantially faster on this small circuit.

## clio-core (IOWarp) vs native — comparison

clio-core was rebuilt with the CTE **POSIX adapter** (`CLIO_CORE_ENABLE_ELF=ON`
→ `libclio_cte_posix.so` + `clio_run`) inside the same container
([`../bin/build-clio-iowarp.slurm`](../bin/build-clio-iowarp.slurm)). The IOWarp
arm starts `clio_run` with a RAM CTE tier
([`../bin/chimaera_case6.yaml`](../bin/chimaera_case6.yaml)) and
`LD_PRELOAD=libclio_cte_posix.so` into `run-network`. Both arms run back-to-back
on the **same node** ([`../bin/run-case6-compare.slurm`](../bin/run-case6-compare.slurm)),
8 ranks, tstop=50.

| Phase | Native | IOWarp |
|---|---:|---:|
| created cells | 0.72 s | 0.72 s |
| connected cells | 43.25 s | 43.54 s |
| created gap junctions | 0.02 s | 0.02 s |
| ran simulation (50 ms) | 15.14 s | 15.30 s |
| **run-network total** | **64 s** | **63 s** |

Load balance 0.98 / 0.99; both arms produce byte-identical results
(`Microcircuit_Small_results.h5`, 168443 B). **IOWarp shows no benefit and no
penalty (within run-to-run noise).**

This is consistent with — and cleaner than — the prior ares result
([miv_iowarp_ares_case6.md](../../NeuroFAIR/wiki/miv_iowarp_ares_case6.md)),
which found IOWarp ~15% *slower* for this **compute-bound, ~45 MB read-once**
workload. Case 6 is simply the wrong regime for a bandwidth-oriented I/O
accelerator (CTE's wins are large, repeated-read, bandwidth-bound I/O).

**Caveat:** unlike ares, the *compute* phases here are unchanged too — the
blanket-syscall-interception overhead ares saw did not appear, indicating the
POSIX adapter was **not on the bulk-I/O hot path** in this configuration (likely
`LD_PRELOAD` not propagating to all mpirun ranks, and/or neuroh5 using MPI-IO
rather than plain POSIX, which the POSIX adapter does not intercept). The
qualitative conclusion (no benefit for case 6) holds regardless; forcing full
interception (mpich `-genv LD_PRELOAD`, POSIX-mode HDF5) would only be expected
to reproduce the ares slowdown.

## clio-core HDF5 VOL adapter vs native

The ares analysis noted the POSIX adapter misses neuroh5's bulk transfers and
that an **HDF5 VOL/VFD** adapter is the right interception point. clio-core's
`iowarp` VOL connector (`CLIO_CTE_ENABLE_HDF5_VOL=ON` → `libiowarp_hdf5_vol.so`)
is a **passthrough** connector that intercepts `H5Dwrite`/`H5Dread` →
CTE `PutBlob`/`GetBlob` (falls back to the native VOL for collective MPI-IO) and
loads via `HDF5_VOL_CONNECTOR=iowarp` + `HDF5_PLUGIN_PATH`
([`../bin/build-clio-iowarp.slurm`](../bin/build-clio-iowarp.slurm),
[`../bin/run-case6-vol.slurm`](../bin/run-case6-vol.slurm)).

**Outcome: the VOL connector builds and loads correctly and attaches to the CTE
runtime, but the end-to-end case-6 comparison could not be completed** — it
aborts during neuroh5's population enumeration:
```
Assertion 'H5Literate(grp, ...) >= 0' failed in neuroh5/src/cell/cell_populations.cc:83
```

Diagnosis (each step verified):
1. **HDF5 duality (fixed).** The base image ships a *serial* HDF5 2.1.1 at
   `/usr/local` whose CMake CONFIG package the connector picked up first, so it
   linked `libhdf5.so.320` while run-network uses `/opt/hdf5` `libhdf5.so.310`
   → two HDF5s in one process → segfault in `H5CX_get_vol_connector_prop`. Fixed
   with `-DCMAKE_IGNORE_PATH=/usr/local/cmake` (+ `HDF5_ROOT=/opt/hdf5`) and
   `mpicxx` (parallel HDF5 headers need `mpi.h`); `ldd` then confirms the
   connector links `/opt/hdf5/lib/libhdf5.so.310`.
2. **Serial iteration works.** A single-process `h5ls` through the connector
   lists the populations correctly (`OLM/PVBC/PYR/STIM`, rc=0) — `H5Literate` is
   fine on an independent (non-MPI) fapl.
3. **Parallel iteration fails.** neuroh5 always opens files with the **MPI-IO
   (collective) fapl**, and `H5Literate` fails through the connector in that mode
   — at both 8 ranks and 1 rank. So it is a clio-core VOL-connector limitation
   for **parallel/collective HDF5 metadata iteration**, not a rank-count or
   setup issue.

Net: the VOL connector is the correct *interception point* (dataset-level, the
actual neuroh5 hot path) and works serially, but is not yet functional for
neuroh5's parallel MPI-IO access pattern on this clio-core build. Completing the
comparison would require fixing the connector's collective-metadata iteration
(a clio-core change) — and per the compute-bound analysis above, even a working
VOL is not expected to speed up this small, read-once workload; its value would
be on large, bandwidth-bound, repeated-read circuits.

## Reproduce

```bash
cd /work2/11623/hyoklee/frontera.hyoklee/bin
sbatch build-miv-sif.slurm        # build miv-stack.sif (once)
sbatch construct-case6-data.slurm # generate dataset onto /scratch2
sbatch run-case6.slurm            # run case 6 (TSTOP=50 default; TSTOP=2000 for full)
sbatch build-clio-iowarp.slurm    # clio-core with POSIX + HDF5 VOL adapters
sbatch run-case6-compare.slurm    # native vs IOWarp POSIX adapter
sbatch run-case6-vol.slurm        # native vs HDF5 VOL connector
```
