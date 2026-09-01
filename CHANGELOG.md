# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0-alpha] - 2026-09-01

Menu bar app (GUI) and embedded daemon — Phase 2 complete. Core charge
limiting remains as in 0.1.0-alpha; the App and daemon installation was
verified end-to-end on Apple Silicon / macOS 26 real hardware.

### Added

- **Menu bar app** (`App/CellarApp.xcodeproj`): battery gauge panel with
  charge arc, limit band, live limit slider, segmented status line,
  multi-state menu bar icon, and alert banner.
- **First-run onboarding** (4 steps): welcome → environment check
  (conflict gate) → daemon install authorization → set limit. Progress
  survives panel close/reopen.
- **Conflict gate**: hard block when an exact match of another
  charge-management tool is detected; soft warning requiring explicit
  confirmation for generic matches.
- **Notifications**: limit reached, write failure, and suspected external
  writer conflict (per-type 10-minute cooldown).
- **Login item**: the app starts with your account and stays in the menu
  bar.
- **Embedded root daemon via SMAppService** (`BundleProgram` string in
  `Contents/Library/LaunchDaemons/`): register/unregister through the
  system Login Items framework, with migration guidance for machines that
  have a legacy hand-installed LaunchDaemon.
- **Admin-group authorization** for mutating XPC commands — the app can
  control limits from an admin account without sudo (security impact
  documented under Changed).

### Fixed

- Menu bar icon no longer invisible in the disabled state.
- CLI status timestamp now rendered in the local timezone.
- First-install failure root cause: SMAppService plist name must include
  the `.plist` extension (registration failed with `code=108` otherwise).
- Routing detection now recognizes the SMAppService/BTM-managed job format
  in `launchctl print` output, so migration guidance is accurate.
- Install guidance now requires `/Applications`: launchd refused to spawn
  the embedded root daemon from a deep home-directory path (repeated
  spawn failures; the same binary runs fine in user mode). Moved to
  `/Applications`, the daemon runs normally.
- Onboarding gate: the first-run guide no longer flashes for
  already-registered users (load-state guard).
- App install state now reports its true state: refresh watchdog with an
  explicit "initializing" state instead of a frozen panel.

### Changed

- **Authorization model — root-only → root or admin group (gid 80)** for
  mutating XPC commands (`setLimits` / `disable` / `enable`). Security
  impact: any local admin account can now change charge limits without
  sudo; non-admin users remain rejected (rejections are rate-limited and
  the connection is cancelled after repeated failures). The daemon still
  runs as root, `getStatus` stays readable by all local users, and
  request validation is unchanged. The admin check resolves the caller's
  group list via `getpwuid_r`/`getgrouplist` (base group, never a
  hard-coded gid) so group membership cannot be spoofed.
- **Version alignment**: development builds between 0.1.0-alpha and this
  release reported `0.2.1-alpha-dev`; the release line is now unified on
  `0.2.0-alpha` (App, daemon, and CLI), with `CFBundleVersion` bumped to
  2. Version comparisons are string-equality throughout, so the numeric
  step-back has no logic impact; stale daemons from dev builds surface
  via the existing stale-version prompt.
- **CI**: added an `app-build` job on `macos-26` (pinned Xcode 26.6) that
  builds the Release app bundle and uploads it as a workflow artifact. It
  is a hard gate (no `continue-on-error`) and keeps the same ad-hoc
  signing as the release artifact; the existing SPM job is unchanged.

## [0.1.0-alpha] - 2026-09-01

First runnable alpha. Core charge limiting works end-to-end on macOS 26
(verified on Apple Silicon hardware); no GUI yet.

### Added

- **Charge limiting** with configurable upper limit (60–100%) and hold band
  (hysteresis, default 2%): charges to the limit, stops, automatically
  resumes after discharge below the resume threshold.
- **Tahoe control backend** (macOS 26+): single-key `CHTE` control over the
  AppleSMC unified entry (selector 2 + data8 dispatch), hardware-verified
  stop/charge/resume cycle. Write path requires root.
- **Legacy control backend** (pre-26 systems, `CH0B`/`CH0C` dual-key with
  failure compensation) — implemented against public reference
  documentation; not yet verified on real hardware.
- **Runtime backend probe**: CHTE → CH0B detection at daemon startup;
  read-only fallback mode when no control backend is available.
- **Battery monitoring** (read-only, no root required): percent, charge/discharge,
  voltage, signed amperage, temperature, cycle count, design/raw capacities,
  per-cell voltages, FCC, adapter details (watts/voltage/current/name).
- **root LaunchDaemon** with keep-alive on crash, startup reconciliation,
  sleep policy (charging disabled before system sleep — the control key is
  a switch, not a limit, and nothing guards it during sleep), SIGTERM
  restore-to-default, and automatic recovery from transient SMC client
  failures.
- **XPC control interface** over launchd MachServices: `getStatus` /
  `setLimits` / `disable` / `enable`, root-only for mutating commands,
  request validation (type whitelist, command length cap) and per-connection
  rate limiting on rejected mutations.
- **CLI**: `cellar status` · `cellar doctor` (seven-point diagnostic report
  with exit codes for scripting) · `cellar set <limit>` ·
  `cellar enable` / `disable` · `cellar install` / `uninstall`.
- **Conflict awareness**: doctor detects other charging-management helpers
  and daemons on the machine and warns before control operations.
- **Self-verification**: 76-scenario zero-dependency verifier
  (`swift run CellarCoreCheck`) covering the decision matrix exhaustively
  (700+ boundary combinations), packet encoding, XPC message validation,
  policy persistence, and real-device smoke diagnostics.
