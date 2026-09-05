// CellarUICheck —— 快照矩阵工具（WP4 §3，自研零第三方依赖）
//
// 三模式：
//   --snapshot [--regen]  重生成 golden（镜像/字体/组件变化后由 CI 或人工触发）
//   --snapshot（默认）     对比模式：渲染矩阵并逐像素比对 golden（差异即红）
//   --l10n                机械门：枚举 catalog 全 key × {en, zh-Hans}，断言
//                         CellarL10n 解析值 ≠ key（缺译即红；同时验证 s() 通路）
//
// 渲染纪律（方案 §3.1）：ImageRenderer scale=1、固定 proposedSize、env 注入
// colorScheme + layoutDirection=.leftToRight + displayScale=1、禁动画；PNG 落盘
// 前经 sRGB CGContext 白底合成去 alpha（硬事实 8 归一化）。容差判定写死：尺寸
// 不同=fail；任一通道 |Δ|>2 = 差异像素；差异占比 >0.5% = fail。
//
// ⚠️ golden 语言钉死（§3.3 golden=en）：进程启动首行设 AppleLanguages=en。
// 实测注记：swift build 形态下资源 bundle 为原始 .xcstrings（无 lproj），Foundation
// 只认开发语言 zh-Hans——语汇文本恒为 zh-Hans（形态钉死、跨机确定性成立）；
// en 钉入在 SwiftPM 未来支持 xcstrings 编译后自动生效（届时 regen 一次）。

import CellarCore
import CellarUI
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

// MARK: - 启动钉语言（必须在任何本地化查找/渲染之前）

UserDefaults.standard.set(["en"], forKey: "AppleLanguages")

// MARK: - 路径（#filePath 推导仓库根，cwd 无关）

/// 仓库根：main.swift 位于 <root>/Sources/CellarUICheck/，回退三级。
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/CellarUICheck
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // 仓库根

let goldensDir = repoRoot.appendingPathComponent("Snapshots/Goldens")
let catalogURL = repoRoot.appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")

// MARK: - 矩阵案例定义（§3.3 N = 108：组件 × 风格(2) × 外观(2) × 态；
// WP2' 自 48 扩 60——PowerFlow 12 新增；WP1 自 60 扩 64——状态行温度暂停态 4 新增；
// WP3 自 64 扩 76——校准区 3 态 12 新增；Phase 5 v1.1 自 76 扩 84——风扇区 2 态 8 新增；
// Phase 5 v1.2 首页 自 84 扩 92——页脚链接 2 态 8 新增；
// Phase 5 v1.2 仪表板 自 92 扩 108——功率流三角图 3 态 12 新增 + 占位页 1 态 4 新增；
// Phase 5 v1.2 走查批 自 108 扩 112——功率流三角图 nodata 空态 4 新增（前 3 态 12 张 M regen：Canvas 测量自适应 F2 + 流动语义统一 F3）；
// Phase 5 v1.4 自 112 扩 132——校准调度卡 3 态 12 新增 + 上次校准卡 2 态 8 新增；
// Phase 5 v1.5 自 132 扩 140——充电热保护卡 2 态 8 新增）

/// 单案例：golden 文件名 `<组件>_<态>_<style>_<scheme>.png` + 视图构造。
struct SnapshotCase {
    let name: String
    /// width 固定提案（面板内容宽 = 340 - 2×18 padding；Gauge 150×150 正方）。
    let width: CGFloat
    /// nil = 高度自然（理想高度）；Gauge 固定 150。
    let height: CGFloat?
    let style: PanelStyle
    let scheme: ColorScheme
    let makeView: @MainActor () -> AnyView

    /// 显式 init：含 @MainActor 闭包属性时 memberwise init 隔离推断冲突（Swift 6）。
    init(
        name: String,
        width: CGFloat,
        height: CGFloat?,
        style: PanelStyle,
        scheme: ColorScheme,
        makeView: @escaping @MainActor () -> AnyView
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.style = style
        self.scheme = scheme
        self.makeView = makeView
    }
}

