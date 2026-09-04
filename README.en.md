[English](README.en.md) | [简体中文](README.md)

# Cellar

> Cell + Cellar — a climate-controlled storage environment for your MacBook battery.

[![CI](https://github.com/chaojimaimi/cellar/actions/workflows/ci.yml/badge.svg)](https://github.com/chaojimaimi/cellar/actions/workflows/ci.yml)

**An open-source battery management tool for Apple Silicon Macs**: keeps your battery within a range you define, avoiding long-term degradation from sitting at full charge on the adapter. Menu-bar resident + CLI control. Free, open source, no telemetry, no network dependency.

> Status: **0.5.0-alpha** — smart fan cooling (v1.1): automatically boosts the built-in fan when the battery temperature exceeds the threshold (default 37 °C, independent of the charge-side thermal pause configuration), with adjustable threshold/speed and strategies (constant-speed cooling [default] / two-stage / full-speed emergency), an opt-in toggle off by default, runtime capability verification (honestly disabled on unsupported machines), and automatic restoration of system fan control on exit/sleep/anomaly. Phase 4 battery protection (charge-side thermal pause, optional auto-discharge, one-click battery calibration, instant enforcement on plug/unplug) shipped with 0.4.0-alpha; all Phase 3 capabilities (theme system, Charge to Full once, Discharge to Limit, power-flow graph, battery health, zh/en bilingual, eleven-check `doctor`) shipped with 0.3.1-alpha; core charge limiting and the menu-bar GUI completed end-to-end acceptance on real hardware (macOS 26 / Apple Silicon): install → limit → discharge recovery → sleep/wake → uninstall. Feedback and trial are welcome; interfaces and behavior may change.

## Features

- **Any charge limit (60–100%)**: including the sub-80% range not natively supported by the system
- **Hysteresis**: charging stops at the limit and only resumes after self-discharge down to the recovery threshold (default: limit −2%), avoiding frequent on/off cycling
- **Charge-side thermal pause**: charging pauses automatically at battery ≥ 40 °C and resumes below 37 °C (hysteresis debounce); no hot restart of charging after a thermally terminated discharge
- **Smart fan cooling** (new in v1.1, off by default): automatically boosts the fan when the temperature exceeds a configurable threshold (adjustable threshold/speed; constant-speed, two-stage and full-speed strategies); exiting or any anomaly restores system fan control automatically, with write-read-back verification and runtime capability checks (auto-disables on unsupported machines)
- **Optional auto-discharge**: automatically discharges back to the limit when charge is above it (off by default; enabling requires double confirmation; after completion it needs to cool down and the adapter to be replugged before it can trigger again)
- **Charge to Full once**: temporarily charges to 100% (e.g., for a full battery before a trip); automatically restores the charge limit on completion; for full battery calibration use one-click calibration (below)
- **Discharge to Limit**: temporarily disconnects the adapter and runs on battery until the charge drops to the limit target, then automatically restores (real-time supply power visualization; support conditions below)
- **Root-free read-only monitoring**: charge level, charging/discharging state, voltage, current, temperature, cycle count, battery health, design/full charge capacity, cell voltages, adapter details
- **CLI + root daemon**: one install, automatic management at boot; `doctor` one-command twelve-point diagnostics (including a device compatibility line)

## GUI (App)

A menu-bar icon resident GUI (App/CellarApp.xcodeproj), sharing the same core and daemon as the CLI.

### Feature overview

- **Menu-bar battery panel**: charge arc, limit range, live status line (level / charging state / temperature / cycles / health / adapter); limit and hysteresis adjustable directly in the panel
- **Power-flow graph**: real-time visualization of three states — adapter supply / floating at stop / battery supply — including measured battery-side power
- **One-shot actions**: “Charge to Full once” (charges to 100% then automatically restores the limit) and “Discharge to Limit” (adapter off, automatically restores when the level drops to the target)
- **Battery calibration**: one-click four-phase calibration (full charge → rest/balance → discharge to 10% → restore limit), fully notified, cancellable anytime, auto-aborted on reboot
- **Themes**: native minimal / Cellar Amber dual themes with instant switching, light/dark adaptive; zh/en bilingual
- **Settings window**: appearance switch, launch at login, login-item repair, auto-discharge toggle, notifications entry
- **First-launch 4-step onboarding**: welcome → environment check (conflict gate) → daemon install authorization → set limit
- **Notifications**: limit reached, write failures, external writer conflict, action complete / safe abort, calibration progress, and more (action-class exempt from cooldown)
- **Launch-at-login item**: resident in the menu bar at login
- **Embedded root daemon**: registered and managed together with the App by the system framework (SMAppService)

### Updating the App (important)

- **App-managed route (panel install)**: first “Uninstall daemon” in the panel → replace Cellar.app → open it → “Install daemon” in the panel. **Overwriting the App directly with `rm`/`cp` can prevent the daemon from starting** (stale system registration cache; symptom: repeatedly failing daemon spawns). If it already happened: restart the Mac and reinstall, or switch to the manual route per the matrix below to restore charge limiting (the panel pending state also offers a “remove stale registration” exit).
- **Manual route (CLI install)**: replacing Cellar.app does not affect the daemon; but a daemon upgrade requires re-running `sudo .build/release/cellar install`.
- When both routes coexist, the panel shows migration guidance; `cellar doctor` item 9 reports the daemon registration state.

**Dual-route choice matrix**:

| Scenario                                        | Recommended route       | Reason                                                          |
| ----------------------------------------------- | ----------------------- | --------------------------------------------------------------- |
| Regular everyday use                            | App-managed (panel)     | Installs/uninstalls together with the App; managed uniformly in System Settings |
| Developers/testers replacing the App frequently | Manual (CLI)            | Daemon decoupled from the App bundle; replacing the App has zero impact |
| Repeated spawn failures on the managed route    | Manual (CLI)            | Deterministic recovery, bypasses system registration-cache issues |
| Manual-route users returning to managed         | Panel migration guide   | Clean up manual residue first, then install via the panel       |

### Discharge to Limit (support conditions and safety notes)

- **Support conditions**: macOS 26+ (Tahoe control backend) and firmware with a discharge-control key (`cellar doctor` item 11); the panel hides the feature otherwise.
- **Behavior**: temporarily disconnects adapter supply (the system switches to battery power) and automatically restores the adapter and charge limit once the level drops to the limit target. During discharge, a 60% charge-level hard floor and a 40 °C auto-abort apply; a daemon crash automatically restores charging.
- **Warning**: during discharge, **all USB / external devices lose power momentarily** (external drives being written to can lose data — remove them first); an external display with the lid closed may fall asleep.

### Install requirements (must)

**Cellar.app must be placed in `/Applications`**. The embedded root daemon is launched by launchd; empirically, launchd refuses to spawn the process from deep paths such as the home directory (repeated spawn failures, while the same binary runs fine as a user-space process); installed in `/Applications`, the daemon persists normally. Do not run the App directly from the Downloads folder or similar locations.

### Gatekeeper

The App is ad-hoc signed and not notarized; on first launch, if it reports “App is damaged” or cannot be opened:

1. **Primary path**: run `xattr -cr /Applications/Cellar.app` in Terminal, then reopen
2. **Alternative**: System Settings → Privacy & Security → “Open Anyway”

(The right-click → “Open” bypass has been removed since macOS 15; do not attempt it.)

### First-launch onboarding (4 steps)

1. **Welcome**: what Cellar is; it will install a root daemon and take over charge limiting (60% floor explained)
2. **Environment check**: scans the machine for other charge-management software/daemons; exact hits block installation, suspected hits require confirmation to continue
3. **Install daemon**: click Install → authorize in the System Settings “Login Items” prompt → continues automatically after authorization
4. **Set limit**: choose the limit target (60–100%) and hysteresis bandwidth; done

Closing the panel mid-flow loses no progress; reopening continues the onboarding.

### Uninstall

Panel → Uninstall (deregisters the daemon, restores default system charging), then move Cellar.app to Trash. On machines where a manual LaunchDaemon was previously installed via CLI, the panel first shows migration guidance.

### Mutual exclusion with other charge-management tools

Cellar must be used exclusively with other charge-management tools/daemons: both sides may write the same charging-control key, and running simultaneously interferes (Cellar’s write-after-read verification detects external writers and explicitly warns). Stop or uninstall other charge-management software before installing; `cellar doctor` also scans installed similar tools (installed directories and running processes, two levels).

## System requirements

| Component        | Requirement                                                                             |
| ---------------- | --------------------------------------------------------------------------------------- |
| Machine          | Apple Silicon MacBook                                                                    |
| OS               | macOS 26+ (Tahoe control backend, validated on real hardware); earlier systems use the experimental Legacy backend (unvalidated) |
| GUI (App)        | macOS 26+ (hard requirement)                                                             |
| Permissions      | Reads need no privileges; writes go through the root daemon (CLI needs `sudo`; App is authorized via System Settings, admin account required) |

## Build & install

Requires the Swift 6 toolchain (Xcode or Command Line Tools); building the GUI App requires Xcode 26.

```bash
git clone https://github.com/chaojimaimi/cellar.git
cd cellar
swift build -c release

# Install the root daemon (copies the binary + registers the LaunchDaemon + starts it)
sudo .build/release/cellar install
```

GUI route: open `App/CellarApp.xcodeproj` in Xcode and build; place the resulting **Cellar.app into /Applications** and run it (install requirements under “GUI (App)”).

## Usage

```bash
cellar status          # status overview (backend, level, charging state, control key, daemon state)
cellar doctor          # twelve-point diagnostic report (exit codes 0/1/2 usable in scripts)
cellar doctor --devices  # single-line device compatibility output (welcome in issue reports)
sudo cellar set 80     # set limit 80% (range 60–100; --hysteresis n available)
sudo cellar disable    # stop limit management, restore default system charging
sudo cellar enable     # restore limit management
sudo cellar uninstall  # uninstall and restore default system charging
```

- `cellar status` / `doctor` give trustworthy conclusions without `sudo`
- after either the daemon or the CLI is updated, re-run `sudo .build/release/cellar install` to upgrade
- `cellar doctor` detects other charge-management tools on the machine (installed directories and running processes, two levels) and warns about coexistence

## Security & design

- **60% hard floor on the limit**: enforced at three layers (CLI parameter validation / XPC permission and re-check / daemon policy construction); persisted files cannot bypass it
- **Recoverability**: SIGTERM, `disable`, and `uninstall` all automatically restore default system charging; a daemon crash is re-pulled by launchd, which immediately reconciles state
- **Least privilege**: reads need no privileges; writes converge on a single root daemon; XPC mutation commands accept only root or admin-group (gid 80) members, with a type whitelist and rate limiting
- **No silent failures**: write-after-read verification; verification failures (including external writer conflicts) are reported as typed errors
- **No telemetry, no network**: zero third-party dependencies besides package resolution

## Validation

```bash
swift run CellarCoreCheck   # 334 scenarios, hundreds of checks: exhaustive decision-matrix
                            # enumeration (700+ boundary combinations), packing/parsing,
                            # XPC validation, policy persistence, action state machine,
                            # notification classification, discharge safety gating,
                            # localization completeness
bash Tools/coverage.sh      # state-machine line-coverage gate (scoped to Control/Daemon
                            # pure logic, ≥80% · currently 88.12%)
swift run CellarUICheck     # 92 UI snapshot comparisons + localization completeness gate
```

Hardware-in-the-loop acceptance (install → limit → discharge recovery → sleep/wake → uninstall) is performed with each version release; recorded in CHANGELOG.

## Roadmap

- ✅ **Phase 2 (0.2.0-alpha)**: menu-bar App (GUI); `install` via the system framework
- ✅ **Phase 3 (0.3.1-alpha)**: theme system, Charge to Full once, Discharge to Limit, power flow, battery health, zh/en bilingual, snapshot matrix, eleven-check `doctor`
- ✅ **Phase 4 (0.4.0-alpha)**: battery protection round — charge-side thermal pause, optional auto-discharge, one-click battery calibration, instant enforcement on plug/unplug
- ✅ **Phase 5 · v1.1 (0.5.0-alpha)**: smart fan cooling (released) — automatic fan boost above the temperature threshold, opt-in off by default, three speed strategies, runtime capability verification, automatic restoration of system control on anomalies
- ✅ **Phase 5 · v1.2 polish batch (0.6.0-alpha)**: low-corner lightweight panel footer + adaptive settings window height (released)
- Phase 5+: live dashboard, statistics panel, calibration auto-scheduling, complete thermal protection, charging schedule, Shortcuts integration

The full roadmap and design documents are published in the release notes.

## Contributing

Issues and PRs are welcome. Before submitting, run `swift run CellarCoreCheck` and `swift run CellarUICheck` to confirm all scenarios pass; building the App (GUI) requires Xcode 26. When reporting device compatibility, attach the `cellar doctor --devices` output (it contains no privacy fields such as serial numbers).

## License

[GPL-3.0](LICENSE)

## Disclaimer

This software is provided “as is” (see the LICENSE disclaimer). Battery charge/discharge behavior varies by hardware; please assess the risks yourself and keep a system recovery path available.