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
//
// 0.23.8 B3-2 hover 下沉：四卡自 StatsPageView extension 拆为四个卡 struct
//（internal——跨文件装配：StatsPageView body 消费，两文件同 App target，
// DashboardViewCards internal 同款先例；卡私有成员全部 private）——hover 态
//（@State）随卡，鼠标在图表上移动只重求值所在卡，页级零求值、其余卡零重算
//（原页级 @State 每帧触发五卡 + O(n) 投影全量重算）。各卡独立 hover 实例
// 保持「共享会跨卡串显」语义（原 StatsPageView :107-108 注记语义随迁）；
// 三单线卡共用投影（DataPoint/DataRun/continuousRuns/hoverPoints/lineSeries）
// 收敛文件级 fileprivate，卡私有投影随卡。能耗卡无 hover 留页级 extension
//（迁移零收益）；页级 panel 方法退役删除，布局收敛本文件 statsPanel 共享
// helper。

extension StatsPageView {

    // MARK: - 能耗卡（0.22.0 §3.2；0.23.8 B3-2 留页级——无 hover）

    /// 能耗卡门控（照容量卡「≥2 点才显示」数据积累如实先例）：查询窗内 ≥1 个
    /// 有效能量对（任一通道累计 > 0）才显示——无累加器键机型（26 未证实）全零
    /// 恒隐藏，26 红线零触及。有效对恒产正 mWh（Δacc ≥ 1 → K 加成 > 0），
    /// 桶值和 > 0 与「≥1 有效对」等价。
    var energyShowsCard: Bool {
        guard let energy else { return false }
        return energy.buckets.contains { $0.systemMWh > 0 || $0.dischargeMWh > 0 }
    }

    /// 趋势卡门控（0.23.17 §2.4）：三态 .insufficient 卡不渲染（决策点 1 锁定；
    /// 门槛常量单源 StatsTrend，禁散落魔法数），且需 ≥1 完整周带——缺席机型
    /// （nominal/design 恒缺席 → daily_health 全 NULL → 零带）不渲染空卡，
    /// R-6 不造数同款诚实语义。
    var trendShowsCard: Bool {
        trendState != .insufficient && !StatsTrend.weeklyBands(daily: dailyHealthRows).isEmpty
    }

    /// 趋势三态（§2.3.4 门槛 presentationState 单源；daysOfData = 跨日数口径，
    /// crossDayCount 派生——禁以日行数冒充，评审 P2 修正）。
    var trendState: TrendPresentation {
        guard let days = trendDaysOfData else { return .insufficient }
        return StatsTrend.presentationState(
            daysOfData: days,
            weeklyBucketCount: StatsTrend.weeklyBands(daily: dailyHealthRows).count
        )
    }

    /// 趋势跨日数（首日 → 今天的日历天数；nil = 无数据）。
    var trendDaysOfData: Int? {
        guard let firstDay = dailyHealthRows.first?.day else { return nil }
        return StatsTrend.crossDayCount(
            firstDay: firstDay, today: DailyHealthRollup.dayString(for: Date())
        )
    }

