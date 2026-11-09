# Security Policy

## Overview

Cellar is an open-source battery charge-limiting tool for Apple Silicon Macs: a menu-bar app plus a CLI, backed by a root LaunchDaemon. It is free, open source (GPL-3.0), ships with **no telemetry**, and its only outbound network traffic is the **Sparkle update channel** (a daily appcast check plus, only after your explicit confirmation, the update package download — details below). The daemon has no networking code at all.

## Why root / permissions model

On Apple Silicon Macs, charging control is executed by the SMC coprocessor. Third-party control therefore requires writing SMC keys through the IOKit `AppleSMC` user client, and **writes are root-only**.

The daemon writes a small, fixed set of SMC keys in two tiers:

**Core charging keys** (the always-on control surface):

| Key | Type / size | Meaning |
|---|---|---|
| `CHTE` | `ui32` / 4B | Charging enable/disable (the core control key) |
| `CHIE` | `hex_` / 1B | Adapter enable/disable — used **only** during explicit discharge actions |

**Conditional feature keys** (written only while the corresponding opt-in feature is active):

| Key | Type / size | Meaning |
|---|---|---|
| `F0Md` / `F0Tg` | `ui8` 1B / `flt` 4B | Fan 0 manual-mode flag / target RPM — written only while fan takeover is enabled; the target RPM is clamped into the fan's read-only `[Mn, Mx]` bounds and every write is verified by write-after-read; original values are restored when takeover ends, and crash/sleep residues are recovered at startup |
| `F1Md` / `F1Tg` | `ui8` 1B / `flt` 4B | Same as above for fan 1 (dual-fan machines only) |
| `ACLC` | `ui8` / 1B | MagSafe LED mode byte — written only when the user explicitly configures the LED mode (`0x00` hands control back to the system) |

All other monitoring reads use `AppleSmartBattery` via IOKit and need no privileges.

## What Cellar does / does not do

**Does:**

- Enforce a user-configured charge limit with hysteresis (default recovery threshold: limit −2%)
- Provide a manual battery-calibration cycle ("Charge to Full once" → rest → discharge → restore limit)
- Provide a manual "Discharge to Limit" action (adapter power-cut until the battery drains to the limit) and an opt-in CHIE hysteresis fallback channel
- Apply a thermal pause: charging pauses at battery ≥ 40 °C and resumes below 37 °C
- Detect competing charging tools and refuse or warn on coexistence
- Check GitHub Releases daily for a newer version via **Sparkle 2** with **EdDSA signature verification** (see "Network surface" below); offer to install it only after the user confirms in the update window

**Does not:**

- Collect telemetry (`SUSendSystemProfile` is explicitly `false`; no profile data is sent with update checks)
- Access any network endpoint other than the update-channel requests below
- Automatically download or install updates (`SUAllowsAutomaticUpdates` is explicitly `false` — the update window offers no "automatically download" option; every install is a user-confirmed action)
- Read user data
- Persist anything outside the following fixed list: `/Library/Application Support/Cellar/` (five JSON files — `policy.json`, `action.json`, `calibration-state.json`, `schedule-state.json`, `topoff-state.json`, all atomic-write), the `/var/root/Library/Preferences/com.apple.smartcharging.topoffprotection` defaults domain (written through the `/usr/bin/defaults` subprocess for the topoff-protection channel), the `/var/run/com.cellar.daemon.lock` flock file (single-instance guarantee), and `/Library/Logs/Cellar/daemon.log` (launchd `StandardErrorPath`)

## Network surface

All update traffic is performed by the App (never the daemon, which has no networking code at all) through **Sparkle 2** with the standard user driver. Two distinct outbound flows, stated separately for honesty — **"no automatic download/install" is not the same as "no automatic network checking"**:

