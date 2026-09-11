# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.19.5-alpha] - 2026-09-11

### Fixed

- **流向判据陈旧防御（校准充满相方向反转事故收口）**：实测 `BatteryPower` 属 ~25-30s 节流的遥测字典，而 `isCharging` 是 1s 快照字段——0.19.3 起「电池补入」由 BP 符号单独裁决，充电起步瞬态（校准充满相、插电、充满一次、下调限值恢复充电）中旧代 BP（负）压过新 isCharging（true），方向全表面反转（现场：充电 ~40 W 却显「电池补入 −25.3 W / 系统 89.2 W」，真实负载仅 ~24 W）。现「电池补入」需**连续两帧 BP < −50 mW 且确认遥测换代**才成立，并带锁存（稳态字典不动也维持，原始弱适配器补差场景不受影响）；**未确认冲突窗口** kind 跟随最新策略态（方向词/徽章不再反转），电池边与系统负载如实空缺不造数，直供边以「直供 · SP W」如实呈现适配器输入。判定/写回为双槽时序（消费面恒用上一帧三元组，防自比恒未换代）。

### 备注

- 遥测字典内恒等式（`SystemPowerIn = SystemLoad + BatteryPower`）精确成立是本修复的判据论据：字典为单代相干样本，换代后的 BP 必然可信；代际更替由相邻帧 (SP, BP) 值比对检测。
- 判据仍收敛于纯函数 `flowDiagramModel`（前态三元组入参，默认 nil 零回归）；四消费入口（面板流向行 / 状态行两段 / 仪表板系）全部透传，无第五入口。
- 全门禁：593 场景（+9，旧场景 3/4/5/16/20 改带前态构造、断言保持）、330 张快照（+12 unconfirmed 全新；`StatusLine_assist` ×6 构造传前态保持零 diff；其余 318 张零 diff）、l10n 439 零增减、状态机覆盖率 90.74%。
- 已知形态（如实登记）：确认前的一代（≤~30s）方向词可能短暂跟随策略态；ε 边界抖动可能引起逐帧形态交替（每帧均如实）；字典停更极端场景下确认门不闭合——方向始终正确、数字如实少显。
- 登记观测项：StatsSample 增补 BP/SP 字段（历史复盘能力）、校准窗口 ioreg 采样脚本、`PowerFlow_assist` 3 张 golden 的环境渲染漂移（容差内，与本批正交）。

## [0.19.4-alpha] - 2026-09-11

### Fixed

- **补入态显示语义统一（0.19.3 已知形态收口）**：面板功率流向行、状态行电源段、电流方向词、主窗口头栏徽章、藏酒环 AX 摘要（面板 + 主窗口）、适配器卡状态词、藏酒环闪电徽标——全部从 `isCharging` 策略位切换到 `FlowDiagramKind` 实测裁决（`PowerFlow` 三态枚举退役删除，全 App 流向判据归一）。补入态（弱适配器 + 高负载，`IsCharging=Yes` 而电池实测放电补差）下不再误显「充电中」：流向行画电池→Mac 左向箭头（warning 色）+「电池补入」词 + 放电向功率；电源段「外接 · 电池补入」；电流方向词「放电」（与电池卡负号一致）；徽章「电池补入」；适配器卡「直供 + 电池补入」；时间瓦片按电池语义外推「预计可用」。
- **电流方向词两处语义修正（如实登记的行为差异）**：① 拔电瞬态（`isCharging` 暂留 true）方向词由「充电」翻转为「放电」——`ext=false` 恒落 battery 态，方向词与实测一致（旧边界为沿用陈旧标志位的妥协）；② 遥测在场且 `|BP| ≤ 50 mW` 的零流子情形，电源段词/方向词/徽章/徽标由「充电中」族翻为「已停充」族——0.19.3 登记的徽章/图形分叉随统一收口一并消除。

### 备注

