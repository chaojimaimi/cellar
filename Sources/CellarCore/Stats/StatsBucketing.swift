import Foundation

/// 桶内充放折叠态（方案 §2.2 R1 P2-3）：M3 电量曲线分色数据源（充电 accent /
/// 停充 holding 色 / 放电 warn——照功率流三色语汇）。
///
/// 折叠规则（全定义域 total function，不可构造失败）：
/// - 未外接 → 放电（物理上无外接不构成充电；快照键异常态如实归入放电）；
/// - 外接 + 充电中 → 充电；外接 + 停充 → holding（直供）。
public enum StatsChargingState: Equatable, Sendable {
    /// 充电中（外接 + IsCharging）。
    case charging
    /// 外接停充（直供维持）。
    case holding
    /// 电池放电（未外接）。
    case discharging

    /// (charging, external) 折叠（桶末样本态语义见 StatsBucket.chargingState）。
    public init(charging: Bool, externalConnected: Bool) {
        guard externalConnected else {
            self = .discharging
            return
        }
        self = charging ? .charging : .holding
    }
}

/// 查询期聚合桶（方案 §2.1 Bucket 规格）：一条曲线数据点。
///
/// 聚合只发生在 StatsBucketing 纯函数（R1 P2-3b：聚合不藏 SQL，保证可测）；
/// 空桶跳过——采样断档（睡眠/App 未运行）在曲线上如实留空（UD-5，不补点）。
public struct StatsBucket: Equatable, Sendable {
    /// 桶起始时刻（对齐查询 range 下界）。
    public let start: Date
    /// 桶结束时刻（不含；start + bucketSeconds）。
    public let end: Date
    /// 桶内样本数（≥1——空桶不产出）。
    public let sampleCount: Int
    /// 电量均值（%）。
    public let avgPercent: Double
    /// 电量最小值（%）。
    public let minPercent: Int
    /// 电量最大值（%）。
    public let maxPercent: Int
    /// 温度均值（厘摄氏度，快照原值口径）。
    public let avgTempCentiC: Double
    /// 功耗均值（毫瓦；符号源 isCharging，+充 −放）。
    public let avgPowerMW: Double
    /// 最大容量均值（%；桶内全缺席 → nil——缺席机型不造数，R-6）。
    public let avgMaxCapacityPercent: Double?
    /// 桶内末样本的 (charging, external) 折叠态（M3 分色数据源）。
    public let chargingState: StatsChargingState
}

/// 分桶聚合纯函数（方案 §2.2）：样本 → StatsBucket 序列。
///
/// - 桶边界对齐 `range.lowerBound`（索引 = ⌊(ts − 下界)/bucketSeconds⌋）；
/// - 桶边界上的样本归入**后一桶**（与 SQL `ts >= 下界 AND ts < 上界` 的半开
///   区间语义一致）；
/// - 空桶跳过（不零填充——断档如实呈现）；
/// - `bucketSeconds <= 0` 或空 range → 防御性返回 []（调用方错误不入聚合）。
public enum StatsBucketing {
    public static func bucket(
        samples: [StatsSample],
        bucketSeconds: Int,
        range: Range<Date>
    ) -> [StatsBucket] {
        guard bucketSeconds > 0, range.upperBound > range.lowerBound else { return [] }
        let startSeconds = range.lowerBound.timeIntervalSince1970

        // 单桶累加器（局部 struct，聚合完成后一次性产出值类型桶）。
        struct Accumulator {
            var count = 0
            var sumPercent = 0.0
            var minPercent = Int.max
            var maxPercent = Int.min
            var sumTemp = 0.0
            var sumPower = 0.0
            var sumMaxCap = 0.0
            var maxCapCount = 0
            /// 桶内末样本（ts 最大者；chargingState 折叠源）。
            var lastSample: StatsSample?
        }

        var accumulators: [Int: Accumulator] = [:]
        for sample in samples where range.contains(sample.timestamp) {
            let offset = sample.timestamp.timeIntervalSince1970 - startSeconds
            // offset ≥ 0（range.contains 已滤）→ Double 截断即 floor。
            let index = Int(offset / Double(bucketSeconds))
            var accumulator = accumulators[index] ?? Accumulator()
            accumulator.count += 1
            accumulator.sumPercent += Double(sample.percent)
            accumulator.minPercent = min(accumulator.minPercent, sample.percent)
            accumulator.maxPercent = max(accumulator.maxPercent, sample.percent)
            accumulator.sumTemp += Double(sample.temperatureCentiC)
            accumulator.sumPower += Double(sample.powerMW)
            if let maxCap = sample.maxCapacityPercent {
                accumulator.sumMaxCap += Double(maxCap)
                accumulator.maxCapCount += 1
            }
            // 输入乱序防御：仅当样本不早于现末样本才替换（相等也替换——并列取后到者）。
            if accumulator.lastSample.map({ $0.timestamp <= sample.timestamp }) ?? true {
                accumulator.lastSample = sample
            }
            accumulators[index] = accumulator
        }

        return accumulators.keys.sorted().map { index in
            let accumulator = accumulators[index]!
            let bucketStart = startSeconds + Double(index * bucketSeconds)
            let last = accumulator.lastSample!
            return StatsBucket(
                start: Date(timeIntervalSince1970: bucketStart),
                end: Date(timeIntervalSince1970: bucketStart + Double(bucketSeconds)),
                sampleCount: accumulator.count,
                avgPercent: accumulator.sumPercent / Double(accumulator.count),
                minPercent: accumulator.minPercent,
                maxPercent: accumulator.maxPercent,
                avgTempCentiC: accumulator.sumTemp / Double(accumulator.count),
                avgPowerMW: accumulator.sumPower / Double(accumulator.count),
                avgMaxCapacityPercent: accumulator.maxCapCount > 0
                    ? accumulator.sumMaxCap / Double(accumulator.maxCapCount)
                    : nil,
                chargingState: StatsChargingState(
                    charging: last.isCharging,
                    externalConnected: last.externalConnected
                )
            )
        }
    }
}