    /// 能耗卡：柱图（系统耗电，小时/日柱随 range）+ 摘要行（总耗电/日均/电池
    /// 放电）+ 今日 SOC 区间行 + 脚注（估算口径 + 复位计数——「如实呈现」纪律）。
    var energyCard: some View {
        statsPanel(theme: theme, title: CellarL10n.s("stats.energy.title")) {
            energyChart
            VStack(alignment: .leading, spacing: 3) {
                Text(CellarL10n.s("stats.energy.total", formatWh(energyTotalMWh)))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                if rangeWindow != .hours24 {
                    Text(CellarL10n.s("stats.energy.dailyAvg", formatWh(energyTotalMWh / Double(rangeWindow.lookbackSeconds / 86_400))))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                if energyDischargeMWh > 0 {
                    Text(CellarL10n.s("stats.energy.discharge", formatWh(energyDischargeMWh)))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                if let socRangeText {
                    Text(socRangeText)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                if let footnote = energyFootnote {
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
                // 数据未填满所选窗时卡内下沉提示（三张曲线卡同款口径）。
                accumulatingNote
            }
        }
    }

    /// 柱图数据点（桶 start 全局唯一可作 id——DataPoint 先例）。
    private struct EnergyBarPoint: Identifiable {
        let date: Date
        let wh: Double
        var id: Date { date }
    }

    /// 系统耗电柱（BarMark；Y 轴 Wh——mWh 直显数值过大，/1000 换算展示层单点）。
    private var energyBars: [EnergyBarPoint] {
        (energy?.buckets ?? []).map { EnergyBarPoint(date: $0.start, wh: $0.systemMWh / 1000) }
    }

    private var energyChart: some View {
        Chart {
            ForEach(energyBars) { point in
                BarMark(
                    x: .value("time", point.date),
                    y: .value("wh", point.wh)
                )
            }
        }
        .foregroundStyle(theme.accent)
        .chartAxisTheme(theme, xStride: rangeWindow.xAxisStride.component,
                        xStrideCount: rangeWindow.xAxisStride.count)
        .chartYAxisLabel {
            Text(CellarL10n.s("stats.unit.watthour"))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(height: 140)
    }

    /// 范围总耗电（系统通道 mWh 累计）。
    private var energyTotalMWh: Double {
        (energy?.buckets ?? []).reduce(0) { $0 + $1.systemMWh }
    }

    /// 范围电池放电累计（mWh）。
    private var energyDischargeMWh: Double {
        (energy?.buckets ?? []).reduce(0) { $0 + $1.dischargeMWh }
    }

    /// 今日 SOC 区间行（0.22.0 §3.3）：最新样本系统键双非 nil ∧ 新鲜 → 「系统
    /// 记录」（重置时机未知——展示不解释成因；跨会话启动窗口 latest 可能是隔日
    /// 旧行，ts 距今 >10 min 不渲染系统行——code-review P3-2，落采样兜底）；
    /// 键缺席 → 本页样本 min/max 兜底「（采样）」标注——**仅 24h 窗**（7d/30d
    /// 窗 buckets 是多日跨度，标「今日」为事实性错位——code-review P3-1）；
    /// 无数据不渲染。部分日覆盖不另标注——由 stats.accumulating 承接。
    private var socRangeText: String? {
        if let min = latestSample?.dailyMinSoc, let max = latestSample?.dailyMaxSoc,
           let latestTs = latestSample?.timestamp,
           Date().timeIntervalSince(latestTs) <= 600 {
            return CellarL10n.s("stats.energy.soc.system", min, max)
        }
        guard rangeWindow == .hours24, let first = buckets.first else { return nil }
        let min = buckets.reduce(first.minPercent) { Swift.min($0, $1.minPercent) }
        let max = buckets.reduce(first.maxPercent) { Swift.max($0, $1.maxPercent) }
        return CellarL10n.s("stats.energy.soc.sample", min, max)
    }

    /// 脚注（caption2）：`固件累加器估算 · 复位 N 次`——N = 系统 + 放电复位
    /// 合计，N>0 才缀（该日低估如实呈现）；全零 → 仅估算标注。
    private var energyFootnote: String? {
        guard let energy else { return nil }
        let total = energy.resets + energy.dischargeResets
        return total > 0
            ? CellarL10n.s("stats.energy.footnote", total)
            : CellarL10n.s("stats.energy.estimate")
    }
}

// MARK: - 曲线卡子视图（0.23.8 B3-2 hover 下沉，各卡独立 struct）

/// 电量卡子视图（0.23.8 B3-2 hover 下沉）：hover 态随卡——鼠标移动只重求值
/// 本卡，不再整页重投影（原页级 @State 每帧触发五卡 + O(n) 投影全量重算）。
/// 各卡独立 hover 实例保持「共享会跨卡串显」语义（原 StatsPageView.swift
/// :107-108 注记语义随迁）。
///
/// 曲线形态：波动带（成对 min/max 的 AreaMark，accent 10% 透明度）垫底 +
/// 按充放状态分色的均值折线；Y 轴 0-100%。
struct StatsBatteryCard: View {
    let theme: CellarTheme
    let buckets: [StatsBucket]
    let rangeWindow: StatsPageView.RangeWindow
    /// 页级预计算传参（依赖页 @State firstSampleDate/rangeWindow——卡不回读页）。
    let accumulatingNoteText: String?
    @State private var hover: StatsHoverPoint?

    var body: some View {
        statsPanel(theme: theme, title: CellarL10n.s("stats.chart.percent"),
                   subtitle: CellarL10n.s("stats.chart.percent.subtitle")) {
            batteryChart
            // 0.18 D-2d：「记录自」徽章退役——数据未填满所选窗时卡内下沉提示
            //（页级 accumulatingNote 渲染形态内联等价，卡仅持文本参数不回读页）。
            Group {
                if let accumulatingNoteText {
                    Text(accumulatingNoteText)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        // B7-1 a11y：图表数值仅 hover 可达——整卡合并单元素 + 最新采样摘要值
        //（走既有 l10n 词，不逐点暴露——逐点对读屏是噪音；元数据零像素）。
        .accessibilityElement(children: .combine)
        .accessibilityValue(a11ySummary)
    }

    /// a11y 值（B7-1）：最新桶采样摘要——标题词 + 均值（波动带上下界）；无数据
    /// → common.nodata 如实降级。
    private var a11ySummary: String {
        guard let last = buckets.last else { return CellarL10n.s("common.nodata") }
        return CellarL10n.s("stats.chart.percent")
            + " " + StatsChartHoverFormat.percent(last.avgPercent)
            + "（" + StatsChartHoverFormat.percent(Double(last.minPercent))
            + " – " + StatsChartHoverFormat.percent(Double(last.maxPercent)) + "）"
    }

    /// 电量卡 hover 游标（含波动带上下界）——自 batteryChart 大表达式抽出。
    @ChartContentBuilder
    private var batteryHoverMark: some ChartContent {
        if let hover {
            StatsChartHover.ruleMark(
                for: hover, theme: theme,
                value: StatsChartHoverFormat.percent,
                time: hoverTimeFormat
            )
        }
    }

    /// hover 时间格式随窗（code-review P3-1：24h 用 HH:mm，7d/30d 跨天需日期——
    /// 与 X 轴 label 口径一致；独立计算属性避免三元嵌进 Chart 大表达式致
    /// type-check 超时）。0.23.8 B3-2：仅三张 range 卡持有（吃自身 rangeWindow）；
    /// 容量卡恒 dayTime 不消费本属性。
    private var hoverTimeFormat: (Date) -> String {
        if rangeWindow == .hours24 { return StatsChartHoverFormat.hourMinute }
        return StatsChartHoverFormat.dayTime
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
            // 0.18 T2 D-2a：hover 竖游标 + 值标签（含波动带上下界；nil = 无 hover）。
            // hover mark 抽独立 @ChartContentBuilder 方法——给 batteryChart 大
            // 表达式瘦身（type-check 超时修复，code-review 后补）。
            batteryHoverMark
        }
        .chartYScale(domain: 0...100)
        .chartAxisTheme(theme, xStride: rangeWindow.xAxisStride.component,
                        xStrideCount: rangeWindow.xAxisStride.count)
        .chartYAxisLabel {
            Text(CellarL10n.s("stats.unit.percent"))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
        }
        // hover 手势（0.18 T2 D-2a）：断档阈值 = 桶径一半（StatsChartHover 注记）。
        .statsChartHover(
            points: batteryHoverPoints,
            bucketSeconds: Double(rangeWindow.bucketSeconds),
            hover: $hover
        )
        .frame(height: 180)
    }

    // MARK: 数据投影（卡私有）

    /// hover 投影（电量卡：均值折线点 + 波动带上下界；段共享边界点重复无害
    /// ——同 date 同值，最近点查找等价）。
    private var batteryHoverPoints: [StatsHoverPoint] {
        segments.flatMap { segment in
            segment.points.map {
                StatsHoverPoint(date: $0.date, value: $0.avg, min: $0.min, max: $0.max)
            }
        }
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

    /// 三色语汇（照功率流：充电 accent / 停充 holding 色 / 放电 warn）。
    private func lineColor(for state: StatsChargingState) -> Color {
        switch state {
        case .charging: return theme.accent
        case .holding: return theme.holding
        case .discharging: return theme.warning
        }
    }
}

/// 窖温卡子视图（0.23.8 B3-2 hover 下沉；自 StatsPageView extension 拆出，
/// Chart 体逐字随迁，hover 态随卡）。
struct StatsTemperatureCard: View {
    let theme: CellarTheme
    let buckets: [StatsBucket]
    let rangeWindow: StatsPageView.RangeWindow
    /// 页级预计算传参（依赖页 @State firstSampleDate/rangeWindow——卡不回读页）。
    let accumulatingNoteText: String?
    @State private var hover: StatsHoverPoint?

    var body: some View {
        statsPanel(theme: theme, title: CellarL10n.s("stats.chart.temp")) {
            Chart {
                lineSeries(temperatureRuns, yKey: "temp")
                // 0.18 T2 D-2a：hover 竖游标 + 值标签（nil = 无 hover）。
                if let hover {
                    StatsChartHover.ruleMark(
                        for: hover, theme: theme,
                        value: StatsChartHoverFormat.celsius,
                        time: hoverTimeFormat
                    )
                }
            }
            .foregroundStyle(theme.accent)
            .chartAxisTheme(theme, xStride: rangeWindow.xAxisStride.component,
                            xStrideCount: rangeWindow.xAxisStride.count)
            .chartYAxisLabel {
                Text(CellarL10n.s("stats.unit.celsius"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            .statsChartHover(
                points: hoverPoints(temperatureRuns),
                bucketSeconds: Double(rangeWindow.bucketSeconds),
                hover: $hover
            )
            .frame(height: 180)
            // 0.18 D-2d：「记录自」徽章退役——数据未填满所选窗时卡内下沉提示
            //（页级 accumulatingNote 渲染形态内联等价，卡仅持文本参数不回读页）。
            Group {
                if let accumulatingNoteText {
                    Text(accumulatingNoteText)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        // B7-1 a11y：整卡合并单元素 + 最新采样摘要值（元数据零像素）。
        .accessibilityElement(children: .combine)
        .accessibilityValue(a11ySummary)
    }

    /// a11y 值（B7-1）：最新桶温度采样摘要；无数据 → common.nodata。
    private var a11ySummary: String {
        guard let last = buckets.last else { return CellarL10n.s("common.nodata") }
        return CellarL10n.s("stats.chart.temp")
            + " " + StatsChartHoverFormat.celsius(last.avgTempCentiC / 100)
    }

    /// hover 时间格式随窗（code-review P3-1：24h 用 HH:mm，7d/30d 跨天需日期——
    /// 与 X 轴 label 口径一致；独立计算属性避免三元嵌进 Chart 大表达式致
    /// type-check 超时。0.23.8 B3-2 随卡下沉，同电量卡）。
    private var hoverTimeFormat: (Date) -> String {
        if rangeWindow == .hours24 { return StatsChartHoverFormat.hourMinute }
        return StatsChartHoverFormat.dayTime
    }

    private var temperaturePoints: [DataPoint] {
        buckets.map { DataPoint(date: $0.start, value: $0.avgTempCentiC / 100) }
    }

    /// 窖温：单 series 改连续 run 分组（与电量分段同技巧）。
    private var temperatureRuns: [DataRun] {
        continuousRuns(temperaturePoints, bucketSeconds: Double(rangeWindow.bucketSeconds))
    }
}

/// 功耗卡子视图（0.23.8 B3-2 hover 下沉；自 StatsPageView extension 拆出，
/// Chart 体逐字随迁，hover 态随卡）。折线含零轴（正=充电输入 / 负=放电输出，
/// 符号纪律 §2.1）——Charts 跨零域默认画出零轴线。
struct StatsPowerCard: View {
    let theme: CellarTheme
    let buckets: [StatsBucket]
    let rangeWindow: StatsPageView.RangeWindow
    /// 页级预计算传参（依赖页 @State firstSampleDate/rangeWindow——卡不回读页）。
    let accumulatingNoteText: String?
    @State private var hover: StatsHoverPoint?

    var body: some View {
        statsPanel(theme: theme, title: CellarL10n.s("stats.chart.power"),
                   subtitle: CellarL10n.s("stats.chart.power.subtitle")) {
            Chart {
                lineSeries(powerRuns, yKey: "power")
                // 0.18 T2 D-2a：hover 竖游标 + 值标签（nil = 无 hover）。
                if let hover {
                    StatsChartHover.ruleMark(
                        for: hover, theme: theme,
                        value: StatsChartHoverFormat.watt,
                        // 0.23.7 B2-5：hover 时间随窗切换（原恒 dayTime 不随
                        // rangeWindow——与电量/温度卡对齐，复用既有条件形态
                        // hoverTimeFormat；0.23.8 B3-2 随卡下沉）。
                        time: hoverTimeFormat
                    )
                }
            }
            .foregroundStyle(theme.accent)
            .chartAxisTheme(theme, xStride: rangeWindow.xAxisStride.component,
                            xStrideCount: rangeWindow.xAxisStride.count)
            .chartYAxisLabel {
                Text(CellarL10n.s("stats.unit.watt"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            .statsChartHover(
                points: hoverPoints(powerRuns),
                bucketSeconds: Double(rangeWindow.bucketSeconds),
                hover: $hover
            )
            .frame(height: 180)
            // 0.18 D-2d：「记录自」徽章退役——数据未填满所选窗时卡内下沉提示
            //（页级 accumulatingNote 渲染形态内联等价，卡仅持文本参数不回读页）。
            Group {
                if let accumulatingNoteText {
                    Text(accumulatingNoteText)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        // B7-1 a11y：整卡合并单元素 + 最新采样摘要值（元数据零像素）。
        .accessibilityElement(children: .combine)
        .accessibilityValue(a11ySummary)
    }

    /// a11y 值（B7-1）：最新桶功率采样摘要；无数据 → common.nodata。
    private var a11ySummary: String {
        guard let last = buckets.last else { return CellarL10n.s("common.nodata") }
        return CellarL10n.s("stats.chart.power")
            + " " + StatsChartHoverFormat.watt(last.avgPowerMW / 1000)
    }

    /// hover 时间格式随窗（code-review P3-1：24h 用 HH:mm，7d/30d 跨天需日期——
    /// 与 X 轴 label 口径一致；独立计算属性避免三元嵌进 Chart 大表达式致
    /// type-check 超时。0.23.8 B3-2 随卡下沉，同电量卡）。
    private var hoverTimeFormat: (Date) -> String {
        if rangeWindow == .hours24 { return StatsChartHoverFormat.hourMinute }
        return StatsChartHoverFormat.dayTime
    }

    private var powerPoints: [DataPoint] {
        buckets.map { DataPoint(date: $0.start, value: $0.avgPowerMW / 1000) }
    }

    /// 功耗：单 series 改连续 run 分组（与电量分段同技巧）。
    private var powerRuns: [DataRun] {
        continuousRuns(powerPoints, bucketSeconds: Double(rangeWindow.bucketSeconds))
    }
}

/// 最大容量趋势卡子视图（0.23.8 B3-2 hover 下沉；自 StatsPageView extension
/// 拆出，Chart 体逐字随迁，hover 态随卡）：全保留窗小时桶趋势；≥2 点才显示
/// （StatsPageView 门控）——容量变化以周计，窄窗内是一条无信息平线，不如如实
/// 隐藏。慢变量但断档判据与三张曲线求一致（整夜睡眠在 35 天窗内高频出现，
/// 跨连同样是断档造假）。副标题钉死口径（v1.8 走查批 F5：nominal/design——
/// 与仪表板「健康」同源，MaxCapacity 键语义漂移不再直采）。
struct StatsCapacityCard: View {
    let theme: CellarTheme
    let capacityPoints: [StatsPageView.CapacityPoint]
    @State private var hover: StatsHoverPoint?

    var body: some View {
        statsPanel(theme: theme, title: CellarL10n.s("stats.chart.capacity"),
                   subtitle: CellarL10n.s("stats.maxCapacity.caliber")) {
            Chart {
                lineSeries(capacityRuns, yKey: "capacity")
                // 0.18 T2 D-2a：hover 竖游标 + 值标签（nil = 无 hover）。
                if let hover {
                    StatsChartHover.ruleMark(
                        for: hover, theme: theme,
                        value: StatsChartHoverFormat.healthPercent,
                        // B2 plan-reviewer P1 裁决「不改 + 不该改」（0.23.7 B2-5
                        // 登记，0.23.8 B3-2 随迁）：容量卡数据源为全保留窗概览
                        // 查询恒跨多天，dayTime 带日期是正确行为——恒 dayTime
                        // 不随窗切换（三张 range 卡 hoverTimeFormat 不适用本卡）。
                        time: StatsChartHoverFormat.dayTime
                    )
                }
            }
            .foregroundStyle(theme.accent)
            // X 轴步长随数据跨度分档（0.23.4 方案 A；0.18.1 T6 写死 1 天步长在数据
            // 积累后标签溢出绘图区容量致重叠——Charts 对显式 stride 不做自动取舍，
            // 实证见 docs/plans/phase7-0.23.4 §0）。
            .chartAxisTheme(theme, xStride: capacityAxisStride.component,
                            xStrideCount: capacityAxisStride.count)
            .chartYAxisLabel {
                Text(CellarL10n.s("stats.unit.percent"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            .statsChartHover(
                points: hoverPoints(capacityRuns),
                bucketSeconds: Double(StatsPageView.overviewBucketSeconds),
                hover: $hover
            )
            .frame(height: 180)
        }
        // B7-1 a11y：整卡合并单元素 + 最新采样摘要值（元数据零像素）。
        .accessibilityElement(children: .combine)
        .accessibilityValue(a11ySummary)
    }

    /// a11y 值（B7-1）：最新容量趋势点摘要（健康度口径与副标题一致）；无数据
    /// → common.nodata。
    private var a11ySummary: String {
        guard let last = capacityPoints.last else { return CellarL10n.s("common.nodata") }
        return CellarL10n.s("stats.chart.capacity")
            + " " + StatsChartHoverFormat.healthPercent(last.percent)
    }

    /// 轴域 = capacityPoints 首尾跨度（Charts domain = 数据极值；ceil 保守——
    /// 跨度偏大方向分档 → 标签更稀，安全向）。卡显门控 = ≥2 点（StatsPageView
    /// body），空/单点本属性不参与渲染，仍防御返回 1 天档。
    private var capacityAxisStride: (component: Calendar.Component, count: Int) {
        guard let first = capacityPoints.first?.date,
              let last = capacityPoints.last?.date else { return (.day, 1) }
        let days = Int(ceil(last.timeIntervalSince(first) / 86_400))
        return ChartAxisStride.capacity(dataSpanDays: days)
    }

    /// 容量趋势：概览查询小时桶（StatsPageView.overviewBucketSeconds）。
    private var capacityRuns: [DataRun] {
        continuousRuns(
            capacityPoints.map { DataPoint(date: $0.date, value: $0.percent) },
            bucketSeconds: Double(StatsPageView.overviewBucketSeconds)
        )
    }
}


// MARK: - 共享投影与容器（0.23.8 B3-2：自 StatsPageView extension 收敛文件级）

/// 面板卡（DashboardView.panel 同款：surface 底 + 描边 + 圆角 18 + 小标题行；
/// 高度 220 适配单曲线卡）。0.23.8 B3-2：原 StatsPageView.panel（页级方法）
/// 退役删除——重构后全部消费点（四卡 + energyCard）收敛本文件，布局落文件级
/// 共享 helper，参数显式加 theme（卡 struct 不回读页 environment）；
/// StatsPageView.swift 一侧零剩余消费点。DashboardView/AutomationPageView/
/// CalibrationPageView 三处独立 panel 实现**零触及**（方案 §0.2-4）。0.23.17
/// 起 internal（文件级 private 退役）——StatsTrendCard 独立文件消费（本文件
/// 达 800 行硬上限按分区拆文件，DashboardViewCards 先例）。
func statsPanel(
    theme: CellarTheme,
    title: String,
    subtitle: String? = nil,
    @ViewBuilder content: () -> some View
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(theme.secondaryText)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
    .background {
        if let panelBackground = theme.panelBackground { panelBackground }
    }
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
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

/// hover 投影（单线卡通用：run 平铺、无波动带）。
private func hoverPoints(_ runs: [DataRun]) -> [StatsHoverPoint] {
    runs.flatMap { run in
        run.points.map { StatsHoverPoint(date: $0.date, value: $0.value, min: nil, max: nil) }
    }
}

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

// MARK: - Wh 格式化（0.22.0 §3.2 单 helper 集中一处）

/// mWh → Wh 文案（能耗卡全部 Wh 值唯一出口）：≥100 Wh 取整、否则 1 位小数。
private func formatWh(_ mWh: Double) -> String {
    let wh = mWh / 1000
    return wh >= 100 ? String(format: "%.0f", wh) : String(format: "%.1f", wh)
}

// MARK: - 图表坐标轴主题（token 化）

/// 四张曲线卡共用坐标轴主题：网格/刻度字全走 theme token（G2——琥珀风格下
/// 不泄漏 Charts 系统默认前景色；native 语义色自动深浅合规）。ViewModifier
/// 形态：chartXAxis/chartYAxis 必须修饰 Chart 本体，不能收进页面实例方法。
///
/// X 轴固定步长（0.18 T2 D-2b/D-2c）：从 `.automatic(desiredCount: 5)` 改日历
/// 步长整点对齐（24h=6h / 7d=2d / 30d=7d；容量卡步长 0.23.4 起随数据跨度分档
/// 1/2/5 天——0.18.1 T6 写死 1 天在数据积累后标签溢出绘图区容量，见
/// StatsCapacityCard）——
/// 刻度收敛于日历单元边界、每窗 ~4-5 刻度，末刻度不再贴绘图区右缘（「S...」
/// 截断随固定刻度消除）；label 格式随窗统一（小时步长「HH:mm」/ 日步长「M/d」）。
private struct StatsChartAxisTheme: ViewModifier {
    let theme: CellarTheme
    /// X 轴步长单元与倍数（卡侧按窗注入）。
    let xStride: Calendar.Component
    let xStrideCount: Int

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .stride(by: xStride, count: xStrideCount)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: xStride == .hour
                                ? .dateTime.hour().minute()
                                : .dateTime.month().day())
                            .foregroundStyle(theme.tertiaryText)
                        }
                    }
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

extension View {
    /// internal（0.23.17 起文件级 private 退役）——StatsTrendCard 独立文件消费
    /// （statsPanel 同款拆文件纪律）。
    func chartAxisTheme(_ theme: CellarTheme, xStride: Calendar.Component, xStrideCount: Int) -> some View {
        modifier(StatsChartAxisTheme(theme: theme, xStride: xStride, xStrideCount: xStrideCount))
    }
}

// MARK: - X 轴固定步长（0.18 T2 D-2b）

extension StatsPageView.RangeWindow {
    /// X 轴日历步长（24h=6h / 7d=2d / 30d=7d——~4 刻度整点对齐；容量卡不走
    /// 本表，步长随数据跨度分档见 StatsCapacityCard/ChartAxisStride——0.23.4）。
    var xAxisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .hours24: return (.hour, 6)
        case .days7: return (.day, 2)
        case .days30: return (.day, 7)
        }
    }
}
