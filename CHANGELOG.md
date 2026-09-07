# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.18.0-alpha] - 2026-09-07

### Added

- **面板观察增强**：面板数据区新增第三行——CPU 表面温度（proximity 传感器，按机型运行时探测，不支持时自动隐藏）与左/右风扇实时转速（策略关闭、系统自动模式下也常驻显示，便于对比「阈值触发 → 实际起转」）。面板可见时 30 秒粒度采样，关闭不采样。
- **统计页 hover 值提示**：四条曲线卡悬停显示竖游标与对应时刻数值（含电量曲线的波动带上下界）；断档区间无提示。
- **通用页**：新增「菜单栏显示电池电量图标」开关——菜单栏图标切为随实际电量填充的电池形态（充电中带闪电），可随时切回状态符号。

### Changed

- 功率流向卡头注记随数据源更新：遥测在场显示「实时遥测」，仅旧机型回退原「电池侧实测口径」注记。
- 统计四卡横轴统一为固定整点步长（24h=6h/7d=2 天/30d=7 天），消除各卡刻度不一致与末端标签截断；hover 时间标签随窗口口径。
- 风扇开关描述去除「电池温度」限定词（温度源现已可选）。
- 移除「记录自」页头徽章；数据未填满所选窗时在曲线卡内提示「数据累积中（N 天）」。

## [0.17.0-alpha] - 2026-09-07

### Added

- **适配器实时功率**：状态行与功率流改显电源适配器的实时输出功率（每 ~30 秒随负载更新，如编译 60W+ → 静息 25W；来自系统电源遥测，本机闭环实测校验），原额定功率降为副注。遥测不可用时回退额定显示。
- **风扇双温度源**：风扇智能降温新增温度源可选——电池温度（默认，行为与历史版本完全一致）/ CPU 表面温度（proximity 传感器，平滑响应负载产热；阈值独立可调 40-70°C，默认 55°C）。本机压测实证：CPU 核心瞬时温度波动达 ±14°C 不适合做阈值控制，表面传感器平滑无尖峰。传感器按机型运行时探测，不支持时诚实降级。doctor 风扇行同步显示当前源与探测结论。
- **标题栏电池图标**：主窗口标题栏可显示随电量填充的原生风格电池图标（充电中带闪电标识），通用页开关控制，默认关闭。

### Fixed

- 升级兼容：旧版本策略文件升级后风扇新配置自动落默认值，既有全部配置（充电上限/模式/风扇设置）原样保留。

## [0.16.0-alpha] - 2026-09-07

### Added

- **菜单栏电量百分比开关**：面板页脚新增「菜单栏显示电量百分比」开关（默认关）——开启后菜单栏图标旁显示当前电量（等宽数字，随轮询/采样节奏刷新，断连或旧守护进程时不显示）；偏好持久化 `app-config.json`（经共享 store 原子共写，与既有偏好字段互不覆盖），旧配置文件缺键自动兼容。

### Fixed

- **MagSafe LED 切换时通用页控件闪灰**：LED 模式切换外迁为独立轻路径——不再触发全局 busy 门，切换往返期间风扇/热保护滑杆不再整页禁用闪灰；LED 结果反馈收进组件内轻提示（成功 5 秒自动消退、失败常驻至下次 LED 操作），不再占用全局告警横幅通道（与其他控制的反馈互不覆盖）。
- **引导页守卫文案与通用页弱化语义分裂**：手工安装的守护进程健康运行时，引导页安装步与通用页（0.4.1 起）同语义——显示弱化说明（「无需安装」）+「继续」直接进入上限步；此前引导页恒显强守卫文案且无继续路径。守护进程失联/未运行时守卫原文不变（保守方向）。

### Docs

- README（中英）新增「无签名应用首次打开」指引：系统设置「仍要打开」图形路径为主，`xattr` 命令路径为备注；首页状态行更新至 0.16.0 现状综述。

## [0.15.0-alpha] - 2026-09-06

