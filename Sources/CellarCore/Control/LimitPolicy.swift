/// 限充策略。红线 1（60% 硬下限）的 Core 层强制点（第三层防线）。
public struct LimitPolicy: Equatable, Sendable {
    /// 充电上限，60...100。
    public let upperLimit: Int
    /// 滞回幅度，1...20；恢复阈值 = upperLimit - hysteresis。
    public let hysteresis: Int

    public static let minimumUpperLimit = 60

    /// 构造期校验。⚠️ 恢复阈值不受 60 地板约束（评审 A-2 定版）：60 地板只约束
    /// upperLimit；阈值 = upper − hys 越低越保守（越早恢复充电），方向安全。
    public init(upperLimit: Int, hysteresis: Int) throws {
        guard upperLimit >= Self.minimumUpperLimit else {
            throw LimitPolicyError.upperLimitBelowFloor(minimum: Self.minimumUpperLimit)
        }
        guard upperLimit <= 100 else {
            throw LimitPolicyError.upperLimitAboveCeiling(maximum: 100)
        }
        guard (1...20).contains(hysteresis) else {
            throw LimitPolicyError.hysteresisOutOfRange(validRange: 1...20)
        }
        self.upperLimit = upperLimit
        self.hysteresis = hysteresis
    }

    /// 恢复阈值（= upperLimit − hysteresis）。
    private var resumeThreshold: Int { upperLimit - hysteresis }

    /// 决策纯函数（§2.1 决策矩阵）：无记忆、幂等，只依赖入参。
    ///
    /// | 外接 | 控制键当前 | 电量 | 动作 |
    /// |---|---|---|---|
    /// | 否 | 任意 | 任意 | noop（电池供电，无可控制） |
    /// | 是 | 充电中 | ≥ 上限（`>=`） | disable（到达上限） |
    /// | 是 | 充电中 | < 上限 | noop（继续充） |
    /// | 是 | 停充 | < 恢复阈值（严格小于） | enable（已放电至阈值以下） |
    /// | 是 | 停充 | ≥ 恢复阈值 | noop（保持区间） |
    ///
    /// 边界定版：`percent == upperLimit` → 停充；`percent == 恢复阈值` → 不恢复。
    public func decide(context: ChargingContext) -> ChargingAction {
        guard context.externalConnected else { return .noop }
        if context.chargingEnabled {
            return context.percent >= upperLimit ? .disableCharging : .noop
        }
        return context.percent < resumeThreshold ? .enableCharging : .noop
    }
}

public enum LimitPolicyError: Error, Equatable, Sendable {
    case upperLimitBelowFloor(minimum: Int)   // < 60（红线 1）
    case upperLimitAboveCeiling(maximum: Int) // > 100
    case hysteresisOutOfRange(validRange: ClosedRange<Int>)
}