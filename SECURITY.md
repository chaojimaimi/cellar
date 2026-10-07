# Security Policy

## Overview

Cellar is an open-source battery charge-limiting tool for Apple Silicon Macs: a menu-bar app plus a CLI, backed by a root LaunchDaemon. It is free, open source (GPL-3.0), ships with **no telemetry**, and its only outbound network traffic is the **Sparkle update channel** (a daily appcast check plus, only after your explicit confirmation, the update package download — details below). The daemon has no networking code at all.

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
- Check GitHub Releases daily for a newer version via **Sparkle 2** with **EdDSA signature verification** (see "Network surface" below); offer to install it only after the user confirms in the update window

**Does not:**

- Collect telemetry (`SUSendSystemProfile` is explicitly `false`; no profile data is sent with update checks)
- Access any network endpoint other than the update-channel requests below
- Automatically download or install updates (`SUAllowsAutomaticUpdates` is explicitly `false` — the update window offers no "automatically download" option; every install is a user-confirmed action)
- Read user data
- Persist anything outside `/Library/Application Support/Cellar/` (`policy.json`, `action.json` — an atomic-write design) and standard log streams

## Network surface

All update traffic is performed by the App (never the daemon, which has no networking code at all) through **Sparkle 2** with the standard user driver. Two distinct outbound flows, stated separately for honesty — **"no automatic download/install" is not the same as "no automatic network checking"**:

1. **Appcast check (automatic, daily)**: Sparkle fetches `https://github.com/chaojimaimi/cellar/releases/latest/download/appcast.xml` at most once every 24 hours (plus on demand via the About page's "Check for Updates" button). This is a small read-only XML GET. GitHub answers `latest/download` with an HTTP redirect to its release-asset download hosts (`release-assets.githubusercontent.com` / `objects.githubusercontent.com`); Sparkle's URLSession follows that 302 — these domains are part of the update channel by design.
2. **Update package download (user-triggered only)**: if the appcast advertises a newer version, Sparkle shows an update window. **Nothing is downloaded until you press "Install Update"** in that window; the package is then fetched from the redirect chain of the same GitHub download hosts and installed after EdDSA verification (below).

- **No telemetry**: `SUSendSystemProfile = false` is hard-coded in Info.plist — Sparkle sends no system-profile payload with any request. The appcast request carries no identifiers beyond what TLS and GitHub's CDN see for any download.
- **EdDSA verification boundary (zip only)**: every appcast entry carries an EdDSA (`sparkle:edSignature`) signature over the release **zip**; Sparkle refuses to install a package whose signature does not verify against the public key pinned in the App's Info.plist. **The .dmg attached to each release is a manual-install convenience and is NOT covered by EdDSA verification** — if you install manually from the dmg, you are relying on GitHub TLS transport and repository integrity (plus the published SHA-256 checksums), not on signature verification.
- **What this replaces**: before 0.23.3 the app used a hand-rolled update checker (single `api.github.com` read-only GET + URL allowlist). That mechanism was retired in favor of the EdDSA-verified Sparkle channel, which is the stronger primitive.

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