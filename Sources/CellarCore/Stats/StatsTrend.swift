import Foundation

// 健康趋势纯函数层（0.23.17 §2.3）：daily_health 每日下采样行的聚合核 + 周桶
// 趋势 + cycle 阈值外推 + 呈现门槛。形态照 StatsBucketing/ChartAxisStride——
// 全部纯函数、无 IO（聚合不藏 SQL：SELECT 全在 StatsStore actor 内，本文件只
// 吃值类型行；回填与滚动写入共用同一聚合核，口径单源）。

// MARK: - 每日健康行（daily_health 表一行的值投影）

/// daily_health 表一行（Schema v3，§2.1）：每日下采样。35 天 samples 保留窗之外
/// 的历史只有这里（1 行/天年增 365 行，永不 prune——永久保留即特性本体，调研 A3
/// 约束 3）。
public struct DailyHealthRow: Equatable, Sendable {
    /// 本地日串（'YYYY-MM-DD'，en_US_POSIX 固定格式 + Calendar.current 时区）。
    public let day: String
    /// 当日 cycle 最大值。
    public let cycleMax: Int
    /// 当日最大健康度（厘百分点 0.01pp 精度——取整纪律照 temp_centi 先例，钉死
    /// 整数截断 nominal×10000/design 整除；nominal/design 任一缺席或 design ≤ 0
    /// 的样本不参与，全缺席 → nil——缺席机型不造数，R-6 同款）。
    public let healthCentiPct: Int?
    /// 当日上限众数（策略上下文钩子——调研 A4 留钩，0.23.18 用法定型时可再深化；
    /// 回填日历史无策略上下文 → NULL，daemon 失联日无读数 → nil，如实）。
    public let upperMode: Int?
    /// 当日入库样本数（数据质量指示）。
    public let sampleCount: Int

    public init(
        day: String, cycleMax: Int, healthCentiPct: Int?,
        upperMode: Int?, sampleCount: Int
    ) {
        self.day = day
        self.cycleMax = cycleMax
        self.healthCentiPct = healthCentiPct
        self.upperMode = upperMode
        self.sampleCount = sampleCount
    }
}

// MARK: - 聚合核（回填与滚动写入共用——口径单源，§2.3.1）

/// daily_health 聚合纯函数：samples → 按本地日分组的日行（回填）或单日行（滚动）。
public enum DailyHealthRollup {
    /// 单日累加器（局部 struct——聚合完成后一次性产出值类型行，StatsBucketing 先例）。
    struct Accumulator {
        var count = 0
        var cycleMax = 0
        var healthCentiPct: Int?
    }

