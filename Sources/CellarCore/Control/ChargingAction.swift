/// 控制器要求 backend 执行的动作。
public enum ChargingAction: Equatable, Sendable {
    case enableCharging     // 写使能
    case disableCharging    // 写停充
    case noop               // 当前态即目标态
}

/// 决策输入快照（调用方从 WP2 backend + WP3 monitor 组装）。
/// percent 由组装侧保证 0...100（WP3 解析天然满足），本类型不二次校验（评审 A-3 定版）。
public struct ChargingContext: Equatable, Sendable {
    public let percent: Int
    public let externalConnected: Bool
    public let chargingEnabled: Bool        // 控制键当前状态（读自 backend）

    public init(percent: Int, externalConnected: Bool, chargingEnabled: Bool) {
        self.percent = percent
        self.externalConnected = externalConnected
        self.chargingEnabled = chargingEnabled
    }
}