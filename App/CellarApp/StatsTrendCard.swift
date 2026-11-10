import CellarCore
import CellarUI
import Charts
import SwiftUI

// 健康趋势卡分区（0.23.17 §2.4——独立文件：StatsPageViewCards.swift 随本卡加入
// 达 800 行硬上限，按分区拆文件 DashboardViewCards 先例；statsPanel 容器随之
// private→internal 跨文件消费）。数据面：StatsPageView 页级 refresh 经
// statsSampler 环境透传 dailyHealthRows（actor 透传，主线程零 SQLite 红线）；
// 本文件仅消费，聚合核（weeklyBands/presentationState/cycleProjection）全在
// CellarCore 纯函数——卡侧零聚合零魔法数（门槛常量单源 StatsTrend）。

/// 健康趋势卡（0.23.17 §2.4）：daily_health 每日行的周桶聚合呈现——三态门槛
/// （StatsTrend.presentationState，§2.3.4 常量单源）：.insufficient 卡不渲染
/// （StatsPageView 门控）；.band = 周中位数折线 + min/max 半透明带（AreaMark，
/// 电量卡波动带先例形态）+「趋势积累中（N/90 天）」提示；.numeric = band 全部
/// 内容 + cycle 外推句（速率与月数各 1 位小数——评审 P3 修正；monthsToThreshold
/// nil → 退化句「循环数已达阈值」；速率 ≤ 0 无句如实不外推）。X 轴复用
/// ChartAxisStride 扩档（0.23.17 §2.3.6，输入周桶跨度天数）；hover 复用
/// statsChartHover（桶径 = 7 天秒数——周桶点，命中阈值=半桶径语义自动成立）；
/// a11y 整卡合并 + 摘要值（B7 先例形态）。周桶聚合核在 CellarCore 纯函数
///（weeklyBands）——卡侧只做展示投影。
struct StatsTrendCard: View {
    let theme: CellarTheme
    let dailyRows: [DailyHealthRow]
    @State private var hover: StatsHoverPoint?