    /// 本地日串投影（'YYYY-MM-DD'）：秒 → 日串（en_US_POSIX 固定格式防 locale
    /// 漂移；startOfDay 先行，任意时刻投影到所属日）。DST 安全日界（23/25 小时
    /// 日）由 Calendar 派生承接——**禁 86400 乘法**（评审 P2 修正）。
    public static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: calendar.startOfDay(for: date))
    }

    /// 回填聚合（迁移一次性：samples 全表 → 按日分组日行序列，day ASC）。
    /// 回填日 `upper_mode` 恒 nil——历史无策略上下文，如实不造数。
    public static func backfillRows(samples: [StatsSample]) -> [DailyHealthRow] {
        let groups = group(samples)
        return groups.keys.sorted().map { day in
            let accumulator = groups[day]!
            return DailyHealthRow(
                day: day,
                cycleMax: accumulator.cycleMax,
                healthCentiPct: accumulator.healthCentiPct,
                upperMode: nil,
                sampleCount: accumulator.count
            )
        }
    }

    /// 单日行聚合（滚动写入核）：输入即当日样本（StatsStore.upsertDailyHealth
    /// 已按日界范围 SELECT）。upperHistogram = 当日上限读数直方图（[上限: 计数]，
    /// App 层采样循环维护）→ 众数落 upper_mode。同日重算同值（幂等——INSERT OR
    /// REPLACE 自愈语义的聚合侧前提）。空输入防御行（生产不可达：upsert 前必有
    /// 本跳样本入库）day 串为空串，如实零值。
    public static func dayRow(
        samples: [StatsSample], upperHistogram: [Int: Int]
    ) -> DailyHealthRow {
        let mode = mode(of: upperHistogram)
        guard let first = samples.first else {
            return DailyHealthRow(
                day: "", cycleMax: 0, healthCentiPct: nil,
                upperMode: mode, sampleCount: 0
            )
        }
        let day = dayString(for: first.timestamp)
        let accumulator = group(samples)[day] ?? Accumulator()
        return DailyHealthRow(
            day: day,
            cycleMax: accumulator.cycleMax,
            healthCentiPct: accumulator.healthCentiPct,
            upperMode: mode,
            sampleCount: accumulator.count
        )
    }

    /// 直方图众数（计数最大者；并列取更小值——确定性钉死，偏保守限值语义）；
    /// 空直方图 → nil（失联日无读数如实）。
    static func mode(of histogram: [Int: Int]) -> Int? {
        var best: (value: Int, count: Int)?
        for (value, count) in histogram {
            if let current = best {
                if count > current.count || (count == current.count && value < current.value) {
                    best = (value, count)
                }
            } else {
                best = (value, count)
            }
        }
        return best?.value
    }

    /// 分组核（共享单源）：按本地日分组 →（cycle max / 健康度厘百分点 max / 计数）。
    private static func group(_ samples: [StatsSample]) -> [String: Accumulator] {
        var groups: [String: Accumulator] = [:]
        for sample in samples {
            let day = dayString(for: sample.timestamp)
            var accumulator = groups[day] ?? Accumulator()
            accumulator.count += 1
            accumulator.cycleMax = max(accumulator.cycleMax, sample.cycleCount)
            // 健康度采样：两容量字段齐备才参与（任一缺席跳过）；design ≤ 0 视同
            // 缺席（防除零——StatsBucketing.avgHealthPercent 同款口径）；取整 =
            // 整数截断（§2.1 评审 P3 修正），日内取最大。
            if let nominal = sample.nominalChargeCapacityMAh,
               let design = sample.designCapacityMAh, design > 0 {
                let centi = nominal * 10_000 / design
                accumulator.healthCentiPct = max(accumulator.healthCentiPct ?? centi, centi)
            }
            groups[day] = accumulator
        }
        return groups
    }
}

// MARK: - 趋势纯函数（§2.3.2-4）

/// 周桶趋势带（锚首日 7 天顺序窗，不追 ISO 自然周——确定性优先、测试友好，§8
/// 登记偏差理由）。量纲：median 厘百分点 Double（偶数桶两中值均值）；min/max
/// 厘百分点 Int。
public struct WeeklyBand: Equatable, Sendable {
    /// 窗起始日串（窗锚 = 首日 + 7×窗序）。
    public let startDay: String
    /// 窗结束日串（start + 6——含端 7 天窗）。
    public let endDay: String
    /// 窗内健康度中位数（厘百分点；偶数桶取两中值均值）。
    public let median: Double
    /// 窗内健康度最小值（厘百分点）。
    public let min: Int
    /// 窗内健康度最大值（厘百分点）。
    public let max: Int
    /// 窗内 sample_count 合计（数据质量指示）。
    public let samples: Int
}

/// cycle 阈值线性外推结果（§2.3.3）。
public struct CycleProjection: Equatable, Sendable {
    /// 线性速率（循环/月；30.44 天/月口径）。
    public let cyclesPerMonth: Double
    /// 到阈值月数；nil = 阈值已过（外推不可达——呈现层退化句「循环数已达阈值」）。
    public let monthsToThreshold: Double?
}