1. **Appcast check (automatic, daily)**: Sparkle fetches `https://github.com/chaojimaimi/cellar/releases/latest/download/appcast.xml` at most once every 24 hours (plus on demand via the About page's "Check for Updates" button). This is a small read-only XML GET. GitHub answers `latest/download` with an HTTP redirect to its release-asset download hosts (`release-assets.githubusercontent.com` / `objects.githubusercontent.com`); Sparkle's URLSession follows that 302 — these domains are part of the update channel by design.
2. **Update package download (user-triggered only)**: if the appcast advertises a newer version, Sparkle shows an update window. **Nothing is downloaded until you press "Install Update"** in that window; the package is then fetched from the redirect chain of the same GitHub download hosts and installed after EdDSA verification (below).

- **No telemetry**: `SUSendSystemProfile = false` is hard-coded in Info.plist — Sparkle sends no system-profile payload with any request. The appcast request carries no identifiers beyond what TLS and GitHub's CDN see for any download.
- **EdDSA verification boundary (zip only)**: every appcast entry carries an EdDSA (`sparkle:edSignature`) signature over the release **zip**; Sparkle refuses to install a package whose signature does not verify against the public key pinned in the App's Info.plist. **The .dmg attached to each release is a manual-install convenience and is NOT covered by EdDSA verification** — if you install manually from the dmg, you are relying on GitHub TLS transport and repository integrity (plus the published SHA-256 checksums), not on signature verification.
- **What this replaces**: before 0.23.3 the app used a hand-rolled update checker (single `api.github.com` read-only GET + URL allowlist). That mechanism was retired in favor of the EdDSA-verified Sparkle channel, which is the stronger primitive.

## Threat model & mitigations

- **XPC surface**: the daemon exposes the `com.cellar.daemon` mach service. Mutating commands require root, or (non-root) admin-group membership (gid 80) **plus code-identity pinning** — since 0.23.13, on App-route deployments (daemon inside the App bundle) the daemon derives the expected App-bundle anchor from its own executable path at startup, and per mutating command re-extracts the client's code identity from the XPC message itself (public `SecCodeCreateWithXPCMessage` API — message-bound, no stale-token surface) and requires an exact match of the main-executable path, the bundle identifier (`com.cellar.app`) and a valid signature; anything else is rejected fail-closed with a dedicated error message. Same-admin-user session malware can therefore no longer drive mutating commands through this path on App-route deployments. Manual (CLI-route) installs have no trusted anchor and keep the plain admin-group gate — an honest degradation, announced once in the daemon log. A 0.23.13 attempt to enable hardened runtime (the complementary measure against injecting the pinned host process) was **reverted in 0.23.14** after real-machine testing: the ad-hoc-signed App cannot satisfy library validation's team match against the embedded Sparkle framework (different Team IDs), which killed the app at dyld load. Without hardened runtime, dylib injection into the running App remains possible for same-user attackers — this widens the residual to *targeted* attacks (injection or bundle rewriting, as with the limitation above); re-introduction of hardened runtime requires first re-signing the embedded Sparkle chain so team identifiers match (registered follow-up). Read-only status queries are unauthenticated **by design**. Stated honestly, the status payload goes beyond public IOKit power info: it also includes the charging schedule JSON (weekly/time-of-day charging metadata), last-calibration timestamps, and the thermal policy — behavioral metadata with no credentials and no user identity. On a multi-user machine this is a mild privacy surface; trimming the payload is registered as a follow-up item.
- **Parameter validation**: all parameters are whitelisted with type checks.
- **Policy floor**: a 60% minimum charge limit is enforced at three layers, including a validated reload of the persisted policy, so tampered files cannot bypass it.
- **Write integrity**: every SMC write is followed by a write-after-read verification; verification failures (including external-writer conflicts) are reported as typed errors instead of failing silently.
- **Conflict detection**: an installation-time and runtime scan detects known competing charging tools; exact matches hard-block, generic matches warn.
- **Single-instance guarantee**: a cross-process `flock` on `/var/run/com.cellar.daemon.lock` prevents two daemons from running concurrently.
- **Recoverability red line**: SIGTERM/SIGHUP handling and crash paths restore the system default charging behavior, so a killed or crashed daemon never leaves charging disabled indefinitely.

**Known design decisions** (documented trade-offs, not vulnerabilities):

- Status queries are unauthenticated (behavioral metadata beyond public IOKit power info as noted above — schedule, last-calibration and thermal-policy fields; no credentials, no user identity, and no mutation is possible through this path).
- XPC client authentication evolution: before 0.23.13 there was no peer code-signing requirement for XPC clients (relaxed to admin-group membership in an earlier phase after review; the attack surface was limited to charging-policy manipulation — no privilege escalation or data exposure through this path). Since 0.23.13, App-route deployments additionally pin the client's code identity (see "XPC surface" above). **Residual limitations, registered honestly as designed trade-offs (not vulnerabilities)**: (1) the App bundle is user-owned by the drag-install convention — an attacker able to targeted-rewrite and re-sign the bundle in place can still pass pinning; bundle-ownership normalization is a registered follow-up that currently conflicts with Sparkle in-place updates (an update resets ownership before the daemon restarts), design pending; (2) CLI-route (manual `sudo cellar install`) deployments have no trusted anchor and keep the legacy admin-group gate; (3) status queries remain unauthenticated (first bullet above); (4) pinning is path-based: moving or renaming Cellar.app after install makes the App's mutating commands fail-closed (denied) until the daemon is reinstalled — after a move the daemon can no longer restart itself via KeepAlive either, so recovery is to uninstall the daemon (panel or `sudo cellar uninstall`), put the bundle back in place, and reinstall.
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