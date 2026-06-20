# Vendored libdivecomputer

This directory contains a snapshot of [libdivecomputer](https://github.com/libdivecomputer/libdivecomputer)
compiled as a SwiftPM target (autotools is not available in SwiftPM, so the library is vendored directly).

## Current snapshot

| Field | Value |
|---|---|
| Upstream commit | `720edf385679cddb2f8c049453a35be198b6d9aa` |
| Upstream date | 2026-05-28 |
| Version | 0.10.0 |

## version.h

`include/libdivecomputer/version.h` is hand-derived from `include/libdivecomputer/version.h.in`
(the autotools-generated variant). Update it manually whenever the snapshot is bumped.

## Files not copied from upstream

| File | Reason |
|---|---|
| `src/serial_win32.c` | Windows only; already listed in `exclude` in `Package.swift` |
| `src/libdivecomputer.rc` | Windows resource script; not needed on Apple platforms |

## How to update

1. Clone the upstream repo:
   ```
   git clone --depth=1 https://github.com/libdivecomputer/libdivecomputer /tmp/libdivecomputer-upstream
   ```
2. Compare file lists (`src/` and `include/libdivecomputer/`) for new or removed files.
3. Copy changed files, skipping the Windows-only ones listed above.
4. Update `version.h` manually from `version.h.in` and the version defined in `configure.ac`.
5. Update the commit SHA and date in this file.
6. Build the project to confirm no regressions.