// 快照基准时刻（快照 timestamp 不参与渲染，恒定值消除随机源）。
private let fixedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

/// 真实型快照构造：走 BatterySnapshotParser 纯函数（与生产同一解析路径），字段
/// 形状仿 AppleSmartBattery 注册表实测（BatterySnapshot.swift 注记）。
/// temperatureCentiC 可注入（默认 3100 = 31.0 °C——WP1 温度暂停态需 40+ 高温）。
private func makeSnapshot(
    percent: Int,
    isCharging: Bool,
    externalConnected: Bool,
    amperageMA: Int,
    temperatureCentiC: Int = 3_100,
    adapter: [String: Any]?
) -> BatterySnapshot? {
    var props: [String: Any] = [
        "CurrentCapacity": percent,
        "IsCharging": isCharging,
        "ExternalConnected": externalConnected,
        "Voltage": 11_670,
        "Amperage": amperageMA,
        "Temperature": temperatureCentiC,
        "CycleCount": 123,
        "DesignCapacity": 6_300,
        "MaxCapacity": 100,
        "FullyCharged": false,
        "AppleRawMaxCapacity": 6_087,
        "AppleRawCurrentCapacity": 4_838,
        // WP2' 健康度：Nominal 显式在场（6030/6300 → 96%——与 rawMax 兜底 97%
        // 有区分度，golden 钉死「循环 123 · 健康 96%」）。
        "NominalChargeCapacity": 6_030,
        "BatteryData": ["CellVoltage": [3_890, 3_895, 3_888], "FccComp1": 5_900],
    ]
    if let adapter {
        props["AdapterDetails"] = adapter
    }
    // 造数失败 = 造数错误（非容错路径），fail-fast——评审 M1：return nil 会让
    // --regen 把「遥测不可用」退化态静默烤成 golden（stderr 一行 + 退出码 0），
    // 坏基线入库即失去回归防护；此处直接终止进程。
    do {
        return try BatterySnapshotParser.parse(props, timestamp: fixedTimestamp)
    } catch {
        FileHandle.standardError.write("造数解析失败：\(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// 主题注入 + 渲染环境统一（colorScheme/layoutDirection/displayScale/禁动画）。
@MainActor
private func wrap(
    _ style: PanelStyle,
    _ scheme: ColorScheme,
    @ViewBuilder _ content: () -> some View
) -> some View {
    let theme = CellarTheme.resolve(style: style, scheme: scheme)
    return content()
        .environment(\.cellarTheme, theme)
        .tint(theme.accent)
        .environment(\.colorScheme, scheme)
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.displayScale, 1)
        .transaction { $0.animation = nil }
}

// MARK: 140 案例清单（WP2'：仪表 20 + 状态行 20 + 功率流向 12 + 横幅 12；
// WP1 自 60 扩 64——状态行温度暂停态 4 新增；WP3 自 64 扩 76——校准区 3 态 12 新增；
// Phase 5 v1.1 自 76 扩 84——风扇区 2 态 8 新增；Phase 5 v1.2 页脚 自 84 扩 92——
// 页脚链接 2 态 8 新增；Phase 5 v1.2 仪表板 自 92 扩 108——功率流三角图 3 态 12
// 新增 + 占位页 1 态 4 新增；走查批 自 108 扩 112——功率流三角图 nodata 4 新增；
// Phase 5 v1.4 自 112 扩 132——校准调度卡 3 态 12 新增 + 上次校准卡 2 态 8 新增；
// Phase 5 v1.5 自 132 扩 140——充电热保护卡 2 态 8 新增）

@MainActor
private func buildCases() -> [SnapshotCase] {
    var cases: [SnapshotCase] = []
    let styles: [PanelStyle] = [.native, .amber]
    let schemes: [ColorScheme] = [.light, .dark]

    // 仪表 5 态（充电中/保持/电池供电/无数据/band==nil）×4。
    let gauges: [(String, GaugeState)] = [
        ("charging", GaugeState(percent: 85, band: 78...80, isCharging: true,
                                axLabel: "当前电量 85%，充电上限 80%，充电中")),
        ("holding", GaugeState(percent: 80, band: 78...80, isCharging: false,
                               axLabel: "当前电量 80%，充电上限 80%，已停充")),
        ("battery", GaugeState(percent: 62, band: 78...80, isCharging: false,
                               axLabel: "当前电量 62%，充电上限 80%，电池供电")),
        ("nodata", GaugeState(percent: nil, band: nil, isCharging: false,
                              axLabel: "电量遥测不可用")),
        ("bandNil", GaugeState(percent: 45, band: nil, isCharging: false,
                               axLabel: "当前电量 45%，电池供电")),
    ]
    for style in styles {
        for scheme in schemes {
            for (stateName, state) in gauges {
                cases.append(SnapshotCase(
                    name: "Gauge_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 150, height: 150, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) { GaugeView(state: state) })
                })
            }

            // 状态行 5 态（充电/停充漂浮/电池供电/温度暂停/遥测不可用）×4。
            let charging = makeSnapshot(percent: 85, isCharging: true, externalConnected: true,
                                        amperageMA: -1_800,
                                        adapter: ["Watts": 96, "AdapterVoltage": 20_150,
                                                  "Current": 4_770, "Name": "96W USB-C Power Adapter",
                                                  "Description": "adapter", "IsWireless": false])
            // 停充漂浮：外接 + 已停充 + 毫安级维持电流（适配器照常在位）。
            let holdingFloat = makeSnapshot(percent: 80, isCharging: false, externalConnected: true,
                                            amperageMA: -30,
                                            adapter: ["Watts": 96, "AdapterVoltage": 20_150,
                                                      "Current": 4_770, "Name": "96W USB-C Power Adapter",
                                                      "Description": "adapter", "IsWireless": false])
            // 电池供电：无适配器（AdapterDetails 缺席 → 整段隐藏、留空位）。
            let battery = makeSnapshot(percent: 62, isCharging: false, externalConnected: false,
                                       amperageMA: 950, adapter: nil)
            // WP1 温度暂停态：tempPauseActive=true + 高温快照（4020 厘摄氏度 =
            // 40.2 °C）——温度段注词「40.2 °C · 暂停中」形态钉死（方案 §4.2）。
            let tempPaused = makeSnapshot(percent: 80, isCharging: false, externalConnected: true,
                                          amperageMA: 0, temperatureCentiC: 4_020,
                                          adapter: ["Watts": 96, "AdapterVoltage": 20_150,
                                                    "Current": 4_770, "Name": "96W USB-C Power Adapter",
                                                    "Description": "adapter", "IsWireless": false])
            let statusLines: [(String, BatterySnapshot?, Bool)] = [
                ("charging", charging, false),
                ("holdingFloat", holdingFloat, false),
                ("battery", battery, false),
                ("tempPaused", tempPaused, true),
                ("telemetryNil", nil, false),
            ]
            for (stateName, snapshot, tempPause) in statusLines {
                cases.append(SnapshotCase(
                    name: "StatusLine_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        StatusLineView(snapshot: snapshot, tempPauseActive: tempPause)
                            .frame(width: 304, alignment: .leading)
                    })
                })
            }

            // 功率流向 3 态（充电/停充漂浮/电池供电）×4（WP2' §4.2 新增 12 张）：
            // 输入 = 快照两字段投影（externalConnected/isCharging）；onBattery 以
            // (false, false) 入阵（(false, true) 为异常过渡态按 .charging 呈现，映射
            // 语义由 PowerFlowView.flow 单一实现，矩阵 3 态全绿即覆盖）。
            let powerFlows: [(String, Bool?, Bool?)] = [
                ("charging", true, true),
                ("floating", true, false),
                ("onBattery", false, false),
            ]
            for (flowName, external, charging) in powerFlows {
                cases.append(SnapshotCase(
                    name: "PowerFlow_\(flowName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        PowerFlowView(externalConnected: external, isCharging: charging, batteryPowerW: flowName == "charging" ? 33.0 : flowName == "onBattery" ? -8.2 : nil)
                            .frame(width: 304, alignment: .leading)
                    })
                })
            }

            // 横幅 3 态（控制失败/daemon 失联/statusFailure writeFailed）×4。
            // ⚠️ lastAttemptSummary / statusFailureMessage 为生产同款字面量：
            // ControlAttempt.summary 与 StatusFailureKind.message 均为 App 层
            // （WP4 未迁），CellarUICheck 不可达——以真实型反馈构造 + 同文案注入。
            let banners: [(String, AlertBanner)] = [
                ("controlFailed", AlertBanner(
                    feedback: .transferFailed, connection: .connected,
                    lastAttemptSummary: "设置上限 80%", statusFailureMessage: nil, onRetry: {})),
                ("daemonUnreachable", AlertBanner(
                    feedback: nil, connection: .unreachable,
                    lastAttemptSummary: nil, statusFailureMessage: nil, onRetry: {})),
                ("writeFailed", AlertBanner(
                    feedback: nil, connection: .connected,
                    lastAttemptSummary: nil,
                    statusFailureMessage: "充电控制写入失败，限充可能未生效——请打开面板查看",
                    onRetry: {})),
            ]
            for (stateName, banner) in banners {
                cases.append(SnapshotCase(
                    name: "AlertBanner_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        banner.frame(width: 304, alignment: .leading)
                    })
                })
            }

            // 校准区 3 态（idle/确认块/运行中放电相）×4（WP3 §2.5 新增 12 张，
            // 64 → 76）：参数驱动组件直接构造（onStart/onCancel 空闭包——渲染无
            // 副作用；running 相位钉死放电相——相位词 + 电量组合的代表形态）。
            let calibrations: [(String, CalibrationSectionView)] = [
                ("idle", CalibrationSectionView(
                    calibrationActive: false, phase: nil, percent: nil,
                    capabilityPresent: true, modeActive: true, busy: false,
                    onStart: {}, onCancel: {})),
                ("confirm", CalibrationSectionView(
                    calibrationActive: false, phase: nil, percent: nil,
                    capabilityPresent: true, modeActive: true, busy: false,
                    onStart: {}, onCancel: {}, initialConfirmVisible: true)),
                ("running", CalibrationSectionView(
                    calibrationActive: true, phase: .discharge, percent: 23,
                    capabilityPresent: true, modeActive: true, busy: false,
                    onStart: {}, onCancel: {})),
            ]
            for (stateName, section) in calibrations {
                cases.append(SnapshotCase(
                    name: "Calibration_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        section.frame(width: 304, alignment: .leading)
                    })
                })
            }

            // Phase 5 v1.1 风扇区 2 态（关闭/两级分段开启）×4（76 → 84，新增 8 张）：
            // 参数驱动组件直接构造（onApply 空闭包——渲染无副作用；on 态钉死
            // twoStage——滑杆参数显形的代表形态 + 状态行「自动」）。
            let fanSections: [(String, FanSectionView)] = [
                ("off", FanSectionView(
                    fan: FanStatus(
                        enabled: false, strategy: .constantSpeed, state: .off,
                        targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700,
                        conflictFlag: false
                    ),
                    busy: false, onApply: { _ in })),
                ("on", FanSectionView(
                    fan: FanStatus(
                        enabled: true, strategy: .twoStage, state: .automatic,
                        targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700,
                        conflictFlag: false, speedPercent: 50, stage2Percent: 80,
                        stage2RiseCentiC: 300
                    ),
                    busy: false, onApply: { _ in })),
            ]
            for (stateName, section) in fanSections {
                cases.append(SnapshotCase(
                    name: "FanSection_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        section.frame(width: 304, alignment: .leading)
                    })
                })
            }

            // Phase 5 v1.2 页脚链接 2 态（idle/hover）×4（84 → 92，新增 8 张）：
            // 参数驱动组件直接构造（onMainWindow/onQuit 空闭包——渲染无副作用）；
            // M3.5 两链接形态（左「主窗口」+ 右「退出 Cellar」，设置链接随设置窗
            // 退役移除，共 108 张数量不变）；hover 态钉死 initialHoveredLink:
            // .mainWindow（golden hover 代表形态）——单钮强调、余钮常态（hover
            // 是运行时鼠标态，矩阵以注入钉死）。
            let footers: [(String, FooterLink?)] = [
                ("idle", nil),
                ("hover", .mainWindow),
            ]
            for (stateName, hoveredLink) in footers {
                cases.append(SnapshotCase(
                    name: "FooterLinks_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        FooterLinksView(onMainWindow: {}, onQuit: {}, initialHoveredLink: hoveredLink)
                            .frame(width: 304, alignment: .leading)
                    })
                })
            }

            // Phase 5 v1.2 功率流三角图 4 态（充电/停充/电池/nodata）×4（108 → 112，
            // 走查批：nodata 新增 4 张 + 前 3 态 12 张 M regen——Canvas 测量自适应
            // F2 + 流动语义统一 F3 变更绘制路径）：几何 = mock viewBox 560×244
            // （快照钉死画布尺寸——几何比例确定性）；⚠️ initialAnimating 恒
            // false——动画帧不确定会毁 golden 对比（快照注入口纪律，§3.2）；
            // 状态行 = App 组装同款形态（诚实口径：充电/停充态系统负载无实测
            // →「—」）。
            let diagramStates: [(String, PowerFlowDiagramView)] = [
                ("charging", PowerFlowDiagramView(
                    state: .charging, batteryPercent: 78, batteryVoltage: "12.3 V",
                    adapterLine: "65 W · 在位", systemLine: CellarL10n.s("common.nodata"),
                    powerAB: "+33.4 W", supplyLine: "直供", initialAnimating: false)),
                ("holding", PowerFlowDiagramView(
                    state: .holding, batteryPercent: 81, batteryVoltage: "12.3 V",
                    adapterLine: "65 W · 在位", systemLine: CellarL10n.s("common.nodata"),
                    supplyLine: "直供", initialAnimating: false)),
                ("battery", PowerFlowDiagramView(
                    state: .battery, batteryPercent: 62, batteryVoltage: "11.9 V",
                    adapterLine: "未接入", systemLine: "12.4 W 负载",
                    powerBS: "−12.4 W", initialAnimating: false)),
                // 走查批入阵：nodata 空态 4 张（108 → 112）——三灰卡悬浮无连线
                // （F3 §2.2）；数值字段全部空（drawNodes 侧经 common.nodata 投影）。
                ("nodata", PowerFlowDiagramView(
                    state: .nodata, batteryPercent: nil, batteryVoltage: "",
                    adapterLine: "", systemLine: "",
                    initialAnimating: false)),
            ]
            for (stateName, diagram) in diagramStates {
                cases.append(SnapshotCase(
                    name: "PowerFlowDiagram_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 560, height: 244, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) { diagram })
                })
            }

            // Phase 5 v1.2 占位页 1 态（校准等占位代表形态——图标/标题/范围/
            // 版本全参数）×4（104 → 108，新增 4 张）：⚠️ v1.3 统计实页化后
            // main.page.stats.scope 退役（App 层零消费、catalog 已删）——本态
            // 以退役前 zh 原文字面量钉死，golden 逐字节不变（swift build 形态
            // s() 本就恒解析 zh-Hans，语义等价）；组件仍被校准/自动化占位消费。
            let placeholder = TBDPlaceholderView(
                icon: "chart.bar",
                title: CellarL10n.s("main.page.stats"),
                scope: "电量 / 窖温 / 功耗历史曲线 · 最大容量趋势 · 循环与健康档案——SQLite 周期采样（后台分钟级，不成为耗电源）。",
                version: "v1.3"
            )
            cases.append(SnapshotCase(
                name: "TBDPlaceholder_stats_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                width: 460, height: nil, style: style, scheme: scheme
            ) {
                AnyView(wrap(style, scheme) { placeholder.frame(width: 460) })
            })

            // 校准调度卡 3 态（legacy/off/on）×4（Phase 5 v1.4 §3.3 新增 12 张，
            // 112 → 124）：门控二态照方案 §7-M3-2——schedule nil = 旧 daemon 升级
            // 提示 / 非 nil 且 false = off 态（勿把未配置当旧 daemon）；on 态
            // nextEstimateText 以 zh 原文字面量钉死（墙钟文案含本地时区语义，不进
            // 组件——上方占位页同款手法，golden 跨时区逐字节不变）。
            // onApply 空闭包——渲染无副作用。
            let scheduleSections: [(String, ScheduleSectionView)] = [
                ("legacy", ScheduleSectionView(
                    schedule: nil, busy: false, nextEstimateText: nil, onApply: { _ in })),
                ("off", ScheduleSectionView(
                    schedule: CalibrationSchedulePolicy(enabled: false, intervalDays: 30, startHour: 1),
                    busy: false, nextEstimateText: nil, onApply: { _ in })),
                ("on", ScheduleSectionView(
                    schedule: CalibrationSchedulePolicy(enabled: true, intervalDays: 30, startHour: 1),
                    busy: false,
                    nextEstimateText: "下次自动校准：11 月 15 日 01:00 前后",
                    onApply: { _ in })),
            ]
            for (stateName, section) in scheduleSections {
                cases.append(SnapshotCase(
                    name: "ScheduleSection_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        section.frame(width: 304, alignment: .leading)
                    })
                })
            }

            // 上次校准卡 2 态（有记录/无记录）×4（124 → 132，新增 8 张）：记录态
            // timeText/outcomeText 以 zh 原文字面量钉死（墙钟文案，同上手法）；
            // durationSeconds = 27_000 秒 = 7 小时 30 分（组件内纯间隔格式化，跨机
            // 确定——真实格式化路径入 golden）。
            let lastCalibrations: [(String, LastCalibrationView)] = [
                ("record", LastCalibrationView(
                    timeText: "11 月 15 日 01:00", outcomeText: "完成", durationSeconds: 27_000)),
                ("never", LastCalibrationView(
                    timeText: nil, outcomeText: nil, durationSeconds: nil)),
            ]
            for (stateName, section) in lastCalibrations {
                cases.append(SnapshotCase(
                    name: "LastCalibration_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        section.frame(width: 304, alignment: .leading)
                    })
                })
            }

            // 充电热保护卡 2 态（legacy/configured）×4（Phase 5 v1.5 §3.3 新增 8 张，
            // 132 → 140）：门控二态照方案 §7-M3-2——thermal nil = 旧 daemon 升级提示
            // （照 ScheduleSection legacy 先例）/ 非 nil = 配置态（configured 钉死默认
            // 40.0/3.0——恢复点派生 37.0 同帧验证）。onApply 空闭包——渲染无副作用；
            // 滑杆/恢复点数值走 String(format:) printf 通路，无钟面/本地区化风险，
            // 无需预格式化注入（fan 阈值行同款先例）。
            let thermalSections: [(String, ThermalSectionView)] = [
                ("legacy", ThermalSectionView(thermal: nil, busy: false, onApply: { _ in })),
                ("configured", ThermalSectionView(
                    thermal: ThermalStatus(pauseCentiC: 4000, hysteresisCentiC: 300),
                    busy: false, onApply: { _ in })),
            ]
            for (stateName, section) in thermalSections {
                cases.append(SnapshotCase(
                    name: "ThermalSection_\(stateName)_\(style.rawValue)_\(scheme == .dark ? "dark" : "light")",
                    width: 304, height: nil, style: style, scheme: scheme
                ) {
                    AnyView(wrap(style, scheme) {
                        section.frame(width: 304, alignment: .leading)
                    })
                })
            }
        }
    }
    return cases
}

