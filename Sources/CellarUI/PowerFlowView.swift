import AppKit
import CellarCore
import SwiftUI

// MARK: - 功率流向可视化（WP2' §4.2；下沉 CellarUI，组件层零风格分支词元——G1；
// 0.19.4 §1：PowerFlow 三态枚举删除，FlowDiagramKind 统一接管全 App 流向判据）

/// 功率流向图 `[插头] → [Mac] ← [电池]`：骨架恒定、箭头方向随功率流翻转
/// （充电流 Mac→电池右向 / 电池供电·补入 电池→Mac 左向），活跃路径 accent 高亮 +
/// 短标签（语汇词条 powerFlow.* ×2 风格，en 译文随 WP2' catalog 先行）。
///
/// - 输入可选（kind 缺席 → nil 不渲染——作为 GaugeView 与 StatusLineView 之间的
///   独立行存在，缺席时布局零占用）；
/// - 0.19.4 §1.1：形态判据 = `FlowDiagramKind`（flowDiagramModel 实测符号裁决，
///   含 assist 补入态）；旧 `PowerFlow` 三态真值表（isCharging 策略位派生）删除——
///   floating≡holding、onBattery≡battery，合流无信息损失；
/// - 功率数字同源（0.19.4 §1.3）：入参 batteryEdgeW 直取 flowDiagramModel 输出
///   （遥测裁决时 = 遥测 |BP|/1000，与三角图边标签同源；② 回退 = |V×I|）——
///   阈值/nil 语义已在模型层收敛，组件零判定；
/// - SF Symbol 运行时存在性检查 + 回退链（MenuBarIconLabel 同款模式——
///   powerplug.slash 缺失事故证明候选表本身需要兜底）。
public struct PowerFlowView: View {
    /// 流向形态（nil → 不渲染，照现状 nil 语义）。
    public let kind: FlowDiagramKind?
    /// 模型层已收敛的电池边功率 W（含 0.05 显示阈值；holding → nil）。
    public let batteryEdgeW: Double?
    /// Phase 5 v1.1：daemon 风扇状态（nil = 不渲染风扇行；仅 enabled ∧ boost/
    /// hold 时显示——off 完全隐形，方案 §7 面板行）。
    public let fanStatus: FanStatus?
    @Environment(\.cellarTheme) private var theme

    public init(
        kind: FlowDiagramKind?, batteryEdgeW: Double? = nil,
        fanStatus: FanStatus? = nil
    ) {
        self.kind = kind
        self.batteryEdgeW = batteryEdgeW
        self.fanStatus = fanStatus
    }

    public var body: some View {
        if let kind {
            HStack(spacing: 6) {
                symbol(name: "powerplug", fallback: "circle.dashed")
                // 插头供电路径恒指向 Mac（右向）；电池供电态插头路径熄灭。
                arrow(active: kind != .battery, symbol: "arrow.right")
                symbol(name: "laptopcomputer", fallback: "desktopcomputer")
                // 电池路径：方向只在有流动时呈现——charging 充电流入电池（右向）、
                // battery/assist 电池→Mac（左向）、**holding 停充无流动 → 中性 minus**
                // （真机验收修正 2026-09-02：停充态画右向灰箭头被读成「在往电池
                // 充」，与已停充语义矛盾）。assist 左向箭头取 warning 色
                // （0.19.4 §1.2——放电补差语义与充电流入/常规放电区分）。
                batteryArrow(for: kind)
                symbol(name: "battery.100", fallback: "battery.75")
                Text(word(for: kind))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
                if let powerText = powerText(for: kind) {
                    Text(powerText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.accent)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel(for: kind))
            // Phase 5 v1.1 风扇行：boost/hold（介入中）呈现；off/静息完全隐形——
            // 与功率流向行同宽布局（窄行：符号 + 状态词 + 目标 rpm）。
            if let fan = fanStatus, fan.enabled,
               fan.state == .boost || fan.state == .hold {
                HStack(spacing: 6) {
                    Image(systemName: fanSymbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(fan.state == .boost ? theme.accent : theme.secondaryText)
                    Text(fanPanelWord(fan))
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
                .accessibilityElement(children: .ignore)
            }
        }
    }

    /// 风扇行符号（运行时存在性兜底：SF Symbol 候选表在 macOS 26 上不可靠）。
    private var fanSymbol: String {
        NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil) != nil
            ? "fan.fill" : "fan"
    }

    /// 风扇行文案（boost → 「加速 →N rpm」；hold → 「保持」——公开文案零品牌词）。
    private func fanPanelWord(_ fan: FanStatus) -> String {
        switch fan.state {
        case .boost:
            if let target = fan.targetRPM {
                return CellarL10n.s("fan.panel.boost", "\(Int(target.rounded()))")
            }
            return CellarL10n.s("fan.panel.boost", "?")
        case .hold:
            return CellarL10n.s("fan.panel.hold")
        default:
            return ""
        }
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

    /// 电池路径箭头（0.19.4 四态）：charging 右向活跃 / battery 左向活跃 /
    /// assist 左向活跃（warning 色——补入语义警示区分）/ holding 中性 minus 熄灭。
    @ViewBuilder
    private func batteryArrow(for kind: FlowDiagramKind) -> some View {
        switch kind {
        case .charging:
            arrow(active: true, symbol: "arrow.right")
        case .battery:
            arrow(active: true, symbol: "arrow.left")
        case .assist:
            arrow(active: true, symbol: "arrow.left", activeColor: theme.warning)
        case .holding:
            arrow(active: false, symbol: "minus")
        }
    }

    /// 路径箭头：活跃 → accent 高亮（activeColor 覆盖——assist 放电补差传 warning）；
    /// 非活跃 → 降档灰（token 消费，无任何风格分支）。
    private func arrow(active: Bool, symbol: String, activeColor: Color? = nil) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? (activeColor ?? theme.accent) : theme.secondaryText.opacity(0.35))
    }

    private func word(for kind: FlowDiagramKind) -> String {
        switch kind {
        case .charging: return theme.word(.powerFlowCharging)
        case .holding: return theme.word(.powerFlowFloating)
        case .assist: return theme.word(.powerFlowAssist)
        case .battery: return theme.word(.powerFlowOnBattery)
        }
    }

    /// 功率数字（0.19.4 §1.3 同源决策：batteryEdgeW 已由模型层收敛阈值/nil——
    /// 组件零判定，holding 恒 nil 不显示；充电 +N W / 放电向 −N W，%+.0f 格式沿用）。
    private func powerText(for kind: FlowDiagramKind) -> String? {
        guard let batteryEdgeW else { return nil }
        let watts = abs(batteryEdgeW)
        return String(format: "%+.0f W", kind == .charging ? watts : -watts)
    }

    private func axLabel(for kind: FlowDiagramKind) -> String {
        switch kind {
        case .charging: return CellarL10n.s("powerflow.axCharging")
        case .holding: return CellarL10n.s("powerflow.axFloating")
        case .assist: return CellarL10n.s("powerflow.axAssist")
        case .battery: return CellarL10n.s("powerflow.axOnBattery")
        }
    }
}
