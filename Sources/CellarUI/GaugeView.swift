import SwiftUI

// MARK: - 仪表显示上下文（WP4 规格 §2.3，面板层拼装；WP4 自 App target 下沉）

/// 仪表输入为面板层组装的显示上下文（纯数值，可预览可测）：
/// - `percent == nil`（遥测不可用/采样失败）→ 中心「--」+ 中性环（降级形态）
/// - `band == nil` → 隐藏区间弧段（未注册——策略真相在 daemon 拿不到；
///   mode == disabled——画 band 会误导「仍在限充」）
/// - `axLabel` 由面板层拼装（「当前电量 85%，充电上限 80%，已停充」语义）
public struct GaugeState {
    public var percent: Int?
    public var band: ClosedRange<Int>?
    public var isCharging: Bool
    public var axLabel: String

    public init(percent: Int?, band: ClosedRange<Int>?, isCharging: Bool, axLabel: String) {
        self.percent = percent
        self.band = band
        self.isCharging = isCharging
        self.axLabel = axLabel
    }
}

/// 仪表尺寸语义（Phase 5 v1.2 §3.3）：regular = 面板 150×150（默认——既有
/// 快照 20 张路径字节不变）；hero = 仪表板 196×196（中心数字 56pt + TARGET 副词行）。
public enum GaugeSize: Equatable, Sendable {
    case regular
    case hero
}

/// 签名组件（产品视觉锚点）：底环 + band 弧 + 电量弧（充电中叠加 bolt 徽标）+
/// 中心数字（monospacedDigit 动态字体）。轻量 trim 重绘，数值插值动画 ≤0.3s
/// linear（无常驻 spring）；accessibilityElement(children: .ignore) 聚合单元素。
/// Phase 5 v1.2 §3.3：`size` 参数化（.regular = 面板 150 语义，默认路径渲染
/// 字节不变——20 张既有 golden 零 regen 的机械保证；.hero = 仪表板 196 语义：
/// 中心数字加大 + TARGET 副词行）。
public struct GaugeView: View {
    public let state: GaugeState
    public let size: GaugeSize
    @Environment(\.cellarTheme) private var theme

    private static let lineWidth: CGFloat = 14

    public init(state: GaugeState, size: GaugeSize = .regular) {
        self.state = state
        self.size = size
    }

    public var body: some View {
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
                    // 光晕随 token（WP3 §3.2；demo 事实：仅当前进度弧有 drop-shadow，
                    // band 弧与底环无）。native 哑值（透明 + radius 0）消解为零视觉
                    // 变化；渐变不用于仪表弧（弧为单色 accent，渐变消费面仅外观 Tab）。
                    .shadow(color: theme.accentGlow.color, radius: theme.accentGlow.radius)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: state.percent)

                if state.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: proxy.size.width * 0.12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .offset(y: -ringRadius)
                }

                // 中心数字 + hero 副词行（M3.5 修复：mock 为纵向排布——数字上、
                // TARGET 下；旧实现同 ZStack 居中叠放，56pt 数字与 11pt TARGET
                // 行重叠）。VStack(spacing: 2) 整块居中；.regular 路径 VStack 单
                // 元素与原裸 Text 等价（20 张 golden 零 regen 的机械保证）。
                VStack(spacing: 2) {
                    Text(centerText)
                        .font(size == .hero
                            ? .system(size: 56, design: .rounded).weight(.semibold)
                            : .system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(state.percent == nil ? theme.secondaryText : theme.accent)
                        .contentTransition(.numericText())

                    // hero 副词行（§3.3：TARGET 限充区间）；regular 路径零变化。
                    if size == .hero, let band = state.band {
                        Text(CellarL10n.s("gauge.target", band.lowerBound, band.upperBound))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(theme.tertiaryText)
                            .tracking(1)
                    }
                }
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