// MARK: - 渲染（ImageRenderer，主线程 + RunLoop 泵等待）

/// 渲染并归一化（底色按被测态 colorScheme 合成——审查修复：dark 态系统语义
/// 白字/白图标合成到白底会整体不可见，native_dark 系 golden 曾接近全白且对比门
/// 不可检测该回归）。返回 nil = 渲染失败（打印原因）。
@MainActor
private func renderFlattened(_ testCase: SnapshotCase) -> CGImage? {
    let renderer = ImageRenderer(content: testCase.makeView())
    renderer.scale = 1
    renderer.proposedSize = ProposedViewSize(width: testCase.width, height: testCase.height)
    // headless 渲染等待：泵一次主 RunLoop，让 SwiftUI 的环境/布局任务在主队列
    // 收敛后再取 cgImage（ImageRenderer 本身同步，此步为收敛保险）。
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    guard let cgImage = renderer.cgImage else {
        FileHandle.standardError.write("渲染失败（cgImage nil）：\(testCase.name)\n".data(using: .utf8)!)
        return nil
    }
    return flattenToSRGB(cgImage, background: flattenBackground(for: testCase.scheme))
}

/// 归一化合成底色（按被测态 colorScheme 选择）：light → 白底；dark → 深灰底
/// #1E1E1E（不取纯黑——保留深色面板底/阴影的区分度）。diff 与落盘同走本函数，
/// 两系各自底色一致 → 对比判定不变式成立。
private func flattenBackground(for scheme: ColorScheme) -> CGColor {
    switch scheme {
    case .dark:
        return CGColor(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
    case .light:
        return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    @unknown default:
        return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    }
}

/// sRGB 底色合成去 alpha（硬事实 8 归一化：diff 与落盘同走本函数）。
private func flattenToSRGB(_ image: CGImage, background: CGColor) -> CGImage? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let width = image.width
    let height = image.height
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

// MARK: - PNG 读写

private func writePNG(_ image: CGImage, to url: URL) -> String? {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { return "CGImageDestination 创建失败：\(url.path)" }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        return "PNG 写入失败：\(url.path)"
    }
    return nil
}