- 判定零新增：全批复用 0.19.3 钉死的 `flowDiagramModel` 判定表，新增仅 `flowModel(of:)` 快照便捷投影与 `currentDirection(kind:)` 四态映射；`currentDirection` 二参版与已弃用的 `currentDirectionWord` 一并删除。
- 面板流向行功率数字与形态同源：遥测裁决时取遥测 `|BP|`（与三角图边标签一致），遥测缺席回退 `V×I`（既有行为）。
- 全门禁：584 场景（+6 净增：投影等价性 ×2、方向四态映射 ×4；用例 92/108 迁移为 kind 版并改写期望）、318 张快照（+12：`PowerFlow_assist` / `StatusLine_assist` 各 6，复刻真机现场 SP 29.8 W / BP −22.6 W / 协商 32 W；既有 306 张零 diff 实证）、l10n 439 key（+8）、状态机覆盖率 90.59%。
- 无配置项 / 线协议变更；升级后限值 / 风扇 / 日程 / LED 配置原样保留。
- 方案与评审记录：docs/plans/phase5-0.19.4-assist-wording.md（本地，R1 REVISE 九条处置 → R2 PASS 定稿）。

## [0.19.3-alpha] - 2026-09-09

### Fixed

- **功率流向数字跨源不一致修复（三角图三边恒守恒）**：适配器节点与系统节点取自硬件遥测（节流 ~25-30s），电池边取电池 V×I（App 侧 1s 采样）——两个不同龄的源在负载/充电态变化时必然对不上（走查五张截图实测源差 0.0 / 0.3 / 1.6 / 17.3 / 1.6 W）。现外接态三条边的功率数字**一律取自同一遥测快照**（遥测缺席回退 V×I；电池供电态维持 V×I——单一路径、方向由外接态唯一确定）。电池边同时恢复既有 0.05 W 显示阈值（不再产出「−0.0 W」）。
- **新增「电池补入」形态**：弱适配器 + 高负载时系统保持 `IsCharging=Yes` 而电池实际放电补差，旧实现按策略位画出不存在的「适配器→电池」充电流并标 `+6.5 W`（诱发 `36.4 + 6.5` 的错误加法；真实守恒为 `29.9(适配器) + 6.5(电池补入) = 36.4(系统)`）。现外接 + 实测 `BatteryPower < −50 mW` → 画 直供边（标适配器实际输出）+ 电池→系统边（标「电池补入 X W」），`直供边 + 电池边 = 系统节点`。实测符号裁决，不再由策略位派生。
- **电池规格卡符号与流向图同源裁决**：功率/电流行正负号改由实测形态决定（受电 `+` / 供给 `−`），不再由 `isCharging` 强制；功率行在取遥测值时标注「功率 · 遥测」。
- **适配器「额定」改「协商」**：`AdapterDetails.Watts/Voltage/Current` 是 PD 协商档位（活体实测：合同 28V×4.99A=140W 而实际输入 20.77W），非铭牌额定、非实时输出——适配器卡行与面板状态行措辞改为「协商」。

### 备注

- 数据层无恙：遥测内部恒等式（`SystemPowerIn = SystemLoad + BatteryPower`）在走查五张截图**全部精确成立**，缺陷只在显示层的取数源与符号派生。
- 判定逻辑下沉纯函数 `CellarCore.flowDiagramModel`（+19 场景钉死判定表、回退等价性与边界：ε=50mW、|BP|==50 落零流、`loadW<0` 不造数、V×I<0.05 无标签）。
- 全门禁：578 场景、306 张快照（+6 assist 全新；6 张 `StatusLine_telemetry` 因「额定→协商」措辞变更登记 regen，其余 294 张零 diff）、l10n 431 key（+3）、状态机覆盖率 90.57%。
- **已知形态（非缺陷，独立批跟进）**：补入态下**面板**流向行/电源态词/电流方向词、以及**主窗口**头栏徽章「充电中」与适配器卡状态词「直供 + 充电」仍由策略位派生，与本批主窗图形并存——同一根因（策略位 vs 实测流向），需 `theme.word` ×3 风格词汇决策，留作后续批；ε 带内（|BP| ≤ 50mW）徽章「充电中」而图形无电池边，同属该清单。
- 电池卡「功率 · 遥测」行取遥测值（~30s），电压/电流为实时读数——两者在遥测窗内可有 ≤10% 差（同一物理量的两个采样时刻）。

## [0.19.2-alpha] - 2026-09-09

### Changed

- **功率流向图流光点 30fps 上限钳制（主窗口可见态 CPU 优化）**：`TimelineView(.animation)` → `.animation(minimumInterval: 1/30)`（macOS 12+ API，包平台 13 满足，本机 SDK swiftdoc 语义核实=「更新频率不快于该间隔」）。`.animation` 缺省跟随屏幕刷新率（60Hz / ProMotion 120Hz），每帧全量 Canvas 重绘（节点+边+标签+光点）是主窗口仪表板可见态持续 CPU 的最大单项；钳 30fps 后 60Hz 屏帧成本减半、120Hz 屏减 3/4。**替代 v1.2 验收标准「60fps 目标」**（本地私有 plans 文档不改历史，判据更替在此记录）。

