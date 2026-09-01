import SwiftUI

// MARK: - 仪表显示上下文（WP4 规格 §2.3，面板层拼装）

/// 仪表输入为面板层组装的显示上下文（纯数值，可预览可测）：
/// - `percent == nil`（遥测不可用/采样失败）→ 中心「--」+ 中性环（降级形态）
/// - `band == nil` → 隐藏区间弧段（未注册——策略真相在 daemon 拿不到；
///   mode == disabled——画 band 会误导「仍在限充」）
/// - `axLabel` 由面板层拼装（「当前电量 85%，充电上限 80%，已停充」语义）
struct GaugeState {
    var percent: Int?
    var band: ClosedRange<Int>?
    var isCharging: Bool
    var axLabel: String
}

/// 签名组件（产品视觉锚点）：底环 + band 弧 + 电量弧（充电中叠加 bolt 徽标）+
/// 中心数字（monospacedDigit 动态字体）。轻量 trim 重绘，数值插值动画 ≤0.3s
/// linear（无常驻 spring）；accessibilityElement(children: .ignore) 聚合单元素。
struct GaugeView: View {
    let state: GaugeState
    @Environment(\.cellarTheme) private var theme

    private static let lineWidth: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            // 环心半径 = 半宽 - 半线宽（bolt 徽标贴环顶、随尺寸缩放）。
            let ringRadius = proxy.size.width / 2 - Self.lineWidth / 2
            ZStack {
                Circle()
                    .stroke(theme.track, lineWidth: Self.lineWidth)

                if let band = state.band {
                    Circle()
                        .trim(from: Double(band.lowerBound) / 100, to: Double(band.upperBound) / 100)
                        .stroke(theme.band, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                Circle()
                    .trim(from: 0, to: arcFraction)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: state.percent)

                if state.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: proxy.size.width * 0.12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .offset(y: -ringRadius)
                }

                Text(centerText)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(state.percent == nil ? theme.secondaryText : theme.accent)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.axLabel)
    }

    /// 电量弧占比；nil（遥测不可用）→ 0（中性环降级）。
    private var arcFraction: Double {
        guard let percent = state.percent else { return 0 }
        return min(max(Double(percent) / 100, 0), 1)
    }

    private var centerText: String {
        state.percent.map { "\($0)" } ?? "--"
    }
}