### Added

- **风格 C「仪表盘工业」Tier 2 打磨（v1.9）**：
  - 仪表内圈刻度盘：主刻度 12 + 副刻度 48，Canvas 静态绘制，仅 C 风格生效（A/B 视觉零变化）
  - 面板细线网格底纹：菜单栏弹窗 + 主窗口内容区 24pt 方格，仅 C 风格生效
  - 等宽数字扩面：仪表 hero 限充区间行、仪表板时间估算与健康卡主读出
  - 快照矩阵 258 → 270（hero 仪表 + 网格容器 2 态 12 张，三风格全列）

### Changed

- **风扇策略「抬升下限」退役（v1.9）**：v1.1 起因固件拒写风扇最低转速键（实测 result=134）而从未可配置的灰显占位策略，正式从设计移除、后续不再实现——策略 Picker 三项（恒速降温 / 两级分段 / 全速应急），线格式值 1 永久保留不复用，daemon 对其拒绝语义不变。对既有用户零行为影响（该策略此前不可选中）。本地化词条 411 → 408。

## [0.14.0-alpha] - 2026-09-06

### Added

- **MagSafe LED 控制（v1.8，stretch 池）**：接管 MagSafe 3 充电线插头指示灯——跟随系统（默认，零行为变化）/ 常灭（夜间环境）/ 常绿 / 常琥珀：
  - 通用页新增「MagSafe 指示灯」分节（Picker 即时生效；旧 daemon 升级提示；无 MagSafe 充电口机型自动隐藏）
  - daemon tick 纠偏（系统在充放切换时重写灯色，30s 心跳内恢复设定）+ 写后回读校验 + 冲突锁存（检测到 MagHue 类写入者自动停手并在 doctor/通用页提示，单写者原则）
  - 恢复红线：退出 / 停用 / 卸载一律交还系统（ACLC=0）；crash 尽力恢复（系统充放覆写自愈）
  - `doctor` 第十六项「MagSafe 指示灯」；`status` 新增 LED 行；`status --json` 携带 `magSafeLed`
  - 键位实测（ACLC ui8/1B，四值目视验证）记录于 SMC 协议文档
- **走查 UI 打磨批（5 项）**：面板页脚「退出 Cellar」→「退出」（琥珀「封存退出」→「封存」）；主窗口标题改「芯仓」；六个设置/功能页内容列宽窗下水平居中；通用页弃用 Form 重建为统一行栅格自定义分节（治标签层级参差）；统计「最大容量趋势」口径切换为标称满充容量/设计容量（与仪表板健康一致——原 MaxCapacity 键在本系统恒 100 失真）

### Changed

- 测试栈：CellarCoreCheck 476 → 507 场景（LED 模型/doctor 分支/线格式），快照 246 → 258 张（MagSafeLed 节 ×12 + FooterLinks 文案 12 张重生成），本地化 400 → 411 键

## [0.13.0-alpha] - 2026-09-06

### Added

- **原生限充协调（macOS 26.4+）**：检测系统设置中的「充电上限」（80/85/90/95/100% 五档）注册态——经实测确认原生机制为 powerd 软件策略（`ChargeCtrlPolicy`/`manualChargeLimit`，非 SMC 固件键），Cellar 对其只读、执法路径零改动：
  - 仪表板注记行「系统限充 N% 生效中」（仅手动策略口径）与冲突横幅（原生值高于 Cellar 上限时提示二选一，附「打开系统电池设置」深链）
  - **校准 / 充满一次守卫**：原生限充激活时前置拒绝（手动路径返回明确文案；调度路径静默顺延），防止校准永远到不了 100%
  - `doctor` 新增第十五项「原生限充共存」（警告 / 提示 / 失败 / 未知分级，摘要文案同步修正为十五项）；`status` 新增原生段与用户域 UI 镜像行；`status --json` daemon 段携带 `nativeLimit` 子对象
  - 兼容性：`DaemonStatus.nativeLimit` 可选字段缺席保持（旧 daemon 不上报 → App/CLI 显示升级提示）；全部控制类回包恒携带该字段（避免「旧 daemon」瞬态误判）
