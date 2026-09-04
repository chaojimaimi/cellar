import Foundation

// MARK: - 时间估算（Phase 5 v1.2 §3.6：满电还需 / 预计可用，诚实纪律 SR-4）

/// 时间估算采样点（App 侧遥测样本环的元素：时刻 + 电量百分比）。
public struct TimeSample: Equatable, Sendable {
    public let date: Date
    public let percent: Int

    public init(date: Date, percent: Int) {
        self.date = date
        self.percent = percent
    }
}

/// 当前电源段（估算法则的分支依据；与 PowerFlowView 的三态映射同源——
/// ext∧charging → charging / ext∧¬charging → holding / ¬ext → battery）。
public enum TimeEstimateState: Equatable, Sendable {
    /// 外接 + 充电中：满电还需 = 至充限上沿（upperLimit，非 100%——产品语义）。
    case charging
    /// 外接 + 停充：适配器直供无时间语义。
    case holding
    /// 电池供电：预计可用 = 放电斜率外推。
    case battery
}

/// 时间估算纯函数（样本集 → 展示值分钟数或 nil），展示规则全实现（方案 §3.6）：
/// - 新鲜度截断：距最新样本 > 15 分钟的点一律剔除——遥测停止/窗口长期关闭后
///   等价「环逻辑清空重来」，杜绝首尾跨度击穿可信窗判定（R1 P1-3）；
/// - 连续段校验：以最新样本为锚自后向前走查，时间间隙 > 60s 或相邻样本电量
///   跳变 > 2% 即断段，只保留含最新样本的末段参与拟合——电源态翻转清环由
///   调用方执行，此处为第二道防线：未清环的异态混合样本不进入斜率（R1 P1-3）；
/// - 最小二乘斜率（%每小时；O(n) 单遍，抗首尾抖动）；
/// - 有效窗 < 5 分钟 或 窗内 |Δpercent| < 1 → nil（斜率不可信，诚实显示——
///   不显「测量中」避免常驻噪声，R-4）；
/// - charging → (upperLimit − percent)/slope×60，slope ≤ 0 或 percent ≥ 上限 →
///   nil；battery → percent/|slope|×60，slope ≥ 0 → nil；holding → nil；
/// - 结果钳制 [1 分钟, 48 小时]（异常外插不穿透显示）。
public enum TimeEstimator {
    /// 新鲜度窗：距最新样本超过该值的点剔除（秒）。
    public static let freshnessWindow: TimeInterval = 15 * 60
    /// 连续段间隙阈值：相邻样本时间间隔超过即视为采样中断（秒）。遥测名义
    /// 间隔 1s，60s 量级中断必非正常采样——跨 gap 重开后前段不参与拟合。
    public static let segmentGapThreshold: TimeInterval = 60
    /// 相邻样本电量跳变断段阈值（百分点）：真实充/放电速率远小于 2%/s，
    /// 秒级跳变即异态（如未清环的电源态翻转边界），按段断裂隔离。
    public static let percentJumpThreshold = 2
    /// 有效窗下限（秒）：窗长不足斜率不可信。
    public static let minimumWindow: TimeInterval = 5 * 60
    /// 窗内总变化下限（百分点）：|Δ| < 1 视作无变化（斜率不可信）。
    public static let minimumDeltaPercent = 1.0
    /// 结果钳制（分钟）：下限 1 分钟 / 上限 48 小时。
    public static let clampMinutes: ClosedRange<Int> = 1...(48 * 60)

    /// 估算满电还需 / 预计可用（分钟数；不可信或不适用 → nil）。
    public static func estimateMinutes(
        samples: [TimeSample],
        state: TimeEstimateState,
        upperLimit: Int
    ) -> Int? {
        guard let anchor = samples.last else { return nil }
        // ① 新鲜度截断（锚 = 最新样本；旧点不参与任何后续步骤）。
        let fresh = samples.filter {
            anchor.date.timeIntervalSince($0.date) <= freshnessWindow
        }
        guard let latest = fresh.last else { return nil }
        // ② 连续段校验：自后向前收集末段（时间间隙 / 电量跳变即断段）。
        var segment: [TimeSample] = [latest]
        var index = fresh.count - 1
        while index > 0 {
            let current = fresh[index]
            let previous = fresh[index - 1]
            let gap = current.date.timeIntervalSince(previous.date)
            guard gap <= segmentGapThreshold,
                  abs(current.percent - previous.percent) <= percentJumpThreshold else {
                break
            }
            segment.append(previous)
            index -= 1
        }
        segment.reverse()
        guard let first = segment.first, segment.count >= 2 else { return nil }
        // ③ 可信窗门槛（诚实纪律：不可信不显示）。
        let windowSeconds = latest.date.timeIntervalSince(first.date)
        guard windowSeconds >= minimumWindow else { return nil }
        let deltaPercent = Double(latest.percent - first.percent)
        guard abs(deltaPercent) >= minimumDeltaPercent else { return nil }
        // ④ 最小二乘斜率（%每小时；x = 距段首小时数，y = 电量）。
        let meanX = segment.reduce(0.0) {
            $0 + $1.date.timeIntervalSince(first.date) / 3600
        } / Double(segment.count)
        let meanY = Double(segment.reduce(0) { $0 + $1.percent }) / Double(segment.count)
        var numerator = 0.0
        var denominator = 0.0
        for sample in segment {
            let x = sample.date.timeIntervalSince(first.date) / 3600 - meanX
            let y = Double(sample.percent) - meanY
            numerator += x * y
            denominator += x * x
        }
        guard denominator > 0 else { return nil }
        let slopePercentPerHour = numerator / denominator
        // ⑤ 按电源段分支（展示规则；percent = 最新样本值）。
        let minutes: Double
        switch state {
        case .holding:
            return nil
        case .charging:
            guard slopePercentPerHour > 0, latest.percent < upperLimit else { return nil }
            minutes = Double(upperLimit - latest.percent) / slopePercentPerHour * 60
        case .battery:
            guard slopePercentPerHour < 0 else { return nil }
            minutes = Double(latest.percent) / abs(slopePercentPerHour) * 60
        }
        // ⑥ 钳制（异常外插不穿透显示）。
        return min(max(Int(minutes.rounded()), clampMinutes.lowerBound), clampMinutes.upperBound)
    }
}