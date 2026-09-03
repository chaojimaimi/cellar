# Cellar SMC Protocol

> How Cellar talks to the SMC coprocessor on macOS 26 / Apple Silicon for charging control, via the IOKit `AppleSMC` user client. This document is the public, implementation-facing reference distilled from the project's protocol findings — it states objective protocol facts only, in "verified on" form.

## Scope

Cellar uses SMC only on the **control paths** (enable/disable charging, adapter control during explicit discharge, and fan speed control in the opt-in smart fan cooling feature). All monitoring reads (charge level, voltage, current, temperature, cycle count, health, capacities, adapter details) come from `AppleSmartBattery` via IOKit and do not touch the SMC — see the README's "Root-free read-only monitoring" feature.

## Universal dispatch: selector 2 + `data8` sub-selectors

On macOS 26 the classic direct selectors have been **removed**: selector 5 (read) / 6 (write) / 9 (getKeyInfo) return `kIOReturnBadArgument (0xE00002C7)` for every caller, root included. The only working entry is the universal dispatch selector:

- **selector = 2** (the classic `KERNEL_INDEX_SMC`), with the operation carried in byte `data8` (buffer offset 42):
  - `5` = read key value
  - `6` = write key value
  - `8` = enumerate keys by index
  - `9` = getKeyInfo (key metadata)

The parameter buffer is the fixed 80-byte layout shared with the classic convention: `key` @ 0, `vers` @ 4 (6B), `pLimit` @ 12 (16B), `keyInfo` {dataSize @ 28, dataType @ 32, attributes @ 36}, `result` @ 40, `status` @ 41, `data8` @ 42, `data32` @ 44, `bytes[32]` @ 48.

## Key info protocol

Charging control on the tested Tahoe-generation firmware is a **single-key protocol**:

| Key | Type / size | Value protocol |
|---|---|---|
| `CHTE` | `ui32` / 4B | `00 00 00 00` = charging enabled · `01 00 00 00` = charging stopped |
| `CHIE` | `hex_` / 1B | `0x00` = adapter enabled · `0x08` = adapter disabled |

- `CHTE` is the core control key; writes take effect immediately and read-back matches the written value.
- `CHIE` is used **only during explicit discharge actions** (Discharge to Limit / the calibration discharge phase). It is never written by steady-state limit enforcement.
- Legacy charging keys (`CH0B` / `CH0C`, dual-key same-value stop) are **absent on the tested firmware** and belong to an older firmware generation.

## Byte order

- 4CC keys and the reply `dataType` are transported as **little-endian uint32**, i.e. the character order is **reversed inside the buffer**: `"CHTE"` is packed as `45 54 48 43`. Packing in natural order yields `kIOReturnBadArgument`-class failures (result 132).
- Key **value bytes are raw** — no transformation. `CHTE` `01 00 00 00` in the buffer is the literal value semantics.
- a 4CC `dataType` read back from the buffer must be re-derived with a little-endian uint32 read plus character-order reversal (e.g. `"23iu"` in the buffer → `ui32`).

## Two-phase read

Reads are strictly two-phase:

1. **getKeyInfo** (`data8` = 9) for the key → returns `dataSize` (and `dataType`).
2. **Sized read** (`data8` = 5): the input buffer's size field (offset 28) must carry the `dataSize` from step 1. Omitting it makes the driver return **result 137** (missing expected size), which maps to an `unexpectedResult` error in Cellar's `SMCResult` classification.

The key's reply does not echo `dataSize`; read results must be sliced to the size requested via getKeyInfo.

## Write privileges

- Key **metadata and values are readable without root** (verified with a non-root user).
- **Writes require root**: a privileged write attempt returns `0xE00002C1` (`NotPrivileged`). This is why all writes in Cellar go through the root daemon — see SECURITY.md for the permissions model.

## Runtime probe, not machine whitelists

Key availability varies with firmware generation, so Cellar **runtime-probes** the key table instead of shipping machine whitelists:

- `CHTE` readable → **Tahoe backend** (preferred; this is the tested path).
- else `CH0B`/`CH0C` present → **Legacy backend** (older systems; untested).
- neither → **read-only mode** (monitoring still works).

## Fan control keys (Phase 5 v1.1)

Smart fan cooling (opt-in, off by default) targets the **first fan (F0)** only. Verified on the same firmware generation as the charging keys:

| Key | Type / size | Role |
|---|---|---|
| `F0Tg` | `flt` / 4B | Target fan speed (rpm) |
| `F0Md` | 1B | Fan mode: `0x00` = system automatic · `0x01` = manual direct-write |
| `F0Ac` | `flt` / 4B | Actual fan speed (rpm) — live value that follows the target |
| `F0Mn` / `F0Mx` | `flt` / 4B | Minimum / maximum rpm — **read-only** (writes are refused by firmware) |

Protocol facts (verified on macOS 26.x / Apple M2 Max, firmware 18000.161.10):

- `flt` values are packed **little-endian** IEEE-754 single precision (e.g. `1350.0` → `00 C0 A8 44`).
- Writes to `F0Tg` are **rejected by firmware while `F0Md` = 0** (read-back returns the old value). The unlock sequence is: write `F0Md` = 1, verify read-back, then write `F0Tg`. The release sequence writes `F0Tg` back to the pre-boost snapshot, then `F0Md` = 0 to hand control back to the system.
- `F0Tg` writes at or above the minimum (`F0Mn`) are clamped into `[F0Mn, F0Mx]` by the daemon; Cellar never writes values below the system baseline.
- Writes require root, like all SMC control keys — fan writes happen only in the root daemon.
- The daemon verifies write-follow by checking `F0Ac` ≥ written target − 300 rpm, and detects external writers by read-back drift of `F0Tg`.

The `setFan` XPC command carries fan parameters as UINT64 keys; the `fanStrategy` wire mapping is append-only: `0` = constantSpeed, `1` = minRaise (currently rejected, reserved), `2` = twoStage, `3` = emergency.

## Verification statement

The protocol facts above were verified on:

- **macOS 26.x / Apple M2 Max (Mac14,6), system firmware 18000.161.10** (read/write round-trips on `CHTE` and `CHIE`).

Older macOS generations and other firmware generations are **untested**; the legacy keys (`CH0B`/`CH0C`) are absent on the tested firmware. Expect protocol drift across firmware generations and re-verify with the runtime probe when supporting new hardware, rather than trusting this table.

## Swift packing caveat

Do **not** replicate the 80-byte parameter structure with a Swift `struct`: the observed Swift nested layout is 76 bytes, which does not match the C ABI 80-byte layout and fails against the driver. The shipped implementation hand-packs a fixed-length `[UInt8]` buffer (see `Sources/CellarCore/SMC/SMCParam.swift`).

## Implementation references

- `Sources/CellarCore/SMC/SMCCommand.swift` — `data8` opcodes (read 5 / write 6 / keyInfo 9), selector 2 fixed in the transport
- `Sources/CellarCore/SMC/SMCClient.swift` & `SMCResult.swift` — two-phase read flow, result 137 classification
- `Sources/CellarCore/Control/TahoeBackend.swift` — `CHTE` / `CHIE` value mapping
- `Sources/CellarCore/Daemon/Discharge.swift` — `CHIE` enabled/disabled byte constants (`[0x00]` / `[0x08]`) and the guarantee that `CHIE` writes happen only during explicit discharge