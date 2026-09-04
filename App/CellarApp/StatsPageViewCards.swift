import CellarCore
import CellarUI
import Charts
import SwiftUI

// 统计页「曲线卡」分区（Phase 5 v1.3 §3.1——StatsPageView 组装超 400 行，按分区
// 拆文件，DashboardViewCards 先例）：电量（分状态分色 + MIN/MAX 波动带）/ 窖温 /
// 功耗 / 最大容量趋势四卡 + 桶→点数据投影。查询与页面骨架在 StatsPageView.swift；
// 本文件仅消费 buckets/capacityPoints，无独立数据源。
//
// 断档留空（UD-5，评审 P1-1）：StatsBucketing 空桶跳过 → 点序列在断档处时间
// 不连续——投影层统一按 bucketSeconds（桶径）判 `start` 间距断组，四张曲线
// 跨断档一律断笔留空（Swift Charts 对同 series 相邻点无条件连线，不分段会把
// 睡眠断档画成一条直线跨过）。

extension StatsPageView {

    // MARK: - 电量卡（§3.1 曲线 1）

    /// 电量卡：波动带（成对 min/max 的 AreaMark，accent 10% 透明度）垫底 +
    /// 按充放状态分色的均值折线；Y 轴 0-100%。
    var batteryCard: some View {
        panel(title: CellarL10n.s("stats.chart.percent"),
              subtitle: CellarL10n.s("stats.chart.percent.subtitle")) {
            batteryChart
        }
    }