- 测试栈：CellarCoreCheck 438 → 476 场景（原生限充检测 23 + wire/守卫 15 + doctor 分支），快照 234 → 246 张（注记行 / 冲突横幅 × 三风格 × 双色板），本地化 387 → 400 键，覆盖率 88.95% → 89.81%

### Changed

- daemon `getStatus` 与全部控制类回包统一附加 `nativeLimit`（每请求一次只读解析 /Library 域 powerd 策略注册表，不进执法 tick）

## [0.12.0-alpha] - 2026-09-05

### Added

- **第三 UI 风格「仪表盘工业」**：外观页新增第三选项——仪表信号绿单信号色板（品牌维度单一，语义红橙保留）、等宽数字（仪表中心读数与状态行数值段等宽化）、石墨 / 浅灰仪器面板双色板；与原生 / 酒窖琥珀并存即时切换，快照回归矩阵扩至三风格（234 张）。
- 语汇沿用原生直白措辞；工业专属语汇与刻度盘仪表变体列入后续打磨。

## [0.11.0-alpha] - 2026-09-05

### Added

- **充电日程（v1.6 自动化，默认关闭）**：主窗口新增「自动化」页——按星期与时段自动切换限充上限或完全放开充电（最多 8 条，30 分钟步进，支持跨午夜窗口）。**边沿触发语义**：进窗快照当前策略、出窗恢复快照（时段内手动修改仅临时生效）；A→B 相邻窗口无缝直切；重启 / 错过边沿自动补判；关总开关立即恢复。守护进程侧日程引擎含状态落盘（原子写 + 损坏自愈）与配置三级校验（长度 / JSON / 结构值域）；配置成功后 ≤1 tick 生效。当前生效条目带「生效中」徽章，日程进入 / 恢复推送本地通知。
- **`cellar status --json`（CLI 脚本化）**：机器可读单行 JSON 输出（`daemon` 状态段键名对齐内部结构——旧 daemon 缺席的扩展字段自动省略；`route` 安装路线；`local` 本地电池读数段），退出码约定不变；默认人读输出不变。`cellar doctor` 同步新增第 14 项充电日程检查。

## [0.10.0-alpha] - 2026-09-05

### Added

- **充电热阈值可配置化（v1.5）**：通用页新增「充电热保护」节——暂停阈值（35–45 °C，步进 0.5，默认 40 °C）与滞回幅度（1–8 °C，步进 0.5，默认 3 °C）可调，滑杆松手提交、全键下发。热保护**不可关闭、无开关**：暂停点上限 45 °C 钳制（行业充电窗口上沿）+ 值域校验 + 非法配置回落默认四级 fail-safe；旧 daemon 显示升级提示。
- **恢复点派生展示**：恢复点 = 暂停点 − 滞回（默认 37 °C），只读行实时派生、不可单独调整——从配置模型上消除「恢复 ≥ 暂停」非法组合。
- **充电使能路径热守卫收编**：「充满一次」保活与校准充满相保活不再绕过热保护——高温期写停充、滞回带驻留不重写、冷却后自动恢复，满充/校准数小时遇高温强制充电的盲区消除；deadline/超时语义不变。
- **doctor 热配置检查项**：新增第 13 项「热暂停配置」，显示当前暂停点/滞回与是否默认值（明示与风扇阈值相互独立）。

## [0.9.0-alpha] - 2026-09-04

### Added