/// golden 读取归一化（底色按被测态 colorScheme——golden 落盘时已按该底合成，
/// 加载回读保持同底，diff 不变式成立）。
private func loadPNG(_ url: URL, scheme: ColorScheme) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return flattenToSRGB(image, background: flattenBackground(for: scheme))
}

/// 位图像素缓冲（统一经 sRGB noneSkipLast 上下文，逐字节可比）。
private func pixelBuffer(_ image: CGImage) -> [UInt8]? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil,
              width: image.width,
              height: image.height,
              bitsPerComponent: 8,
              bytesPerRow: image.width * 4,
              space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ),
          let data = context.data else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4
    ))
}

// MARK: - 容差 diff（判定写死：尺寸差=fail；|Δ|>2=差异像素；占比>0.5%=fail）

private func compare(_ a: CGImage, _ b: CGImage) -> String? {
    guard a.width == b.width, a.height == b.height else {
        return "尺寸不同：\(a.width)×\(a.height) vs \(b.width)×\(b.height)"
    }
    guard let pixelsA = pixelBuffer(a), let pixelsB = pixelBuffer(b) else {
        return "像素缓冲读取失败"
    }
    let total = a.width * a.height
    var diffPixels = 0
    var index = 0
    while index < pixelsA.count {
        // noneSkipLast：末字节为无效 alpha 位，仅比 RGB 三通道。
        if abs(Int(pixelsA[index]) - Int(pixelsB[index])) > 2
            || abs(Int(pixelsA[index + 1]) - Int(pixelsB[index + 1])) > 2
            || abs(Int(pixelsA[index + 2]) - Int(pixelsB[index + 2])) > 2 {
            diffPixels += 1
        }
        index += 4
    }
    let ratio = Double(diffPixels) / Double(total)
    if ratio > 0.005 {
        return String(format: "差异像素 %d/%d（%.3f%% > 0.5%%）", diffPixels, total, ratio * 100)
    }
    return nil
}