/// 趋势呈现（§2.3.4 三态门槛；调研决策点 2 锁定值，常量单源）。
public enum TrendPresentation: Equatable, Sendable {
    /// < 14 天——卡不渲染（决策点 1 锁定）。
    case insufficient
    /// 14-89 天——趋势带图。
    case band
    /// ≥ 90 天 ∧ ≥ 13 桶——带图 + cycle 数字外推。
    case numeric
}

public enum StatsTrend {
    // MARK: 门槛/口径常量（单源——UI 侧禁散落魔法数，一律引用本组）

    /// band 态下限（跨日数）。
    public static let bandMinDays = 14
    /// numeric 态下限（跨日数；趋势卡副标题「N/90 天」同源）。
    public static let numericMinDays = 90
    /// numeric 态下限（完整周桶数）。
    public static let numericMinBuckets = 13
    /// Apple 电池服务阈值（机型差异登记为已知近似——调研 A2/A3）。
    public static let cycleThreshold = 1000
    /// 月均天数（365.25/12——外推统一口径）。
    static let daysPerMonth = 30.44
    /// 周桶窗宽（天；趋势卡 hover 桶径与跨空窗断笔判据同源——禁散落魔法数）。
    public static let windowDays = 7

    /// 呈现门槛（§2.3.4）：输入 daysOfData 口径钉死 = **跨日数**（首日 → 今天的
    /// 日历天数，非日行数——与「积累时长」语义一致，断档运行的机器不虚高，评审
    /// P2 修正；跨日数经 crossDayCount 派生，勿以日行数冒充）。
    public static func presentationState(
        daysOfData: Int, weeklyBucketCount: Int
    ) -> TrendPresentation {
        if daysOfData < bandMinDays { return .insufficient }
        if daysOfData < numericMinDays { return .band }
        return weeklyBucketCount >= numericMinBuckets ? .numeric : .band
    }

    /// 跨日数（日串 → 日串的日历天数差，today − firstDay）：daysOfData 的唯一
    /// 口径出口（UTC 锚定差分——日串无时区语义，免 DST/时区漂移）。
    public static func crossDayCount(firstDay: String, today: String) -> Int? {
        guard let start = dayDate(firstDay), let end = dayDate(today) else { return nil }
        return utcCalendar.dateComponents([.day], from: start, to: end).day
    }

    /// 日串 → 本地午夜 Date（趋势卡图表 X 轴消费的单一出口；日串无时区语义 →
    /// 按本地日历解读，X 轴月日标签不漂移）。解析失败 → nil。
    public static func localMidnight(forDay day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayNumber
        return Calendar.current.date(from: components).map { Calendar.current.startOfDay(for: $0) }
    }

    /// 周桶趋势带（§2.3.2）：锚首日 7 天顺序窗；窗内 health_centi_pct 非空集 →
    /// 中位数 + min/max；空窗跳过（断档如实）；**尾窗不满 7 天整窗丢弃，窗满才出**
    /// （与断档如实语义一致，评审 P2 修正）。输入任意序，内部按 day ASC 归位。
    public static func weeklyBands(daily: [DailyHealthRow]) -> [WeeklyBand] {
        let rows = daily.sorted { $0.day < $1.day }
        guard let first = rows.first, let last = rows.last,
              let firstOrdinal = ordinal(first.day), let lastOrdinal = ordinal(last.day)
        else { return [] }
        // 完整窗数 = 跨日数 / 7（整除）——末窗不满 7 天整窗丢弃（窗满才出）。
        let spanDays = lastOrdinal - firstOrdinal + 1
        let completeWindows = spanDays / windowDays
        guard completeWindows > 0 else { return [] }

        struct WindowAccumulator {
            var values: [Int] = []
            var samples = 0
        }
        var windows: [Int: WindowAccumulator] = [:]
        for row in rows {
            guard let ordinal = ordinal(row.day) else { continue }   // 日串非法 → 行不参与
            let index = (ordinal - firstOrdinal) / windowDays
            guard index >= 0, index < completeWindows else { continue }   // 尾窗丢弃
            var accumulator = windows[index] ?? WindowAccumulator()
            if let health = row.healthCentiPct { accumulator.values.append(health) }
            accumulator.samples += row.sampleCount
            windows[index] = accumulator
        }

        return windows.keys.sorted().compactMap { index in
            let accumulator = windows[index]!
            guard let sorted = sortNonEmpty(accumulator.values) else { return nil }   // 空窗跳过
            let startOrdinal = firstOrdinal + index * windowDays
            return WeeklyBand(
                startDay: dayStringFromOrdinal(startOrdinal),
                endDay: dayStringFromOrdinal(startOrdinal + windowDays - 1),
                median: median(of: sorted),
                min: sorted.first!,
                max: sorted.last!,
                samples: accumulator.samples
            )
        }
    }

