# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.6.1-alpha] - 2026-09-04

### Changed

- **设置窗分节视觉打磨**：通用页按「通用 / 自动放电（无节头）/ 智能风扇降温」三节分组、关于页按「版本 / 诊断」两节分组（macOS 原生 Form Section）——解决行信息紧凑、风扇区与系统项混排的观感问题；注册态与通知授权态迁入「通用」节。控件与控制逻辑零变更（纯组织结构）

## [0.6.0-alpha] - 2026-09-04

### Changed

- **面板页脚轻量化重设计**：「设置…」「退出」移至面板低角两端的纯文字轻量形态（悬停强调色反馈），替换原居中纵排的默认样式按钮；交互语义不变（设置仍先激活 App 再开窗口）。页脚组件化下沉 UI 组件库并纳入快照矩阵（界面快照 84 → 92 张，含悬停态）
- **设置窗口高度自适应**：窗口高度跟随当前页内容（原固定 560pt，短页大块留白）——三页统一滚动结构、每页独立高度槽位、测量驱动成帧（下限 260pt 短页贴身残留约 30pt）；修复 macOS TabView 窗格缓存导致的切页高度残值（重访不再跟随）

## [0.5.1-alpha] - 2026-09-04

### Fixed

- **风扇控制能力误判**：模式寄存器写后存在 ≤100ms 量级锁存延迟（真机探针实测 T+10ms 回读仍旧值、T+100ms 锁存），写后立即回读误报「写后回读不一致」→ 进入连续失败 ≥3 → 本机误判为「不支持」（实测支持机同样中招）；还原写（Md=0）同样受影响。写后回读校验改锁存重试阶梯（[100, 300, 800]ms 三次回读，任一次一致即通过；fail-visible 语义不变），仅影响 boost 进入/重写/释放等稀有转移写，不进入 tick 常规路径

## [0.5.0-alpha] - 2026-09-04

### Added

- **智能风扇降温（v1.1）**：电池温度超过阈值（默认 37 °C，独立于充电热暂停 40/37 配置）自动提速内置风扇散热；opt-in 开关默认关闭；三种转速策略（恒速降温【默认】/ 两级分段 / 全速应急）；基于真实硬件探测的运行时能力验证（不支持机型诚实显示「不支持」，不盲写）；Apple Silicon 需先切换风扇手动模式（实测验证的解锁序列）；退出/睡眠/异常一律恢复系统自动管理；设置区与面板状态行；CLI status 风扇行 + doctor 风扇检查项
- **CLI `setFan` XPC 命令与 DaemonStatus 风扇字段**（协议向后兼容）

### Fixed

- **数据目录校验兼容性缺陷**（0.4.1 引入的 root:wheel 严格判定在 macOS 惯例 admin 组环境下阻断安装——组属主不再参与判定，保留 uid 与无组/其他可写位校验；install 对既有非 root 属主目录拒绝并提示人工处置，防投毒目录被洗白）
- **设置窗口通用 Tab 内容加风扇区后固定高度裁切**（内容改滚动布局）

## [0.4.0-alpha] - 2026-09-03

### Added

- **充电侧温度暂停**：电池 ≥ 40 °C 自动暂停充电、< 37 °C 恢复（3 °C 滞回）；放电热终止后不再热态回充
- **自动放电（可选）**：电量高于上限时自动放电回到上限（默认关闭；设置 → 通用开启，双确认警示；完成/终止后 30 分钟冷却并需适配器重插才可再触发）
- **电池校准（手动）**：一键四相校准（充满至 100% → 静置平衡 2h → 放电至 10% → 恢复限充），面板内嵌四点警示确认，全程通知 + 可取消，重启即中止
- **插拔即时执法**：守护进程订阅系统电源变化事件，插/拔电 ≤1s 全量重估（插电恢复充电从最长 30s 缩到 1-2s；翻转门/温度守卫/自动放电触发同步即时化）

## [0.3.1-alpha] - 2026-09-02

Phase 3 complete — interface style system, one-shot actions (charge to full /
discharge to limit), power flow visualization, battery health, full English +
Simplified Chinese localization, snapshot test matrix, and an expanded
eleven-check `doctor`. All verified end-to-end on Apple Silicon / macOS 26
real hardware.

### Added

- **Interface style system**: Native / Cellar Amber themes with instant
  switching, dark & light adaptive; Settings window (appearance / general /
  about); menu-bar power flow visualization (adapter / floating / battery
  with measured battery-side wattage)
- **Charge to Full Once**: temporarily charge to 100% (battery calibration /
  travel), automatically resuming the charge limit afterwards
- **Discharge to Limit**: temporarily cuts adapter power and lets the battery
  drain to the charge target, then restores automatically — with hardware
  safety rails (60% floor, 40 °C cutoff, sleep abort, crash-recovery,
  residual-state patrol); requires macOS 26+ (Tahoe backend) and supported
  firmware (auto-detected, feature hidden otherwise)
- **Battery health** percentage (nominal / design capacity) in the panel
- **Power flow diagram** with real-time direction and measured wattage
- **Full English + Simplified Chinese localization** (menu bar panel,
  onboarding, settings, notifications, about)
- **doctor expanded to eleven checks**: daemon registration state (BTM),
  three-way version matrix, discharge capability & residual-state safety,
  key-generation notes, and process-level coexistence scanning; new
  `cellar doctor --devices` outputs a machine-parsable compatibility line
  (no serial numbers or hardware UUIDs)
- **Icon immediacy**: menu bar icon now reacts to plug/unplug instantly
  (system power-source notifications instead of polling)

### Changed

- Daemon protocol version bumped to `0.3.1-alpha` (capabilities discovery;
  App / daemon must be upgraded together — see README "Updating the App")
- Onboarding, notifications and panel copy available in both languages;
  daemon wire-format literals remain untranslated by design

### Fixed

- Settings window now opens in front of other apps
- Discharge confirmation moved inline (the system dialog dismissed the
  menu-bar panel)
- Power-flow arrow direction during battery discharge; floating state now
  shows a neutral "no flow" marker
- Success banners auto-dismiss after 5 seconds (previously lingered)
- Localization language matching for region-qualified preferences
  (e.g. `zh-Hans-CN`)

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
  `0.2.0-alpha` (App, daemon, and CLI), with `CFBundleVersion` bumped to 2. Version comparisons are string-equality throughout, so the numeric
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
