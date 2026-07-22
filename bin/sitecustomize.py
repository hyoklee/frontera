"""VOL-compatibility shim for the MiV stack under the clio HDF5 VOL connector.

Auto-imported by CPython at interpreter startup when this directory is on
PYTHONPATH (clio_vol_env.sh adds it only for VOL runs). It is a NO-OP unless
HDF5_VOL_CONNECTOR is set, so native (non-VOL) runs are completely unaffected.

Why it exists
-------------
h5py's ``File(path, "a")`` opens the file read-write and, if that open fails,
falls back to creating it — but ONLY if the failure surfaces as
``FileNotFoundError``. h5py derives ``FileNotFoundError`` from the top of the
HDF5 error stack. Through a *non-native* VOL connector, HDF5's H5VL layer wraps
the underlying "file not found" (errno=2) as a generic
"Virtual Object Layer / Can't open object" error, so h5py raises a plain
``OSError`` instead — its create-fallback is skipped and ``File(path, "a")``
fails on a not-yet-existing file. This breaks MiV-Simulator's ``mkout`` (results
file) and every other ``h5py.File(..., "a")`` site.

The connector cannot fix this: the masking H5VL error frame is added by HDF5
itself, above the connector. So we make the mode-"a" open VOL-robust here:
when the target file does not exist, create it (mode "x"); a lost create race
falls back to a plain append open (the file now exists, which the connector
handles correctly).
"""
import os

if os.environ.get("HDF5_VOL_CONNECTOR"):
    try:
        import h5py as _h5py

        _orig_File = _h5py.File

        def _vol_safe_File(name, mode="r", *args, **kwargs):
            # Only mode "a" on a not-yet-existing file trips the h5py+non-native
            # -VOL FileNotFoundError-detection gap; every other case is native.
            if mode == "a":
                try:
                    _absent = not os.path.exists(name)
                except Exception:
                    _absent = False
                if _absent:
                    try:
                        return _orig_File(name, "x", *args, **kwargs)  # create
                    except (OSError, IOError):
                        # A peer rank created it first: fall through to append.
                        return _orig_File(name, "a", *args, **kwargs)
            return _orig_File(name, mode, *args, **kwargs)

        _vol_safe_File.__wrapped__ = _orig_File
        _h5py.File = _vol_safe_File
    except Exception:
        # Never break interpreter startup because of the shim.
        pass
