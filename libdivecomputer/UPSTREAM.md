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

## Swift wrapper checklist

After updating the C library, check `descriptor.c` for new or changed entries and update the Swift wrapper accordingly:

- **`Sources/LibDCSwift/BLEManager.swift`** — `knownSerialServices`: add a `SerialService` entry for every new BLE service UUID. Missing entries make devices invisible to the CoreBluetooth scan.
- **`Sources/LibDCSwift/Models/DeviceConfiguration.swift`**:
  - `supportedModels`: add a `ComputerModel` entry for each new BLE-capable device. Use the model ID from `descriptor.c`, not the hardware-reported value.
  - `DeviceFamily` enum: add a case for each new `DC_FAMILY_*` constant, with matching `asDCFamily` and `init?(dcFamily:)` entries.
  - `knownServiceUUIDs`: add the BLE service UUID (must match the entry in `knownSerialServices`).
  - `bleNamePrefixes`: for families where the C BLE filter covers multiple models, add prefix entries ordered most-specific-first. Verify the prefix string against the `dc_filter_*` function in `descriptor.c` — it must match the actual BLE advertisement name, not just the display name.
