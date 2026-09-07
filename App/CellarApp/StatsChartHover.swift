import CellarUI
import Charts
import SwiftUI

// 统计页曲线卡 hover 值提示（0.18 M2 T2 D-2a，独立新文件——四卡无共用 Chart 体、
// StatsPageViewCards 组装已近 400 行、DashboardView 恰 400 触顶，共用面落位于此）：
// - 统一 HoverPoint 投影（date/value/min?/max?——消波动带卡与单值卡结构差）；
// - chartOverlay 手势（onContinuousHover——macOS 悬停语义，无需按住拖动；工单
//   「实现期以实际可用手势为准」落定于此）+ 最近点查找（按 date 距离，命中阈值
//   = 桶径一半——连续数据区最近点必 ≤ 半桶径，断档区（≥2 桶跳空）必 > 半桶径
//   → 无提示，不造值）；
// - RuleMark 竖游标 + 值标签（时间 + 值 + 波动带上下界若有；annotation x 轴
//   fit——标签收敛于绘图区内，不外溢被裁）。
//
// App 层组件（StatsPageView 结构性不可快照——零 golden 面）。

/// hover 投影点（桶 start 全局唯一；min/max = 波动带上下界，单线卡 nil）。
struct StatsHoverPoint: Equatable {
    let date: Date
    let value: Double
    let min: Double?
    let max: Double?
}

/// hover 标签格式（各卡单位/时间粒度不同的单一实现集合；卡侧以函数引用注入）。
enum StatsChartHoverFormat {
    /// 电量/容量：整数百分比（均值折线 Y 口径）。
    static func percent(_ value: Double) -> String { String(format: "%.0f%%", value) }
    /// 健康度（容量趋势）：一位小数百分比（容量变化以 0.1% 计，整数会抹平趋势）。
    static func healthPercent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    /// 窖温：一位小数 °C（状态行温度段同口径）。
    static func celsius(_ value: Double) -> String { String(format: "%.1f °C", value) }
    /// 功耗：一位小数 W（状态行适配器段同口径）。
    static func watt(_ value: Double) -> String { String(format: "%.1f W", value) }
    /// 24h 窗时间标签：「HH:mm」。
    static func hourMinute(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }
    /// 7d/30d 窗时间标签：「M/d HH:mm」（跨天窗须带日期消歧义）。
    static func dayTime(_ date: Date) -> String { date.formatted(.dateTime.month().day().hour().minute()) }
}

/// 曲线卡 hover 组装（0.18 T2 D-2a）。
enum StatsChartHover {
    /// hover 竖游标 + 值标签：RuleMark 置于 Chart 内容内（游标随数据坐标系走，
    /// annotation 随 mark 定位——不经手像素坐标）；x 轴 fit 让标签收敛于绘图区
    /// 内（右缘不裁——「S...」同源的标签外溢问题在标签侧一并消除）。
    static func ruleMark(
        for point: StatsHoverPoint,
        theme: CellarTheme,
        value: @escaping (Double) -> String,
        time: @escaping (Date) -> String
    ) -> some ChartContent {
        RuleMark(x: .value("hover", point.date))
            .foregroundStyle(theme.secondaryText.opacity(0.35))
            .annotation(
                position: .top,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(time(point.date))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    Text(value(point.value))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                    if let min = point.min, let max = point.max {
                        Text("\(value(min)) – \(value(max))")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.secondaryText.opacity(0.45))
                )
            }
    }
}

/// hover 手势修饰器：chartOverlay 全区域命中（Color.clear + contentShape）+
/// onContinuousHover 跟随 → proxy.value(atX:) 反算 X 时刻 → 最近点查找 → 写
/// 卡侧游标态（驱动 Chart 内容内的 StatsChartHover.ruleMark）。
private struct StatsChartHoverOverlay: ViewModifier {
    let points: [StatsHoverPoint]
    /// 桶径（秒）——最近点命中阈值 = 其一半。
    let bucketSeconds: TimeInterval
    @Binding var hover: StatsHoverPoint?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hover = Self.nearestPoint(
                            toX: location.x, points: points,
                            bucketSeconds: bucketSeconds, proxy: proxy
                        )
                    case .ended:
                        hover = nil
                    }
                }
        }
    }

    /// 最近点查找（按 date 距离线性扫——每卡 ≤500 点，开销可忽略；命中阈值 =
    /// 桶径一半：连续数据区最近点必 ≤ 半桶径，断档区必 > 半桶径 → 无提示）。
    private static func nearestPoint(
        toX x: CGFloat,
        points: [StatsHoverPoint],
        bucketSeconds: TimeInterval,
        proxy: ChartProxy
    ) -> StatsHoverPoint? {
        guard let date = proxy.value(atX: x, as: Date.self) else { return nil }
        var nearest: StatsHoverPoint?
        var nearestDistance = TimeInterval.greatestFiniteMagnitude
        for point in points {
            let distance = abs(point.date.timeIntervalSince(date))
            if distance < nearestDistance {
                nearest = point
                nearestDistance = distance
            }
        }
        guard let nearest, nearestDistance <= bucketSeconds / 2 else { return nil }
        return nearest
    }
}

extension View {
    /// 曲线卡 hover 值提示（0.18 T2 D-2a 统一入口，四卡各一行接入）：游标态由
    /// 卡侧 @State 持有（各卡独立——共享会跨卡串显），Chart 内容内配
    /// StatsChartHover.ruleMark 消费。
    func statsChartHover(
        points: [StatsHoverPoint],
        bucketSeconds: TimeInterval,
        hover: Binding<StatsHoverPoint?>
    ) -> some View {
        modifier(StatsChartHoverOverlay(
            points: points, bucketSeconds: bucketSeconds, hover: hover
        ))
    }
}
