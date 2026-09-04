import CellarCore
import CellarUI
import SwiftUI

/// 实时仪表板（Phase 5 v1.2 §3，App 层组装——数据源 = StatusController 双管线：
/// 1s 遥测快照 + daemonStatus 轮询）：头栏（页题/实时徽章/低电量 chip/状态徽章）
/// → 英雄区（功率流三角图 + 藏酒环）→ 四指标带 → 三卡片。
///
/// - 视觉态四态见 §3.1（PowerFlow.flow 三态映射复用 + nodata 组合空态）；
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

    /// 三态映射复用 PowerFlowView.flow（(ext, charging) 二元判定单一实现——含异常
    /// 过渡态结论）。
    var flowState: PowerFlow? {
        snapshot.flatMap {
            PowerFlowView.flow(externalConnected: $0.externalConnected, isCharging: $0.isCharging)
        }
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
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
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
        case .floating: return theme.word(.dashboardStateHolding)
        case .onBattery: return theme.word(.dashboardStateBattery)
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

    // MARK: - 英雄区

    private var hero: some View {
        HStack(spacing: 14) {
            panel(title: CellarL10n.s("dashboard.panel.flow"),
                  subtitle: CellarL10n.s("dashboard.panel.flow.subtitle")) {
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

    private var diagramState: PowerDiagramState {
        guard !isNodata else { return .nodata }
        switch flowState {
        case .charging: return .charging
        case .floating: return .holding
        case .onBattery: return .battery
        case nil: return .nodata
        }
    }

    // ---- 三角图数据行（诚实纪律 §3.1：功率数字只给电池侧实测口径）----

    private var batteryVoltageText: String {
        guard let snapshot else { return CellarL10n.s("common.nodata") }
        return String(format: "%.1f V", Double(snapshot.voltageMV) / 1000)
    }

    /// 适配器副行：在位（额定 W）/ 未接入 / nodata「—」。
    private var adapterLineText: String {
        guard !isNodata else { return CellarL10n.s("common.nodata") }
        if let watts = snapshot?.adapter?.watts {
            return CellarL10n.s("dashboard.adapter.line.present", watts)
        }
        return CellarL10n.s("dashboard.adapter.line.absent")
    }

    /// 系统副行：电池态显实测负载（电池是唯一电源，V×A = 系统功耗）；充电/停充
    /// 态系统负载无公开数据源（适配器输出不可测）——诚实纪律不造数，显「—」
    /// （mock 的 18.2 W 为演示造数不落地）。
    private var systemLineText: String {
        guard !isNodata else { return CellarL10n.s("common.nodata") }
        if snapshot?.externalConnected == false {
            return CellarL10n.s("dashboard.sysLine.load", abs(batteryPowerW))
        }
        return CellarL10n.s("common.nodata")
    }

    private var powerABText: String? {
        guard flowState == .charging, abs(batteryPowerW) >= 0.05 else { return nil }
        return CellarL10n.s("dashboard.flow.powerIn", abs(batteryPowerW))
    }

    private var powerBSText: String? {
        guard flowState == .onBattery, abs(batteryPowerW) >= 0.05 else { return nil }
        // 负值经格式串显「−」方向（组件 color 由放电边 warn 承载）。
        return CellarL10n.s("dashboard.flow.powerOut", -abs(batteryPowerW))
    }

    private var supplyLineText: String? {
        guard snapshot?.externalConnected == true else { return nil }
        return CellarL10n.s("dashboard.supply")
    }

    private var gaugeState: GaugeState {
        GaugeState(
            percent: snapshot?.percent,
            band: bandRange,
            isCharging: snapshot?.isCharging ?? false,
            axLabel: gaugeAxLabel
        )
    }

    /// 藏酒环 AX 摘要（照面板 gaugeAxLabel 组装模式：电量 + band + 电源态词）。
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
            case .floating: parts.append(theme.word(.powerFlowFloating))
            case .onBattery: parts.append(theme.word(.powerFlowOnBattery))
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
                    .font(.system(size: 22, weight: .semibold))
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