- **自动校准调度（opt-in，默认关闭）**：校准页新增调度卡——设定周期（7 / 14 / 30 / 60 / 90 天，默认 30）与夜间窗口起点（默认 01:00 起四小时窗），守护进程在窗口内自动发起电池校准；外接电源 + 空闲才启动，条件不满足顺延次日，随时可取消。
- **校准页实页化**：主窗口「校准」页上线——校准状态卡（发起 / 两步确认 / 相位进度 / 取消，与菜单栏面板同一流程）、调度卡、上次校准记录卡。
- **上次校准记录**：守护进程持久化最近一次校准的启动时间与结果（完成 / 已取消 / 超时 / 安全中止 / 重启中止），页面展示时间、结果与耗时，并提供下次自动校准时间预估。
- 发布产物新增 dmg（拖拽安装布局），与 zip 双形态并行。

## [0.8.0-alpha] - 2026-09-05

### Added

- **统计面板（主窗口侧栏）**：SQLite 周期采样（60 秒一跳常驻，35 天滚动窗口保留）+ 历史曲线页——电量曲线按充电 / 停充 / 放电三色分段并带最小-最大波动带，窖温、功耗曲线（正 = 充电输入 / 负 = 放电输出），24 小时 / 7 天 / 30 天范围切换，最大容量趋势（数据积累后显示）。采样断档（睡眠 / App 未运行）如实留空不插值；统计存储于本机用户域（`~/Library/Application Support/Cellar/stats.sqlite`），无遥测。
- **采样与界面解耦**：统计记录常驻（每分钟一跳，静息 CPU 近零），不受面板 / 主窗口可见性影响；库损坏自动重建（遥测可弃，App 不受影响）。

### Fixed

- 功率流向三角图直供边配色与标签位置修正（真实能量流动用主题强调色呈现、标签上移出线），停充态直供动态可见。

## [0.7.0-alpha] - 2026-09-04

### Added

- **实时仪表板（主窗口 + 侧栏导航）**：功率流向三角图（适配器—电池—系统三实体，流动光点动画，「只有真实流动的路径才画线」——直供边 accent 实时呈现系统能量流动）；藏酒量环（限充区间弧 + TARGET）；四指标（窖温/时间估算/电池健康/循环）；三卡片（电池规格 / 电池健康 / 适配器，未接入空态）。数据源 = AppleSmartBattery 直读 + SMC 只读键 + IOPowerSources（全公开接口，纯只读监测）；时间估算「满电还需 = 至限充上沿 / 预计可用 = 近 15 分钟斜率外推」，样本不可信显「—」不造数。
- **充电控制 / 通用 / 外观 / 关于页**：菜单栏面板与原设置窗的全部能力统一迁入主窗口侧栏（控制区滑杆语义/自动放电/风扇降温/daemon 安装管理/风格切换/诊断摘要），统计 / 校准 / 自动化占位页标注规划版本；菜单栏面板保留快捷操作形态。
- **采样多表面仲裁**：面板 / 主窗口任一可见即 1s 高频采样，全部关闭回落 60s（仪表板不成为耗电源）。

### Changed

- **设置窗退役**：设置项统一并入主窗口侧栏，菜单栏面板页脚精简为「主窗口 · 退出 Cellar」。
- **风格词汇系统扩展**：仪表板语汇按风格取词——原生主题用中性功能词（电量 / 温度 / 已停充），琥珀主题保留酒窖语汇（藏酒量 / 窖温 / 已停充 · 窖藏中）。
- **系统控件跟随主题强调色**：琥珀风格下滑杆 / 开关 / 选择器不再泄漏系统蓝（主题 tint 全树注入）。
- 界面快照矩阵 92 → 112（功率流三角图 4 态 + nodata 空态入阵）；本地化 311 → 314 key。

### Fixed

- **菜单栏图标插拔延迟**：电源事件在控制忙碌 / 通知竞态 / 节流窗口下会被静默丢弃（兜底轮询最长 60s）——事件处理改为应用无条件生效 + 丢弃路径 1.5s 自愈复查，插拔后图标 ≤2s 翻转。
- 主窗口功率流向几何缩放修正（整数除法推断陷阱致节点卡在部分窗口宽度下塌缩、文字溢出卡框——绘制改单坐标系 + 内容驱动卡宽 + 字号随容器统一缩放）。

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
