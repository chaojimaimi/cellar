import AppKit
import SwiftUI

// MARK: - 功率流向可视化（WP2' §4.2；下沉 CellarUI，组件层零风格分支词元——G1）

/// 功率流向三态（数据源 = App 侧 1s telemetry 快照，非 daemonStatus 30s 滞后字段）。
public enum PowerFlow: Equatable, Sendable {
    /// 外接 + 充电中（插头供电路径 + 充电流入电池，均右向活跃）。
    case charging
    /// 外接 + 停充漂浮（仅插头供电路径活跃；电池路径挂起）。
    case floating
    /// 电池供电（仅电池路径活跃且方向翻转：电池→Mac 左向；插头路径熄灭）。
    case onBattery
}

/// 功率流向图 `[插头] → [Mac] ← [电池]`：骨架恒定、箭头方向随功率流翻转
/// （充电流 Mac→电池右向 / 电池供电 电池→Mac 左向），活跃路径 accent 高亮 +
/// 短标签（语汇词条 powerFlow.* ×2 风格，en 译文随 WP2' catalog 先行）。
///
/// - 输入可选（快照缺席 → nil 不渲染——作为 GaugeView 与 StatusLineView 之间的
///   独立行存在，缺席时布局零占用）；
/// - 三态映射（评审 P2-7）：(true, true) → .charging / (true, false) → .floating /
///   (false, _) → .onBattery；「ext∧charging∧动作中」实测为异常过渡态，按
///   .charging 真实呈现，无第四态；
/// - SF Symbol 运行时存在性检查 + 回退链（MenuBarIconLabel 同款模式——
///   powerplug.slash 缺失事故证明候选表本身需要兜底）。
public struct PowerFlowView: View {
    public let externalConnected: Bool?
    public let isCharging: Bool?
    /// 电池侧实测功率 W（Voltage×Amperage/1e6，IOKit 实测值；适配器实际输出功率
    /// 无公开数据源——WP1.5 §7.5 标定结论）。nil/漂浮态（电池电流≈0，显示 0W 会
    /// 误导「系统未耗电」）不显示功率数字。
    public let batteryPowerW: Double?
    @Environment(\.cellarTheme) private var theme

    public init(externalConnected: Bool?, isCharging: Bool?, batteryPowerW: Double? = nil) {
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.batteryPowerW = batteryPowerW
    }

    public var body: some View {
        if let flow = Self.flow(externalConnected: externalConnected, isCharging: isCharging) {
            HStack(spacing: 6) {
                symbol(name: "powerplug", fallback: "circle.dashed")
                // 插头供电路径恒指向 Mac（右向）。
                arrow(active: flow == .charging || flow == .floating, symbol: "arrow.right")
                symbol(name: "laptopcomputer", fallback: "desktopcomputer")
                // 电池路径方向随功率流翻转：充电流 Mac→电池（右向）；电池供电
                // 电池→Mac（左向）——真机验收修正（2026-09-02：恒右向把放电画成
                // 「Mac 给电池充电」，用户目视报告）。
                arrow(active: flow == .charging || flow == .onBattery,
                      symbol: flow == .onBattery ? "arrow.left" : "arrow.right")
                symbol(name: "battery.100", fallback: "battery.75")
                Text(word(for: flow))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                if let powerText = powerText(for: flow) {
                    Text(powerText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.accent)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel(for: flow))
        }
    }

    /// 数据源三态映射（纯函数——快照缺席/字段缺席 → nil 不渲染）。
    public static func flow(externalConnected: Bool?, isCharging: Bool?) -> PowerFlow? {
        guard let externalConnected, let isCharging else { return nil }
        if externalConnected && isCharging { return .charging }
        if externalConnected { return .floating }
        return .onBattery
    }

    /// 运行时符号解析（主选 → 回退 → 首选兜底；macOS 26 候选表实测存在性不可靠）。
    private func resolvedSymbol(_ primary: String, fallback: String) -> String {
        if NSImage(systemSymbolName: primary, accessibilityDescription: nil) != nil {
            return primary
        }
        if NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil {
            return fallback
        }
        return primary
    }

    private func symbol(name: String, fallback: String) -> some View {
        Image(systemName: resolvedSymbol(name, fallback: fallback))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.secondaryText)
    }

    /// 路径箭头：活跃 → accent 高亮；非活跃 → 降档灰（token 消费，无任何风格分支）。
    private func arrow(active: Bool, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? theme.accent : theme.secondaryText.opacity(0.35))
    }

    private func word(for flow: PowerFlow) -> String {
        switch flow {
        case .charging: return theme.word(.powerFlowCharging)
        case .floating: return theme.word(.powerFlowFloating)
        case .onBattery: return theme.word(.powerFlowOnBattery)
        }
    }

    /// 功率数字（评审语境：用户要「当前实际功率」——可给的是电池侧实测 V×A；
    /// 漂浮态电池功率≈0 而系统实际由适配器直供，显示 0W 误导 → 不显示）。
    private func powerText(for flow: PowerFlow) -> String? {
        guard let batteryPowerW, flow != .floating else { return nil }
        // 充电显示入电池功率（+），放电显示出电池功率（−，取绝对值加方向由
        // 态标签承载）。
        let watts = flow == .charging ? batteryPowerW : abs(batteryPowerW)
        guard watts >= 0.05 else { return nil }   // 微瓦级抖动不显示
        return String(format: "%+.0f W", flow == .charging ? watts : -watts)
    }

    private func axLabel(for flow: PowerFlow) -> String {
        switch flow {
        case .charging: return "功率流向：充电中"
        case .floating: return "功率流向：外接已停充"
        case .onBattery: return "功率流向：电池供电"
        }
    }
}