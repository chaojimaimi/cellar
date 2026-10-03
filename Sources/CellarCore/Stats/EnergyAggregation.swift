import Foundation

/// 相邻累加器对分类（0.22.0 §2.3 共享分类器）：EnergyAggregation 聚合与
/// StatsSampler 仪器化日志**共用同一真相**（两处独立实现必漂移，评审 P2-3）。
///
/// 判据（SMC-NOTES §11.7→§11.8 活体捕获定谳）：计数 ≈ 样本序号——**计数回退
/// = 累加器复位**的独立判据（复位真实发生过：29.4 万 → 3.6 万）。
public enum AccumulatorPairClass: Equatable, Sendable {
    /// 正常能量对（计数单调不减 ∧ acc 朝正常方向变化——系统通道递增 /
    /// 放电通道递减）。
    case normal
    /// 复位对（计数回退；系统通道 acc 下降同判）——剔除该对能量 + 以对端
    /// 重建基线 + 计入复位计数（该区间能量低估，UI 脚注如实呈现）。
    case reset
    /// 一端字段缺席（v1 旧行 / 键缺席机型 / 复位后首样本）——该对不计，
    /// 作基线重建点。
    case nullEnd
    /// 放电通道 acc 递增（充电窗语义未定谳，观察期实验④）——跳过不计，
    /// 不猜符号（宁缺毋假）；如实计 unknownDischargeSpans。
    case increasing
    /// 等值对（Δacc = 0——零贡献，非异常）。
    case equal
}

/// 能耗聚合桶（0.22.0 §3.1）：一条柱图数据点（系统/放电双通道独立累计）。
/// 空桶（零贡献）跳过——断档/无累加器键区间如实留空（UD-5 沿袭）。
public struct EnergyBucket: Equatable, Sendable {
    /// 桶起始时刻（对齐查询 range 下界，StatsBucketing 同构）。
    public let start: Date
    /// 系统耗电（mWh；Δacc × systemK / 3600）。
    public let systemMWh: Double
    /// 电池放电（mWh；|Δacc| × dischargeK / 3600）。
    public let dischargeMWh: Double

    public init(start: Date, systemMWh: Double, dischargeMWh: Double) {
        self.start = start
        self.systemMWh = systemMWh
        self.dischargeMWh = dischargeMWh
    }
}

/// 能耗聚合摘要（0.22.0 §3.1）：桶序列 + 诚实性三计数（脚注管线可达，复核 P3-1）。
public struct EnergySummary: Equatable, Sendable {
    /// 非零能量桶（ts 升序；空桶跳过）。
    public let buckets: [EnergyBucket]
    /// 系统通道复位对数（该日能量低估——如实标注）。
    public let resets: Int
    /// 放电通道复位对数（计数回退判据 + |Δ| 合理性上限双防护命中合计）。
    public let dischargeResets: Int
    /// 放电通道递增对数（充电窗语义未定谳，跳过未计的对数）。
    public let unknownDischargeSpans: Int

    public init(
        buckets: [EnergyBucket],
        resets: Int,
        dischargeResets: Int,
        unknownDischargeSpans: Int
    ) {
        self.buckets = buckets
        self.resets = resets
        self.dischargeResets = dischargeResets
        self.unknownDischargeSpans = unknownDischargeSpans
    }
}

/// 能耗差分聚合纯函数（0.22.0 §3.1；照 StatsBucketing 形态——聚合不藏 SQL，
/// 输入 = ts 升序原始样本序列，输出 = EnergySummary）。
///
/// 逐对差分规则（相邻两样本为一对，两通道独立）：
/// - 系统通道：两端齐备 ∧ 计数单调不减 ∧ acc 非降 → Δacc × systemK / 3600 mWh
///   计入 t1 所在桶；计数回退或 acc 下降 → 复位对（剔除 + resets += 1）。
/// - 放电通道：**先复位防护**——计数回退 → 复位；计数单调但 |Δacc| 超合理性
///   上限（对时长 × 200 W 折算）→ 亦判复位（长间隙后计数反超的兜底）；防护
///   过 → acc 下降才计 |Δ| × dischargeK / 3600；递增对跳过（计
///   unknownDischargeSpans）；等值对零贡献。
/// - 一端 NULL → 该对不计（基线重建点——后续对从该样本继续差分）。
/// - **间隙不插值**（UD-5 沿袭）：App 未运行期间累加器照常积分，间隙对的
///   ΔAcc 是固件真实记录的能量，如实计入；仅复位破坏连续性（由复位对处理）。
public enum EnergyAggregation {
    /// 相邻累加器对分类（共享判据——采样器复位检测日志同源）。
    ///
    /// `accDecreasingIsNormal`：false = 系统通道（递增为正常，acc 下降判复位）；
    /// true = 放电通道（递减为正常，acc 递增判 `.increasing` 未定谳态）。
    /// 任一端 acc/count 缺席 → `.nullEnd`；计数回退优先判 `.reset`。
    public static func classifyPair(
        acc0: Int?, count0: Int?, acc1: Int?, count1: Int?,
        accDecreasingIsNormal: Bool
    ) -> AccumulatorPairClass {
        guard let acc0, let count0, let acc1, let count1 else { return .nullEnd }
        if count1 < count0 { return .reset }
        if acc1 == acc0 { return .equal }
        let decreased = acc1 < acc0
        if accDecreasingIsNormal {
            return decreased ? .normal : .increasing
        }
        return decreased ? .reset : .normal
    }

