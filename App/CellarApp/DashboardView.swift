import AppKit
import CellarCore
import CellarUI
import SwiftUI

/// 实时仪表板（Phase 5 v1.2 §3，App 层组装——数据源 = StatusController 双管线：
/// 1s 遥测快照 + daemonStatus 轮询）：头栏（页题/实时徽章/低电量 chip/状态徽章）
/// → 英雄区（功率流三角图 + 藏酒环）→ 四指标带 → 三卡片。
///
/// - 视觉态四态见 §3.1（0.19.4 §1：flowModel.kind 四态单一判据 + nodata 组合空态）；
/// - band 语义照 §3.1：daemonStatus 非 nil 且 mode ≠ "disabled" 才画
///   （外接断开仍显示：限充在位）；
/// - nodata：tiles/卡片数值全「—」、三角图 nodata 形态、gauge 数字「—」；
/// - 低电量 chip：onAppear 直查 + NSProcessInfoPowerStateDidChange 订阅（R1 P3）；
/// - 时间估算经 TimeEstimator（§3.6 纯函数）+ StatusController.estimateSamples。
struct DashboardView: View {
    @EnvironmentObject var statusController: StatusController
    @Environment(\.cellarTheme) var theme

    /// 低电量模式（onAppear 直查一次 + 电源态通知订阅刷新，防陈旧）。
    @State private var lowPowerMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                nativeLimitRegion
                hero
                tiles
                cards
            }
            .padding(24)
        }
        .onAppear {
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    // MARK: - 数据投影（snapshot ↔ daemonStatus 交汇）

    var snapshot: BatterySnapshot? {
        statusController.batterySnapshot
    }

    /// 流向判据（0.19.4 §1：PowerFlow 三态枚举删除，FlowDiagramKind 统一接管——
    /// flowModel 已在位（DashboardView+PowerFlowText），kind 直取；nodata → nil）。
    var flowState: FlowDiagramKind? {
        snapshot != nil ? flowModel.kind : nil
    }

    var isNodata: Bool { snapshot == nil }

    /// band 语义（§3.1）：daemon 可达且 mode != disabled → 限充区间弧。
    private var bandRange: ClosedRange<Int>? {
        guard let status = statusController.daemonStatus, status.mode != "disabled" else { return nil }
        return (status.upperLimit - status.hysteresis)...status.upperLimit
    }

    /// 电池侧实测功率 W（Voltage×Amperage/1e6——面板 PowerFlowView 同款口径）。
    var batteryPowerW: Double {
        guard let snapshot else { return 0 }
        return Double(snapshot.voltageMV) * Double(snapshot.amperageMA) / 1_000_000
    }

    var healthPercent: Int? {
        guard let snapshot else { return nil }
        return batteryHealthPercent(
            nominal: snapshot.nominalChargeCapacityMAh ?? snapshot.rawMaxCapacityMAh,
            design: snapshot.designCapacityMAh
        )
    }

    // MARK: - 头栏

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CellarL10n.s("main.page.dashboard"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            liveBadge
            Spacer()
            lowPowerChip
            stateChip
        }
    }

    /// 实时徽章（mock live：accent 点 + 「实时 · 1s 采样」胶囊）。
    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(theme.accent).frame(width: 6, height: 6)
            Text(CellarL10n.s("dashboard.live"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .background { if let pb = theme.panelBackground { pb } }
        .overlay(Capsule().strokeBorder(theme.secondaryText.opacity(0.45)))
    }

    private var lowPowerChip: some View {
        chip(CellarL10n.s(lowPowerMode ? "dashboard.lowPower.on" : "dashboard.lowPower.off"))
    }

    /// 状态徽章（§3.3：已停充·窖藏中 / 充电中·酒液入窖 / 电池供电·开窖出行；
    /// nodata → 「—」）。
    private var stateChip: some View {
        chip(stateChipText, emphasized: true)
    }

    private var stateChipText: String {
        switch flowState {
        case .charging: return theme.word(.dashboardStateCharging)
        case .holding: return theme.word(.dashboardStateHolding)
        // 0.19.4 §1.2：assist 补入态徽章词（旧 PowerFlow 三态下误显「充电中」）。
        case .assist: return theme.word(.dashboardStateAssist)
        case .battery: return theme.word(.dashboardStateBattery)
        case nil: return CellarL10n.s("common.nodata")
        }
    }

    private func chip(_ title: String, emphasized: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(emphasized ? theme.accent : theme.secondaryText)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background {
                // 状态徽章按 mock gstate 形态：accent 微底；普通 chip 无底
                // （零 Color 字面量的条件渲染路径）。
                if emphasized {
                    Capsule().fill(theme.accent.opacity(0.12))
                }
            }
            .overlay(
                Capsule().strokeBorder(emphasized ? theme.accent.opacity(0.35) : theme.secondaryText.opacity(0.45))
            )
    }

    // MARK: - 原生限充区（Phase 5 v1.7 M3 §4.1）

    /// 原生限充呈现区（冲突横幅 + 注记行，两者可并存；注记行不抢主状态——
    /// 状态徽章/停充语义零改动）。三态门控：nativeLimit 缺席（旧 daemon）→
    /// 区域整体隐藏；known=false（检测未知）→ 不渲染（fail-open 对齐）；
    /// known=true 才进入呈现判定（方案 §4.1 消费口径分工）。横幅在前（照
    /// PanelView AlertBanner 置顶先例——警示级先行，注记行随后）。
    @ViewBuilder
    private var nativeLimitRegion: some View {
        if let native = statusController.nativeLimitStatus, native.known {
            // 冲突横幅（口径 = manualSocLimit > L_c）：Cellar 执法在位（mode !=
            // disabled）才成立——停用态原生值本就生效，无冲突可言（照 doctor
            // 检查 15 的执法/未执法分支语义）。
            if let status = statusController.daemonStatus,
               status.mode != "disabled",
               let manual = native.manualSocLimit,
               manual > status.upperLimit {
                NativeLimitConflictBanner(
                    nativeSocLimit: manual,
                    cellarLimit: status.upperLimit,
                    onOpenSettings: Self.openBatterySettings
                )
            }
            // 注记行（口径 = manualSocLimit，仅手动策略；nil 不显示）。
            if native.active, let manual = native.manualSocLimit {
                NativeLimitNoteRow(socLimit: manual)
            }
        }
    }

    /// 深链「打开系统电池设置」（force unwrap 规避：锚构造失败 → 通用系统设置
    /// 锚降级；再失败不动作——不 crash 不静默崩溃面）。
    private static func openBatterySettings() {
        let url = URL(string: "x-apple.systemsettings:com.apple.settings.battery")
            ?? URL(string: "x-apple.systemsettings:")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 英雄区

    private var hero: some View {
        HStack(spacing: 14) {
            panel(title: CellarL10n.s("dashboard.panel.flow"),
                  // 副题随遥测：在场 → 实时遥测注记；缺席 → V×I 口径原键（旧机型仍准）。
                  subtitle: CellarL10n.s(snapshot?.telemetry != nil ? "dashboard.panel.flow.subtitle.live" : "dashboard.panel.flow.subtitle")) {
                PowerFlowDiagramView(
                    state: diagramState,
                    batteryPercent: snapshot?.percent,
                    batteryVoltage: batteryVoltageText,
                    adapterLine: adapterLineText,
                    systemLine: systemLineText,
                    powerAB: powerABText,
                    powerBS: powerBSText,
                    supplyLine: supplyLineText
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // 藏酒环面板（mock hero 列宽 1.45fr:1fr）。
            panel(title: theme.word(.dashboardGaugeTitle),
                  subtitle: bandRange.map {
                      CellarL10n.s("dashboard.panel.gauge.subtitle", $0.lowerBound, $0.upperBound)
                  }) {
                VStack(spacing: 10) {
                    GaugeView(state: gaugeState, size: .hero)
                        .frame(width: 196, height: 196)
                    stateBadge
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 面板卡（mock .panel：surface 底 + line 描边 + 圆角 18 + 小标题行）。
    private func panel(title: String, subtitle: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(theme.secondaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
    }

    /// 三角图视觉态（v0.19.3：映射 `flowModel.kind`——形态由实测功率符号裁决，
    /// assist 补入态新增；nodata 仍由 isNodata 前置判定）。
    private var diagramState: PowerDiagramState {
        guard !isNodata else { return .nodata }
        switch flowModel.kind {
        case .charging: return .charging
        case .holding: return .holding
        case .assist: return .assist
        case .battery: return .battery
        }
    }


    private var gaugeState: GaugeState {
        GaugeState(
            percent: snapshot?.percent,
            band: bandRange,
            // 0.19.4 §0-6：bolt 徽标改由 kind == .charging 驱动（与面板同一规则——
            // assist 态不亮 bolt；holding 态本就无 bolt，行为零变化）。
            isCharging: flowState == .charging,
            axLabel: gaugeAxLabel
        )
    }

    /// 藏酒环 AX 摘要（照面板 gaugeAxLabel 组装模式：电量 + band + 电源态词；
    /// 0.19.4 §1.2：电源态词由 flowModel kind 选词，assist 追加 powerFlowAssist）。
    private var gaugeAxLabel: String {
        var parts: [String] = []
        if let percent = snapshot?.percent {
            parts.append(CellarL10n.s("panel.gaugeAx.percent", percent))
        } else {
            parts.append(CellarL10n.s("panel.gaugeAx.unavailable"))
        }
        if let band = bandRange {
            parts.append(CellarL10n.s("panel.gaugeAx.band",
                                      CellarL10n.s("vocabulary.native.limitLabel"), band.upperBound))
        }
        if let flowState {
            switch flowState {
            case .charging: parts.append(theme.word(.powerFlowCharging))
            case .holding: parts.append(theme.word(.powerFlowFloating))
            case .assist: parts.append(theme.word(.powerFlowAssist))
            case .battery: parts.append(theme.word(.powerFlowOnBattery))
            }
        }
        return parts.joined(separator: CellarL10n.s("common.joinSeparator"))
    }

    /// 藏酒环下状态徽章（mock gstate 胶囊；nodata → 「—」）。
    private var stateBadge: some View {
        Text(stateChipText)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.vertical, 3)
            .padding(.horizontal, 12)
            .background(Capsule().fill(theme.accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35)))
    }

    // MARK: - 四指标带

    private var tiles: some View {
        HStack(spacing: 14) {
            tile(title: theme.word(.dashboardTileTemp),
                 value: tempValue,
                 unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.celsius"),
                 subtitle: CellarL10n.s("dashboard.tile.temp.sub"))
            tile(title: timeTileTitle,
                 value: timeValue.value, unit: timeValue.unit,
                 subtitle: timeTileSubtitle)
            tile(title: CellarL10n.s("dashboard.tile.health"),
                 value: healthPercent.map(String.init) ?? CellarL10n.s("common.nodata"),
                 unit: healthPercent == nil ? nil : CellarL10n.s("dashboard.unit.percent"),
                 subtitle: CellarL10n.s("dashboard.tile.health.sub"))
            tile(title: CellarL10n.s("dashboard.tile.cycle"),
                 value: snapshot.map { "\($0.cycleCount)" } ?? CellarL10n.s("common.nodata"),
                 unit: snapshot == nil ? nil : CellarL10n.s("dashboard.unit.count"),
                 subtitle: CellarL10n.s("dashboard.tile.cycle.sub"))
        }
    }

    private func tile(title: String, value: String, unit: String? = nil, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .tracking(1)
                .foregroundStyle(theme.tertiaryText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    // v1.9 D-B4：tile 主数字面 design 随 token（时间估算等四 tile
                    // 共用本读出面；A/B nil 落回 .default 零扰动；caption/副词级
                    // 标签行不接——宁缺勿滥）。
                    .font(.system(size: 22, weight: .semibold, design: theme.numericFontDesign ?? .default))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.top, 4)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.secondaryText.opacity(0.25)))
    }
}
