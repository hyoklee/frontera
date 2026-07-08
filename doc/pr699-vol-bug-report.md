# Bug report for PR #699 — iowarp HDF5 VOL connector + neuroh5 (MiV case 6)

Tested PR #699 (`iowarp/clio-core`, head `64008d3f`) end-to-end with
MiV-Simulator **case 6** (`6-gapjunctions`) on TACC Frontera, inside an Apptainer
container (Ubuntu 24.04 / glibc 2.39; `neuroh5` + NEURON + MiV built against a
parallel HDF5 1.14.6). Summary: **PR #699 builds and loads correctly and the VOL
connector attaches to the CTE runtime, but MiV case 6 does not run through it.**
The primary blocker is **not** in the connector — it is a deprecated-API issue in
neuroh5 — and there is a second blocker after that.

## Environment note (build gotcha)

The connector must link the **same** HDF5 as the application. The Ubuntu base
image ships a **serial** HDF5 2.1.1 CONFIG package at `/usr/local/cmake`, which
`find_package(HDF5 CONFIG)` picks up first — so the connector linked
`libhdf5.so.320` while neuroh5/run-network use parallel `/opt/hdf5`'s
`libhdf5.so.310`. Two HDF5s in one process → segfault in
`H5CX_get_vol_connector_prop` on the first `H5Fopen`. Worked around with
`-DCMAKE_IGNORE_PATH=/usr/local/cmake -DHDF5_ROOT=/opt/hdf5` and building with
`mpicxx` (parallel HDF5 headers pull in `mpi.h`). Consider having the VOL build
prefer a parallel HDF5 / warn on a serial one.

## Blocker 1 (root cause): deprecated `H5Literate1` is rejected under any VOL

MiV case 6 aborts during population discovery:

```
Assertion 'H5Literate(grp, H5_INDEX_NAME, H5_ITER_NATIVE, &idx, &iterate_cb, ...) >= 0'
  failed in neuroh5/src/cell/cell_populations.cc:83
```

Minimal repro (`H5Literate` on `/Populations`, file opened with the MPI-IO fapl
as neuroh5 does), with the HDF5 error stack printed:

```
VOL + MPI-IO, v2 API (H5Literate2):  returns 0, lists OLM/PVBC/PYR/STIM   ✅
VOL + MPI-IO, v1 API (H5Literate1):  returns -1                          ❌
  #000: H5Ldeprec.c line 172 in H5Literate1():
        "H5Literate1 is only meant to be used with the native VOL connector"
        major: Links   minor: Bad value
```

So HDF5 itself forbids the **deprecated v1** `H5Literate1` under a non-native VOL
connector; only `H5Literate2` works. neuroh5 is built with `-DH5_USE_110_API`,
which maps its unversioned `H5Literate` to `H5Literate1` — hence every group
enumeration fails whenever the iowarp VOL (or any non-native VOL) is active.
**This is not fixable in the connector or by #699.**

### Fix (neuroh5)

Switch the 8 iteration call sites + their callbacks from the v1 macros to the
versioned `H5Literate2` / `H5L_info2_t` (which work with both native and
non-native VOLs; the callbacks only use the link name, so the info-struct
version is inert). Patch: `hyoklee/neuroh5` branch `fix/vol-h5literate2`
(`28b6d83`). Files: `src/hdf5/{read_link_names,group_contents}.cc`,
`src/cell/{cell_attributes,cell_populations}.cc`,
`src/graph/{edge,node}_attributes.cc`.

Verified: with this patch, case 6 gets **past** population enumeration through
the iowarp VOL (no more `H5Literate` abort).

## Blocker 2 (after the neuroh5 fix): `read_cell_attribute_info` drops populations

With the H5Literate2 patch, run-network proceeds further, then fails in MiV:

```
File ".../miv_simulator/network.py", line 858, in make_cells
    f"population attributes are {env.cell_attribute_info[pop_name]}"
KeyError: 'OLM'
```

i.e. `neuroh5.io.read_cell_attribute_info(...)` returns a population→namespace
map that is **missing populations** when read through the iowarp VOL, whereas
the identical call over native HDF5 returns all four populations (the native arm
of the same job runs to completion). No further deprecated `*1` APIs remain in
neuroh5 (all iteration is now `H5Literate2`), so this looks like a VOL-side
enumeration/read-correctness issue — possibly interaction with the
selection-aware read caching in this PR. Not yet root-caused.

## Repro assets

- Container build + run scripts: `hyoklee/frontera` `bin/build-clio-iowarp.slurm`,
  `bin/run-case6-vol.slurm`, `bin/chimaera_case6.yaml`.
- Minimal C repro: `vol_iter_repro.c` (compile with/without `-DH5_USE_110_API`
  to toggle v1/v2; run through the VOL via `HDF5_VOL_CONNECTOR=iowarp`).
- Full context: `hyoklee/frontera` `doc/miv-case6-frontera.md`.

## Asks

1. Land the neuroh5 `H5Literate2` fix (PR to `iraikov/neuroh5` / `hyoklee/neuroh5`).
2. Investigate `read_cell_attribute_info` under the VOL (Blocker 2) — does the
   connector correctly serve the small attribute-index/metadata reads used to
   enumerate per-population namespaces?
3. (Nice to have) make the VOL build fail loudly if it links a *serial* HDF5.