// MARK: - 模式：重生成 / 对比

private func ensureGoldensDir() -> String? {
    do {
        try FileManager.default.createDirectory(at: goldensDir, withIntermediateDirectories: true)
        return nil
    } catch {
        return "golden 目录创建失败：\(error)"
    }
}

@MainActor
private func runSnapshot(regenerate: Bool) -> Int32 {
    if let error = ensureGoldensDir() {
        FileHandle.standardError.write(error.data(using: .utf8)!)
        return 1
    }
    let cases = buildCases()
    var failures: [String] = []
    var passed = 0
    for testCase in cases {
        let url = goldensDir.appendingPathComponent("\(testCase.name).png")
        guard let rendered = renderFlattened(testCase) else {
            failures.append("\(testCase.name)：渲染失败")
            continue
        }
        if regenerate {
            if let error = writePNG(rendered, to: url) {
                failures.append("\(testCase.name)：\(error)")
            } else {
                print("  ↻ \(testCase.name).png（\(rendered.width)×\(rendered.height)）")
                passed += 1
            }
            continue
        }
        guard let golden = loadPNG(url, scheme: testCase.scheme) else {
            failures.append("\(testCase.name)：golden 缺失或不可读（先跑 --snapshot --regen）")
            continue
        }
        if let reason = compare(rendered, golden) {
            failures.append("\(testCase.name)：\(reason)")
        } else {
            print("  ✓ \(testCase.name)")
            passed += 1
        }
    }
    let mode = regenerate ? "重生成" : "对比"
    print("快照\(mode)：\(passed)/\(cases.count) 通过")
    if !failures.isEmpty {
        print("失败清单：")
        for failure in failures {
            print("  ✗ \(failure)")
        }
        return 1
    }
    return 0
}