    /// cycle 阈值线性外推（§2.3.3）：速率 =（末 cycle − 首 cycle）/ 跨日数；
    /// 速率 ≤ 0 → nil（不外推，如实——平台期/下降无「到达」语义）；monthsToThreshold
    /// =（threshold − 末 cycle）/ 速率 / 30.44，阈值已过 → nil。**输入取 day ≤
    /// 今天的行**（未来行过滤在 StatsStore.dailyHealth——时钟前跳行不参与，评审
    /// P3 登记）。
    public static func cycleProjection(
        first: DailyHealthRow, last: DailyHealthRow,
        threshold: Int = StatsTrend.cycleThreshold
    ) -> CycleProjection? {
        guard let spanDays = crossDayCount(firstDay: first.day, today: last.day),
              spanDays > 0 else { return nil }   // 同日/倒序防御：无可观测速率
        let ratePerDay = Double(last.cycleMax - first.cycleMax) / Double(spanDays)
        guard ratePerDay > 0 else { return nil }
        let remaining = Double(threshold - last.cycleMax)
        return CycleProjection(
            cyclesPerMonth: ratePerDay * daysPerMonth,
            monthsToThreshold: remaining > 0 ? remaining / ratePerDay / daysPerMonth : nil
        )
    }

    // MARK: 内部位移（UTC 锚定——差分免 DST；日串无时区语义）

    /// 固定 UTC 公历历（日串锚定差分专用；Calendar 值类型 Sendable）。
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 'YYYY-MM-DD' 严格解析（段数 3 + 定宽 + 数值域；en_US_POSIX 自解析——
    /// DateFormatter 实例非 Sendable，纯函数内免共享可变面）。非法 → nil。
    private static func dayDate(_ day: String) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts[0].count == 4, let year = Int(parts[0]),
              parts[1].count == 2, let month = Int(parts[1]), (1...12).contains(month),
              parts[2].count == 2, let dayNumber = Int(parts[2]), (1...31).contains(dayNumber)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayNumber
        return utcCalendar.date(from: components)
    }

    /// 日串序数（UTC 锚定参照日起的天差——窗序与跨日数共用同一锚，免漂移）。
    private static func ordinal(_ day: String) -> Int? {
        guard let date = dayDate(day) else { return nil }
        return utcCalendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: date).day
    }

    /// 序数 → 日串（窗起止呈现面；与 ordinal 同锚互逆）。
    private static func dayStringFromOrdinal(_ ordinal: Int) -> String {
        let date = utcCalendar.date(
            byAdding: .day, value: ordinal,
            to: Date(timeIntervalSince1970: 0)
        ) ?? Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utcCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// 非空降序排序（空输入 → nil——空窗跳过判据）。
    private static func sortNonEmpty(_ values: [Int]) -> [Int]? {
        guard !values.isEmpty else { return nil }
        return values.sorted()
    }

    /// 中位数（奇数桶取中值；偶数桶取两中值均值——Double 厘百分点）。
    private static func median(of sorted: [Int]) -> Double {
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return Double(sorted[middle]) }
        return Double(sorted[middle - 1] + sorted[middle]) / 2
    }
}
