import Foundation

/// 容量卡横轴步长分档（0.23.4 方案 A）：固定 1 天步长 × 增长域（35d 保留窗）
/// = 标签数随数据线性增长（0.23.4 走查实证 33 标签重叠）——Charts 对显式
/// stride 自定义轴标签不做空间取舍（0.18.1 R-5 假设证伪），标签数必须由
/// 步长分档钉在绘图区容量（~15）内。域 = 数据首尾跨度（Charts domain = 数据
/// 极值），分档输入即该跨度天数：
/// - ≤12 天 → 1 天（最多 13 标签）；13-24 天 → 2 天（最多 13）；≥25 天 →
///   5 天（35d 满窗最多 8）。显式 stride 保持确定性（不用 .automatic——0.18
///   曾在短域上 label 消失，翻案需重新实证，不冒险）。
public enum ChartAxisStride {
    public static func capacity(dataSpanDays: Int) -> (component: Calendar.Component, count: Int) {
        switch dataSpanDays {
        case ..<13: return (.day, 1)
        case 13...24: return (.day, 2)
        default: return (.day, 5)
        }
    }
}
