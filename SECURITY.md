# Security Policy

## Overview

Cellar is an open-source battery charge-limiting tool for Apple Silicon Macs: a menu-bar app plus a CLI, backed by a root LaunchDaemon. It is free, open source (GPL-3.0), ships with **no telemetry**, and its **only outbound network traffic is one read-only GitHub update check** (details below).

## Why root / permissions model

On Apple Silicon Macs, charging control is executed by the SMC coprocessor. Third-party control therefore requires writing SMC keys through the IOKit `AppleSMC` user client, and **writes are root-only**.

Cellar's daemon writes exactly two SMC keys:

| Key | Type / size | Meaning |
|---|---|---|
| `CHTE` | `ui32` / 4B | Charging enable/disable (the core control key) |
| `CHIE` | `hex_` / 1B | Adapter enable/disable — used **only** during explicit discharge actions |

All other monitoring reads use `AppleSmartBattery` via IOKit and need no privileges.

## What Cellar does / does not do

**Does:**

- Enforce a user-configured charge limit with hysteresis (default recovery threshold: limit −2%)
- Provide a manual battery-calibration cycle ("Charge to Full once" → rest → discharge → restore limit)
- Provide a manual "Discharge to Limit" action (adapter power-cut until the battery drains to the limit) and an opt-in CHIE hysteresis fallback channel
- Apply a thermal pause: charging pauses at battery ≥ 40 °C and resumes below 37 °C
- Detect competing charging tools and refuse or warn on coexistence
- Check GitHub Releases for a newer version (read-only; see "Network surface" below)

**Does not:**

- Collect telemetry
- Access any network endpoint other than the single update-check request below
- Automatically download or install updates
- Read user data
- Persist anything outside `/Library/Application Support/Cellar/` (`policy.json`, `action.json` — an atomic-write design) and standard log streams

## Network surface

The only outbound network request is the update check, performed by the App (never the daemon, which has no networking code at all):

- **Endpoint**: `GET https://api.github.com/repos/chaojimaimi/cellar/releases/latest` — read-only, unauthenticated, no query parameters, no request body, no telemetry identifiers.
- **Trigger**: at App launch, at most once every 24 hours (a throttle stamp is written only after a successful check — a failed check stays silent and retries on the next launch); plus an explicit "Check for Updates" button on the About page.
- **Timeout**: 10 seconds. Any failure is silent (os_log only).
- **Rendering**: if a newer version is detected, the About page shows the version and a "Download" link. The link is validated against a strict allowlist before `NSWorkspace.open` (scheme must be `https` and host must be `github.com`; anything else is refused, fail-closed). A one-line local notification may fire once per new version.
- **No auto-download / auto-install**: updating is always a manual user action.

## Threat model & mitigations

- **XPC surface**: the daemon exposes the `com.cellar.daemon` mach service. Mutating commands require root or admin-group membership (gid 80); read-only status queries are unauthenticated **by design** — they expose only information equivalent to public IOKit power info.
- **Parameter validation**: all parameters are whitelisted with type checks.
- **Policy floor**: a 60% minimum charge limit is enforced at three layers, including a validated reload of the persisted policy, so tampered files cannot bypass it.
- **Write integrity**: every SMC write is followed by a write-after-read verification; verification failures (including external-writer conflicts) are reported as typed errors instead of failing silently.
- **Conflict detection**: an installation-time and runtime scan detects known competing charging tools; exact matches hard-block, generic matches warn.
- **Single-instance guarantee**: a cross-process `flock` on `/var/run/com.cellar.daemon.lock` prevents two daemons from running concurrently.
- **Recoverability red line**: SIGTERM/SIGHUP handling and crash paths restore the system default charging behavior, so a killed or crashed daemon never leaves charging disabled indefinitely.

**Known design decisions** (documented trade-offs, not vulnerabilities):

- Status queries are unauthenticated (information-equivalent to public IOKit power info; no mutation possible).
- There is no peer code-signing requirement for XPC clients; this was relaxed to admin-group membership in an earlier phase after review. The attack surface is limited to charging-policy manipulation — no privilege escalation or data exposure is possible through this path.
- `os_log` entries are public-privacy by convention; they reference only fixed, documented file paths.

## Build & distribution integrity

- Releases are **ad-hoc signed** (no Developer ID). Gatekeeper will prompt on first launch; the README documents the `xattr -cr /Applications/Cellar.app` workaround.
- Each GitHub Release publishes the **SHA-256 checksum of the release zip** — verify the artifact against it before use.
- Building from source reproduces the same binaries via `swift build` (CLI/daemon) or Xcode (App). When in doubt, build from source and compare.

## Supported versions

- **macOS 26+ on Apple Silicon** — this is the only supported platform.
- Earlier macOS generations are untested and unsupported; SMC key generations differ across firmware versions, and keys are runtime-probed rather than hard-coded.

## Reporting a vulnerability

- Use **GitHub Security Advisories** (“Report a vulnerability” on the repository) — do **not** open public issues for security findings.
- Response target: initial acknowledgment within **7 days**.