    private var batteryChart: some View {
        Chart {
            // 波动带先画（垫底）：每点一对 (yStart=min, yEnd=max) 的 AreaMark，
            // 相邻点由 Charts 连续成带；恒 accent 透明底（不随状态分色）；段即
            // 连续 run——断档处带同样断开。
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    AreaMark(
                        x: .value("time", point.date),
                        yStart: .value("min", point.min),
                        yEnd: .value("max", point.max)
                    )
                }
            }
            .foregroundStyle(theme.accent.opacity(0.10))
            // 折线按桶 chargingState 拆 series 分色（§3.0 预置：不用
            // foregroundStyle(by:)——全类别图例 + 过渡点着色怪癖）。
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("time", point.date),
                        y: .value("percent", point.avg)
                    )
                }
                .foregroundStyle(lineColor(for: segment.state))
            }
        }
        .chartYScale(domain: 0...100)
        .chartAxisTheme(theme)
        .chartYAxisLabel {
            Text(CellarL10n.s("stats.unit.percent"))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(height: 180)
    }

    // MARK: - 窖温卡（§3.1 曲线 2）

    var temperatureCard: some View {
        panel(title: CellarL10n.s("stats.chart.temp")) {
            Chart {
                lineSeries(temperatureRuns, yKey: "temp")
            }
            .foregroundStyle(theme.accent)
            .chartAxisTheme(theme)
            .chartYAxisLabel {
                Text(CellarL10n.s("stats.unit.celsius"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            .frame(height: 180)
        }
    }

    // MARK: - 功耗卡（§3.1 曲线 3）

    /// 功耗卡：折线含零轴（正=充电输入 / 负=放电输出，符号纪律 §2.1）——
    /// Charts 跨零域默认画出零轴线。
    var powerCard: some View {
        panel(title: CellarL10n.s("stats.chart.power"),
              subtitle: CellarL10n.s("stats.chart.power.subtitle")) {
            Chart {
                lineSeries(powerRuns, yKey: "power")
            }
            .foregroundStyle(theme.accent)
            .chartAxisTheme(theme)
            .chartYAxisLabel {
                Text(CellarL10n.s("stats.unit.watt"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            .frame(height: 180)
        }
    }

    // MARK: - 最大容量趋势卡

    /// 全保留窗小时桶趋势；≥2 点才显示（StatsPageView 门控）——容量变化以周
    /// 计，窄窗内是一条无信息平线，不如如实隐藏。慢变量但断档判据与三张曲线
    /// 求一致（整夜睡眠在 35 天窗内高频出现，跨连同样是断档造假）。
    var capacityCard: some View {
        panel(title: CellarL10n.s("stats.chart.capacity")) {
            Chart {
                lineSeries(capacityRuns, yKey: "capacity")
            }
            .foregroundStyle(theme.accent)
            .chartAxisTheme(theme)
            .chartYAxisLabel {
                Text(CellarL10n.s("stats.unit.percent"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            .frame(height: 180)
        }
    }

    // MARK: - 数据投影（StatsBucket → Charts 点/段；断档分段 UD-5）

    /// 连续 run 序列 → LineMark 组（每 run 独立 series 互不连线——断档断笔）。
    /// 三张单线卡同构 Chart 体收敛为单实现（嵌套 ChartContentBuilder 内联展开
    /// 会触发类型检查超时）。
    private func lineSeries(_ runs: [DataRun], yKey: String) -> some ChartContent {
        ForEach(runs) { run in
            ForEach(run.points) { point in
                LineMark(
                    x: .value("time", point.date),
                    y: .value(yKey, point.value)
                )
            }
        }
    }

    /// 单曲线数据点（桶 start 全局唯一可作 id）。
    private struct DataPoint: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// 连续 run（时间连续的一段折线；Charts 每 run 独立 series 互不连线）。
    private struct DataRun: Identifiable {
        let id: Int
        let points: [DataPoint]
    }

    /// 电量曲线数据点（均值折线 + MIN/MAX 波动带双轨）。
    private struct BatteryPoint: Identifiable {
        let date: Date
        let avg: Double
        let min: Double
        let max: Double
        var id: Date { date }
    }

    /// 电量曲线分段（同 chargingState 的相邻桶合并为一条 series）。
    private struct BatterySegment: Identifiable {
        let id: Int
        let state: StatsChargingState
        let points: [BatteryPoint]
    }

    /// 电量分段投影——**两判据独立**（评审 P1-1）：
    /// - 状态切换 = 共享边界点续笔（新段 prepend 前段末点，切换处折线相接）；
    /// - 时间断档（`start` 间距 > bucketSeconds，即中间至少跳过一个空桶）=
    ///   断笔重起（新段**不** prepend——跨空档连线即断档造假）。
    private var segments: [BatterySegment] {
        var raw: [(state: StatsChargingState, points: [BatteryPoint])] = []
        var previousStart: Date?
        for bucket in buckets {
            let point = BatteryPoint(
                date: bucket.start,
                avg: bucket.avgPercent,
                min: Double(bucket.minPercent),
                max: Double(bucket.maxPercent)
            )
            // 桶 start = range 下界 + index×bucketSeconds（整秒，Double 精确），
            // 相邻非空桶间距恰等于桶径，严格大于即有跳桶。
            let isGap = previousStart.map {
                bucket.start.timeIntervalSince($0) > Double(rangeWindow.bucketSeconds)
            } ?? false
            if let last = raw.indices.last, !isGap, raw[last].state == bucket.chargingState {
                raw[last].points.append(point)
            } else {
                var points: [BatteryPoint] = []
                if !isGap, let last = raw.indices.last, let lastPoint = raw[last].points.last {
                    points.append(lastPoint)   // 仅状态切换共享点续笔
                }
                points.append(point)
                raw.append((bucket.chargingState, points))
            }
            previousStart = bucket.start
        }
        return raw.enumerated().map {
            BatterySegment(id: $0.offset, state: $0.element.state, points: $0.element.points)
        }
    }

    private var temperaturePoints: [DataPoint] {
        buckets.map { DataPoint(date: $0.start, value: $0.avgTempCentiC / 100) }
    }

    private var powerPoints: [DataPoint] {
        buckets.map { DataPoint(date: $0.start, value: $0.avgPowerMW / 1000) }
    }

    /// 窖温/功耗：单 series 改连续 run 分组（与电量分段同技巧）。
    private var temperatureRuns: [DataRun] {
        continuousRuns(temperaturePoints, bucketSeconds: Double(rangeWindow.bucketSeconds))
    }

    private var powerRuns: [DataRun] {
        continuousRuns(powerPoints, bucketSeconds: Double(rangeWindow.bucketSeconds))
    }

    /// 容量趋势：概览查询小时桶（StatsPageView.overviewBucketSeconds）。
    private var capacityRuns: [DataRun] {
        continuousRuns(
            capacityPoints.map { DataPoint(date: $0.date, value: $0.percent) },
            bucketSeconds: Double(StatsPageView.overviewBucketSeconds)
        )
    }

    /// 连续 run 分组：`date` 超过前点 date + bucketSeconds 即断 run（每 run 至
    /// 少 1 点；单点 run 无线可画，如实空白——不造点）。
    private func continuousRuns(_ points: [DataPoint], bucketSeconds: TimeInterval) -> [DataRun] {
        var runs: [[DataPoint]] = []
        for point in points {
            if let lastRun = runs.last, let lastPoint = lastRun.last,
               point.date.timeIntervalSince(lastPoint.date) <= bucketSeconds {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs.enumerated().map { DataRun(id: $0.offset, points: $0.element) }
    }

    /// 三色语汇（照功率流：充电 accent / 停充 holding 色 / 放电 warn）。
    private func lineColor(for state: StatsChargingState) -> Color {
        switch state {
        case .charging: return theme.accent
        case .holding: return theme.holding
        case .discharging: return theme.warning
        }
    }
}

// MARK: - 图表坐标轴主题（token 化）

/// 四张曲线卡共用坐标轴主题：网格/刻度字全走 theme token（G2——琥珀风格下
/// 不泄漏 Charts 系统默认前景色；native 语义色自动深浅合规）。ViewModifier
/// 形态：chartXAxis/chartYAxis 必须修饰 Chart 本体，不能收进页面实例方法。
private struct StatsChartAxisTheme: ViewModifier {
    let theme: CellarTheme

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisValueLabel().foregroundStyle(theme.tertiaryText)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(theme.secondaryText.opacity(0.15))
                    AxisValueLabel().foregroundStyle(theme.tertiaryText)
                }
            }
    }
}

private extension View {
    func chartAxisTheme(_ theme: CellarTheme) -> some View {
        modifier(StatsChartAxisTheme(theme: theme))
    }
}