    var body: some View {
        statsPanel(theme: theme, title: CellarL10n.s("stats.trend.title"),
                   subtitle: CellarL10n.s("stats.trend.subtitle")) {
            trendChart
            VStack(alignment: .leading, spacing: 3) {
                Text(CellarL10n.s("stats.trend.chart.median")
                     + " · " + CellarL10n.s("stats.trend.chart.band"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
                if let days = daysOfData {
                    Text(CellarL10n.s("stats.trend.band.hint", days))
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
                if let cycleText = cycleLineText {
                    Text(cycleText)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        // B7-1 a11y：图表数值仅 hover 可达——整卡合并单元素 + 摘要值（元数据零像素）。
        .accessibilityElement(children: .combine)
        .accessibilityValue(a11ySummary)
    }

    /// a11y 值（B7 先例形态）：标题词 + 跨日数 + 最新周中位数；无数据 → common.nodata。
    private var a11ySummary: String {
        guard let point = trendPoints.last, let days = daysOfData else {
            return CellarL10n.s("common.nodata")
        }
        return CellarL10n.s("stats.trend.a11y.summary", days, point.median)
    }

    // MARK: 数据投影（卡私有）

    /// 周桶带（CellarCore 纯函数直出——窗满才出 + 空窗跳过语义在聚合侧）。
    private var bands: [WeeklyBand] {
        StatsTrend.weeklyBands(daily: dailyRows)
    }

    /// 跨日数（「N/90 天」提示 + a11y 摘要共用；门槛常量 numericMinDays 单源在
    /// l10n 文案侧对齐——90 与 StatsTrend.numericMinDays 同值）。
    private var daysOfData: Int? {
        guard let firstDay = dailyRows.first?.day else { return nil }
        return StatsTrend.crossDayCount(
            firstDay: firstDay, today: DailyHealthRollup.dayString(for: Date())
        )
    }

    /// 三态（numeric 态才渲染 cycle 外推句）。
    private var presentation: TrendPresentation {
        guard let days = daysOfData else { return .insufficient }
        return StatsTrend.presentationState(
            daysOfData: days, weeklyBucketCount: bands.count
        )
    }

    /// 图表点（带 → 厘百分点 / 100 展示口径；X = 窗锚本地午夜）。
    private struct TrendPoint: Identifiable {
        let startDay: String
        let date: Date
        let median: Double
        let min: Double
        let max: Double
        var id: Date { date }
    }

    private var trendPoints: [TrendPoint] {
        bands.compactMap { band in
            guard let date = StatsTrend.localMidnight(forDay: band.startDay) else { return nil }
            return TrendPoint(
                startDay: band.startDay, date: date,
                median: band.median / 100,
                min: Double(band.min) / 100, max: Double(band.max) / 100
            )
        }
    }

    /// 连续段（跨空窗断笔——与四曲线卡断档如实语义一致）：相邻带 startDay 差
    /// 恰窗宽为连续，超过 = 中间有空窗（聚合侧已跳过），折线/带断开不跨连。
    private struct TrendRun: Identifiable {
        let id: Int
        let points: [TrendPoint]
    }

    private var trendRuns: [TrendRun] {
        var runs: [[TrendPoint]] = []
        for point in trendPoints {
            if let lastRun = runs.last, let lastPoint = lastRun.last,
               let gapDays = StatsTrend.crossDayCount(firstDay: lastPoint.startDay, today: point.startDay),
               gapDays <= StatsTrend.windowDays {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs.enumerated().map { TrendRun(id: $0.offset, points: $0.element) }
    }

    /// hover 投影（周桶点 + 带上下界）。
    private var trendHoverPoints: [StatsHoverPoint] {
        trendRuns.flatMap { run in
            run.points.map {
                StatsHoverPoint(date: $0.date, value: $0.median, min: $0.min, max: $0.max)
            }
        }
    }

    /// X 轴步长 = 周桶跨度分档（ChartAxisStride 扩档后复用——0.23.17 §2.3.6；
    /// ceil 保守方向同容量卡：跨度偏大 → 标签更稀，安全向）。
    private var trendAxisStride: (component: Calendar.Component, count: Int) {
        guard let first = bands.first, let last = bands.last,
              let span = StatsTrend.crossDayCount(firstDay: first.startDay, today: last.endDay)
        else { return (.day, 1) }
        return ChartAxisStride.capacity(dataSpanDays: max(1, span + 1))
    }

    private var trendChart: some View {
        Chart {
            // 波动带垫底（每带一对 min/max 的 AreaMark，accent 10% 透明底——
            // 电量卡先例形态；段即连续 run，断档处带断开）。
            ForEach(trendRuns) { run in
                ForEach(run.points) { point in
                    AreaMark(
                        x: .value("time", point.date),
                        yStart: .value("min", point.min),
                        yEnd: .value("max", point.max)
                    )
                }
            }
            .foregroundStyle(theme.accent.opacity(0.10))
            // 周中位数折线（单色 accent——周桶聚合已抹平充放语义，无分色面）。
            ForEach(trendRuns) { run in
                ForEach(run.points) { point in
                    LineMark(
                        x: .value("time", point.date),
                        y: .value("percent", point.median)
                    )
                }
            }
            .foregroundStyle(theme.accent)
            // hover 竖游标 + 值标签（nil = 无 hover；带日期格式——周桶点跨月）。
            if let hover {
                StatsChartHover.ruleMark(
                    for: hover, theme: theme,
                    value: StatsChartHoverFormat.healthPercent,
                    time: { $0.formatted(.dateTime.month().day()) }
                )
            }
        }
        .chartAxisTheme(theme, xStride: trendAxisStride.component,
                        xStrideCount: trendAxisStride.count)
        .chartYAxisLabel {
            Text(CellarL10n.s("stats.unit.percent"))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
        }
        // hover 手势：桶径 = 窗宽秒数（秒换算——86400 此处为时长单位换算，非日界
        // 派生；禁 86400 乘法纪律针对本地日界推导，StatsSampler/StatsStore 同注）。
        .statsChartHover(
            points: trendHoverPoints,
            bucketSeconds: Double(StatsTrend.windowDays) * 86_400,
            hover: $hover
        )
        .frame(height: 180)
    }

    /// cycle 外推句（numeric 态）：速率与月数各 1 位小数（评审 P3 修正）；
    /// monthsToThreshold nil → 退化句「循环数已达阈值」；速率 ≤ 0 → nil 无句
    /// 如实（不外推）。输入取 day ≤ 今天的行（store 读面已滤未来行）。
    private var cycleLineText: String? {
        guard presentation == .numeric,
              let first = dailyRows.first, let last = dailyRows.last,
              let projection = StatsTrend.cycleProjection(
                  first: first, last: last, threshold: StatsTrend.cycleThreshold
              )
        else { return nil }
        guard let months = projection.monthsToThreshold else {
            return CellarL10n.s("stats.trend.cycle.reached")
        }
        return CellarL10n.s("stats.trend.cycle.rate", projection.cyclesPerMonth)
            + CellarL10n.s("stats.trend.cycle.eta", months)
    }
}
