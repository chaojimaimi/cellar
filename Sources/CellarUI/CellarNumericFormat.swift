import Foundation

// MARK: - 数值格式通路（0.23.15 B7-3 字面量/单位统一）
//
// 手拼 "%" / LocalizedStringKey 数字插值的单一收敛出口（方案 §2.3-4/5：数值部分
// formatter——千分位/小数点随 locale，标签部分 l10n key）。缓存实例照
// DashboardViewCards.groupedFormatter 先例：消费点全在 View body（MainActor）
// ——@MainActor 隔离；NumberFormatter 非 Sendable，static let 裸存不过 Swift 6
// 严格并发检查。percent 通路：入参为「已是 0-100 的百分数值」（全库既有语义），
// formatter .percent 语义为 0-1 → 入参 /100 归一，en 输出 "80%" 与原手拼逐字节
// 一致（golden 零漂移锚；其他 locale 千分位/空白随系统——有意收敛）。

@MainActor
public enum CellarNumericFormat {
    /// 百分数 formatter（.percent 内部 ×100——入参 /100 归一）。
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        return formatter
    }()

    /// 千分位分组整数 formatter（rpm——保留「1,344」locale 分组语义，原
    /// LocalizedStringKey 插值通路的 formatter 等价替换）。
    private static let groupedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// 百分数词（80 → "80%"）。string(from:) 失败回退手拼——不可达安全网
    ///（groupedFormatter 先例同形，仅防 formatter 异常）。
    public static func percent(_ value: Int) -> String {
        percentFormatter.string(from: NSNumber(value: Double(value) / 100)) ?? "\(value)%"
    }

    /// 分组整数词（1344 → "1,344"；en/zh 同形，其他 locale 随系统）。
    public static func grouped(_ value: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