// MARK: - 模式：--l10n 门禁（评审 P1-6）

/// 枚举 catalog 全 key（JSON 解析 xcstrings）× {en, zh-Hans} 断言解析值 ≠ key
/// （经 CellarL10n/Bundle.module；缺译/空值即红）；另对全 key 跑一遍 s() 当前
/// 语言通路，验证门面端到端。
private func runL10nGate() -> Int32 {
    guard let data = try? Data(contentsOf: catalogURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = root["strings"] as? [String: Any] else {
        FileHandle.standardError.write("catalog 读取/解析失败：\(catalogURL.path)\n".data(using: .utf8)!)
        return 1
    }
    let keys = strings.keys.sorted()
    var failures: [String] = []
    for key in keys {
        for locale in ["en", "zh-Hans"] {
            let value = CellarL10n.value(forKey: key, localeIdentifier: locale)
            if value == key || value.isEmpty {
                failures.append("\(key) [\(locale)]：解析值 == key 或为空（缺译）")
            }
        }
        // s() 当前语言通路（门面主入口端到端：LocalizationValue → key 还原 →
        // lproj/原始 catalog 双形态查找）。
        let value = CellarL10n.s(String.LocalizationValue(key))
        if value == key || value.isEmpty {
            failures.append("\(key) [s() 通路]：解析值 == key 或为空")
        }
    }
    print("l10n 门：\(keys.count) key × (en, zh-Hans, s() 通路) 全查")
    if !failures.isEmpty {
        print("缺译清单：")
        for failure in failures {
            print("  ✗ \(failure)")
        }
        return 1
    }
    return 0
}

// MARK: - 入口（top-level 代码 = @MainActor，SE-0343）

let arguments = Set(CommandLine.arguments.dropFirst())
let regenerate = arguments.contains("--regen")
if arguments.contains("--l10n") {
    exit(runL10nGate())
}
exit(runSnapshot(regenerate: regenerate))