### 备注

- 光点相位取绝对时间（周期恒 1.9/2.0/2.6s），降采样只减帧数不减周期——视觉无差；静帧/reduceMotion/快照路径零改动：300 张快照零 diff、559 场景、l10n 428 key、覆盖率 90.43% 全绿。
- 复核方法记录：TimelineView 全库唯一消费点经 `command grep` 确认——ugrep 包装尊重 .gitignore 会静默跳过 docs/，全库检索须防此类假阴性。
- 同批评估不采纳：daemonStatus 发布等值去重（收益不可测——全表面关闭实测 0.0% CPU、可见态重渲染大头为遥测采样与本动画；且该状态管线为 0.19.1 刚修复面，风险收益不成比）。
- 本项源自外部资源分析工具误诊的排查收官（其「4s 常驻轮询/每次刷新含 SQLite 写/UpdateCycle 库」前提均与代码不符，静息实测 0.0%）；部署后验收：主窗口仪表板可见态 `top -pid $(pgrep -x Cellar)` 前后采样对比 + 光点平滑度目视。

## [0.19.1-alpha] - 2026-09-08

### Fixed

- **菜单栏电池图标电源徽标冻结修复（插拔电不刷新、点击面板才更新的根因）**：电池形态的充电闪电/维持插头徽标取值链把 App 侧遥测快照 `batterySnapshot` 排在 IOPS 实时电源态之前，而快照只在面板/主窗口可见时采样且停采样时从不清空——面板关闭后最后一次采样值被永久冻结：拔电后闪电不消失、插电后不显插头，点击面板（重开遥测）才刷新。现 `refreshCadence()` 在全表面关闭时即时清空快照，电池形态自动回退 IOPS 活数据（`powerOverride`，含 1.5/5/15/30s 复查阶梯）+ `daemonStatus` 百分比；配套在途采样竞态守卫（关面板瞬间已起飞的采样不得把可见时刻的值重新冻进快照）。
- **取值链纯函数化**：电池形态取值链抽至 `CellarCore.menuBarBatteryForm`（与原实现逐字段等价），由「电池形态」域 8 个新场景钉死回退链与优先级（场景总数 559）。

### 备注

- 数据链本身无恙：IOPS 事件订阅、daemon 插电即时执法（≤1-2s 恢复充电）均按既有设计工作，坏的只是图标的取数优先级与快照生命周期；「插头→闪电」的间隔是系统真实起充节奏，显示如实跟随。
- 面板/主窗口可见时的行为零变化（1s IOKit 采样）；重开面板首帧可能短暂呈现「遥测不可用」降级形态（有界于一次采样时长，随即被即时补采样覆盖）——用瞬时降级换永久陈旧，方向正确。
- 快照 300 张零扰动、l10n 428 key 零增减、状态机覆盖率 90.43%（阈值 90%）。

## [0.19.0-alpha] - 2026-09-08

### Added

- **双风扇同步接管（Phase 5 v1.12）**：风扇智能降温的 boost 介入从「仅 F0」扩为「F0+F1 每风扇槽位状态机」——同开关、同策略、同阈值驱动两扇，各扇按各自 [Mn, Mx] 独立 clamp（F1Mn=1522/F1Mx=5777），进入/冲突检测/能力验证全槽位独立（诚实隔离：一扇失败不拖累另一扇，三连败自动停用该扇回到系统自控）。单风扇机型行为零变化（F1Mn 键缺席 sticky 识别，零额外 SMC 流量）。
- **F1 写通路 spike 实测 GO**（前置门，Tools/spike-fan-f1.swift）：F1Md=1 解锁 → F1Tg=3650 直写 60s 全窗驻留、转速跟随（T+6s 起 min=3620.9 ≥ 阈 3350）、还原干净；Md=0 直写固件即时拒绝（与 F0 同构镜像）。新事实：F1Md 锁存延迟 ∈(100,400]ms——既有 verifyLadder [100,300,800]ms 第二档覆盖，生产零调参。
- **doctor 检查 12 扩面**：F1 键族在位矩阵 + F1Md/F1Tg 现态（同款「配置开启=合法介入态 INFO / 关闭态≠0=残留 WARN」分流）；风扇区第二风扇状态行（secondFanPresent 时左/右双行各自带状态词与目标转速）。
- **XPC 载荷向后兼容**：FanStatus 追加 secondFanPresent/State/TargetRPM/CurrentRPM 四可选字段（新 App + 旧 daemon → nil 隐藏第二行；旧 App + 新 daemon → 忽略未知键，线上字节形态零新增键）。