    /// 聚合入口（`bucketSeconds <= 0` 或空 range → 防御性空摘要；输入要求 ts
    /// 升序——StatsStore.rawRows 既有语义）。
    public static func aggregate(
        samples: [StatsSample],
        bucketSeconds: Int,
        range: Range<Date>
    ) -> EnergySummary {
        guard bucketSeconds > 0, range.upperBound > range.lowerBound else {
            return EnergySummary(buckets: [], resets: 0, dischargeResets: 0, unknownDischargeSpans: 0)
        }
        let startSeconds = range.lowerBound.timeIntervalSince1970

        struct BucketAccumulator {
            var systemMWh = 0.0
            var dischargeMWh = 0.0
        }
        var accumulators: [Int: BucketAccumulator] = [:]
        var resets = 0
        var dischargeResets = 0
        var unknownDischargeSpans = 0

        // 相邻对差分（zip 平移——前值即上一原始行；v1 旧行 NULL 端对自然成为
        // 基线重建点，后续对从该样本继续）。
        for pair in zip(samples, samples.dropFirst()) {
            let t0 = pair.0, t1 = pair.1
            // 桶界按 t1（当前样本）归属（方案 §3.1「计入 t1 所在桶」）。
            func bucketIndex(_ date: Date) -> Int? {
                let offset = date.timeIntervalSince1970 - startSeconds
                guard offset >= 0 else { return nil }
                return Int(offset / Double(bucketSeconds))
            }
            func accumulate(_ modify: (inout BucketAccumulator) -> Void) {
                guard let index = bucketIndex(t1.timestamp) else { return }
                var bucket = accumulators[index] ?? BucketAccumulator()
                modify(&bucket)
                accumulators[index] = bucket
            }

            // 系统通道（K=1.101 递增）。
            switch classifyPair(
                acc0: t0.accSystemLoadMWs, count0: t0.accSystemLoadCount,
                acc1: t1.accSystemLoadMWs, count1: t1.accSystemLoadCount,
                accDecreasingIsNormal: false
            ) {
            case .normal:
                let deltaMWh = Double(t1.accSystemLoadMWs! - t0.accSystemLoadMWs!)
                    * EnergyScale.systemK / 3600
                accumulate { $0.systemMWh += deltaMWh }
            case .reset:
                resets += 1
            case .nullEnd, .equal, .increasing:
                break   // 基线重建 / 零贡献 / 系统通道无此分类
            }

            // 放电通道（K≈0.825 递减；先复位防护——评审 P1-1）。
            switch classifyPair(
                acc0: t0.accBatteryDischarge, count0: t0.accBatteryDischargeCount,
                acc1: t1.accBatteryDischarge, count1: t1.accBatteryDischargeCount,
                accDecreasingIsNormal: true
            ) {
            case .normal:
                let delta = abs(Double(t1.accBatteryDischarge! - t0.accBatteryDischarge!))
                let duration = t1.timestamp.timeIntervalSince(t0.timestamp)
                // 合理性上限：|Δacc|(mW·s) > 对时长(s) × 200 W × 1000(mW/W) →
                // 判复位（长间隙 + 中途复位、计数反超不可检形态的能量兜底）。
                if delta > duration * EnergyScale.dischargeSanityCapWatts * 1000 {
                    dischargeResets += 1
                } else {
                    let deltaMWh = delta * EnergyScale.dischargeK / 3600
                    accumulate { $0.dischargeMWh += deltaMWh }
                }
            case .reset:
                dischargeResets += 1
            case .increasing:
                unknownDischargeSpans += 1   // 充电窗语义未定谳——如实计数不猜符号
            case .nullEnd, .equal:
                break   // 基线重建 / 零贡献
            }
        }

        // 空桶跳过（零贡献桶不产出——柱图断档留空，UD-5）。
        let buckets = accumulators.keys.sorted().compactMap { index -> EnergyBucket? in
            let bucket = accumulators[index]!
            guard bucket.systemMWh > 0 || bucket.dischargeMWh > 0 else { return nil }
            return EnergyBucket(
                start: Date(timeIntervalSince1970: startSeconds + Double(index * bucketSeconds)),
                systemMWh: bucket.systemMWh,
                dischargeMWh: bucket.dischargeMWh
            )
        }
        return EnergySummary(
            buckets: buckets,
            resets: resets,
            dischargeResets: dischargeResets,
            unknownDischargeSpans: unknownDischargeSpans
        )
    }
}
