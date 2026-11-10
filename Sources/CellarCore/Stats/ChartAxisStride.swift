import Foundation

/// 容量卡/趋势卡横轴步长分档（0.23.4 方案 A；0.23.17 §2.3.6 大跨度扩档）：
/// 固定日历步长 × 增长域。Charts 对显式 stride 自定义轴标签不做空间取舍
/// （0.18.1 R-5 假设证伪），标签数必须由步长分档钉在绘图区容量（~15）内。
/// 域 = 数据首尾跨度（Charts domain = 数据极值），分档输入即该跨度天数；
/// 标签数模型 = floor(跨度/步长)+1（现档自证：12 天@1=13、35@5=8、99@7=15）。
/// 分档逐档核算（≤15）：≤12→1 天（13）；13-24→2 天（13）；25-59→5 天（13）；
/// ≥60→7 天（99@7=15）；≥100→14 天（179@14=13——补中段洞：105-179 天 @7 步
/// 会溢出到 16-26 标签）；≥180→30 天（365@30=13）。既有 <60 天档不动。显式
/// stride 保持确定性（不用 .automatic——0.18 曾在短域上 label 消失，翻案需
/// 重新实证，不冒险）。
///
/// 0.23.18 地平线登记（评审 P1 修正二轮补洞配套）：30 天步档在跨度 ≥421 天起
/// 进入 15 标签满载区（floor 模型 450 天起 =16 实溢绘图区容量）——届时加
/// ≥420→60 天步（floor(800/60)+1=14 ✓）并把 CellarCoreCheck 统计域扫描域
/// 扩 1-800。
public enum ChartAxisStride {
    public static func capacity(dataSpanDays: Int) -> (component: Calendar.Component, count: Int) {
        switch dataSpanDays {
        case ..<13: return (.day, 1)
        case 13...24: return (.day, 2)
        case 25...59: return (.day, 5)
        case 60...99: return (.day, 7)
        case 100...179: return (.day, 14)
        default: return (.day, 30)   // ≥180（daily_health 永不 prune = 趋势卡跨度无上界）
        }
    }
}