### 备注

- 决策纯函数层（FanGuard）零修改复用——签名本就按键无关参数化，既有风扇域测试场景全部零修改即回归门。
- 无新增配置项、policy.json 零迁移（升级后限值/风扇配置原样保留）。
- 仍为 boost-only 红线：只抬高不压低，静息交还系统；释放统一 Md=0 规范值。

## [0.18.7-alpha] - 2026-09-07

### Fixed

- **菜单栏电池图标徽标缺失修复（第六轮，自绘位图路线定版）**：0.18.6 五档符号方案的充电/维持徽标（第二个 Image）仍被菜单栏 label 渲染管道丢弃（真机截图实证：电量填充渲染而徽标消失）。本轮以**最小 App + 真菜单栏截图对照 spike** 一次性实证七种候选形态：`Image(nsImage:)` 自绘位图整体渲染、位图内合成元素全部可见、非模板彩色位图显色；双 Image 平铺的第二个必被丢弃（复现）。据此电池图标改为**单一自绘 NSImage 位图**：电池轮廓 + **连续比例填充**（六轮以来首次回归 demo 设计的连续形态，0.18.6 五档量化退役）+ 充电闪电/维持插头徽标合成进位图（destinationOut 挖对比环，任何填充量下可读）+ 低电量（< 15%）红色实绘（非模板位图，spike 实证显色）。
- **部署修复**：install 版本核对报错方向修正前先解决 CLI 半旧构建问题（`swift build -c release` 完整重建后三方版本一致）。

### 备注

- 菜单栏 label 渲染边界定版补全（六轮实证链）：除裸 Image/Text + HStack 平铺外，`Image(nsImage:)` 单位图为**唯一可行的复合形态**——填充、徽标、着色全部在一张位图内合成。
- 生产渲染器代码原样抽入 spike 编译并逐状态像素验证后上车（流程中抓出 NSBezierPath 合成参数与 rep.size 回设两问题）。
- 仅菜单栏 label 改动，充电执法路径与 App 层组装零改动。

## [0.18.6-alpha] - 2026-09-07

### Fixed

- **菜单栏电池电量图标真机走查修复（第五轮，五档符号 + 徽标平铺）**：0.18.5 双层裁剪方案真机实证两层不渲染——只有底层空腔轮廓上屏（电量恒显空），顶层 `frame/clipped` 裁剪填充层与 `ZStack/offset` 覆盖定位徽标层均被菜单栏 label 渲染管道丢弃。现收敛为**五轮实证唯一可靠形态**：电量按就近映射取五档符号（`battery.0/25/50/75/100percent`，阈值 12.5/37.5/62.5/87.5，最大误差 ±12.5%，80% → 75percent 不顶满），充电闪电/外接维持插头徽标改 HStack 平铺同级排布。
- **徽标符号修正**：0.18.5 使用的 `plug.fill` 在 macOS 26 不存在（`NSImage` 探测 MISSING，缺失符号渲染为空）——改用实测在位的 `powerplug.fill`；徽标符号经运行时存在性校验，缺失自动降级为无徽标（不伤电池本体显示）。

### 备注

- 菜单栏 label 渲染边界定版（五轮实证链）：裸 `Image(systemName:)`/`Text` + HStack 平铺 ✅；`variableValue`（恒满格）、`Canvas`（不渲染）、`frame/clipped` 裁剪层、`ZStack/offset` 覆盖层 ✗。连续比例填充在该管道无可用机制，NSImage 位图路线留待后续 spike 实证评估。
- 低电量（< 15%）红色沿袭 alert 分支 `.renderingMode(.original)` + `foregroundStyle` 在产先例。
- 仅菜单栏 label 改动，充电执法路径与 App 层组装零改动；既有快照零修改（App 层无 golden 覆盖，走真机走查门）。

## [0.18.5-alpha] - 2026-09-07

### Fixed

- **菜单栏电池电量图标形态修复（第四轮，双层 SF Symbols 裁剪）**：0.18.4 的 Canvas 自绘在菜单栏 label 不渲染（图标不可见）——改用底层空腔轮廓 + 顶层满格电池按电量比例宽度裁剪的全 Image 路径。（后续 0.18.6 真机实证该裁剪层亦不被渲染，已再修正。）

### Changed

- 充电日程全天窗口收尾：守护进程侧拒绝文案同步（0.18.1 遗留）。
- 退役 Canvas 版电池图形组件（MenuBatteryGlyph，被双层裁剪方案替代）。

### 备注

- 本版 CHANGELOG 条目在发布提交中遗漏，0.18.6 补记。

## [0.18.4-alpha] - 2026-09-07

### Fixed

- **菜单栏电池图标充电态恒满格修复（第三轮，自绘方案）**：前两轮依赖的 SF Symbols `variableValue` 电量填充在菜单栏 template 单色渲染下不可见（符号默认形态即满格轮廓）——本轮改为 **Canvas 自绘电池组件**：外壳描边 + 端子 + 按实际电量比例的内部填充，逐元素可控不再依赖系统符号渲染行为。
- **状态标识入电池**：充电中显示中央闪电挖空（透出菜单栏背景，原生充电图标同款观感）；外接未充电（停充维持）显示插头挖空；电池供电无标识。
- **低电量告警**：电量 < 15%（具名常量）填充转红；低电量 + 充电为红填充 + 白闪电实绘（对比度最大）。

### 备注

- 停充维持、15-35% 部分填充区间：中央标识落在填充之外时无可见标识——为「挖孔只作用于填充」的固有语义（与原生图标一致），登记备查。
- 本修复仅菜单栏 label，App 层组装；既有快照零修改。

## [0.18.3-alpha] - 2026-09-07

### Fixed

- **菜单栏电池图标充电态恒满格修复**：充电中原走 `battery.100percent.bolt` 单体符号（该符号不支持电量填充，恒显满格）；现全状态统一为随实际电量连续填充的电池图形，充电语义改由叠加的小闪电徽标承载（放电/维持由填充电量自然表达）。
- **系统负载显示语义修正**：外接供电时「系统负载」原直显遥测 `SystemLoad` 字段——实测该字段语义与「系统负载消耗」不符（静息显示 86.9W 虚高，且与适配器输入/电池充电功率违反守恒）；现改为**守恒推导值**（适配器输入 − 电池充电功率，两字段均已物理验证），静息合理区间 ~20-30W。

### 备注

- `SystemLoad` 字段真实语义登记 v1.12 考证（spike 控制变量实测）。
- 功率闭环自检口径更新：适配器输入 ≈ 系统负载（推导） + 电池充电功率。

## [0.18.2-alpha] - 2026-09-07

### Fixed

- **功率流向充电态边标签语义修正**：充电中适配器→系统边误显「直供 · 总输入 W」（与电池充电边并排诱发错误加法）；现充电态显示该边真实流量「系统负载 · X W」（遥测 SystemLoad 字段），停充态「直供」语义保持不变。
- **系统节点充电/停充态补实测负载**：外接供电时系统节点原显「—」；现遥测在场显示实测系统负载（W），遥测缺席仍显「—」不造数。

### 备注

- 功率闭环自检：适配器输出 ≈ 系统负载 + 电池充电功率（遥测三字段恒满足）。「额定 140 W」为适配器能力上限，非当前总输出。

## [0.18.1-alpha] - 2026-09-07

### Added

- **充电日程支持「全天」窗口**：结束时间新增「24:00」档——00:00–24:00（或开始 = 结束任意相同时刻，自动归一）即全天生效；守护进程窗口判定算法同步扩展，星期与互补组合语义不变。
- **日程「待生效」标注**：充电日程列表双态标注——当前命中的条目显「生效中」，其余已排程条目显「待生效」，消除互补日程「为什么只有一条生效」的困惑。
- **面板风扇来源标注**：左/右风扇转速旁显示当前控制来源（系统 / Cellar）——未达阈值时的底速运转是系统自控行为，一目了然。

### Changed

- 充电日程时间选择改为固定高度内滚弹出（不再撑出窗口）。
- 移除充电控制页的重复校准入口（校准页保留完整功能）。
- 主窗口标题栏不再显示「芯仓」文字（品牌标识保留在侧栏与菜单栏）。
- 容量趋势卡横轴标签恢复显示（0.18 回归修复）。

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
