/// 控制器门面：策略持有 + 决策 + 应用（写后回读校验，红线 5）。
///
/// **struct 值语义定版（§0.1，非 actor）**：决策无记忆（控制键状态从 backend 读取，
/// 不由本类型记忆）、策略更新 = 换新实例；actor 的串行化收益为空集。
/// ⚠️ **单一属主不变量（评审 C-1，WP6 硬约束）**：daemon 必须以单一属主（主 actor
/// 或锁保护单实例）持有本类型，XPC handler/电源桥/CLI 一律经该属主查询与更新策略——
/// 值语义下若多处持副本，`updatePolicy` 只改一份，策略更新会**静默丢失**。
public struct LimitController: Sendable {
    public private(set) var policy: LimitPolicy

    public init(policy: LimitPolicy) {
        self.policy = policy
    }

    /// 策略更新（换新实例语义；配合单一属主不变量使用）。
    public mutating func updatePolicy(_ newPolicy: LimitPolicy) {
        policy = newPolicy
    }

    /// 纯决策（不执行）。
    public func decide(context: ChargingContext) -> ChargingAction {
        policy.decide(context: context)
    }

    /// 决策 + 应用 + 回读校验（评审 B-3 定版）。非 mutating（评审 C-2：无内部状态）。
    ///
    /// - noop → 不触碰 backend，直接返回。
    /// - enable/disable → 经 `perform(_:backend:)` 执行（写后回读校验）。
    /// - ⚠️ 若外部写者（同类工具/手动 smc）在写读之间翻转状态，verifyFailed 触发是
    ///   **期望行为**（冲突显式化），WP6 不得把它误诊为协议故障。
    public func enforce(context: ChargingContext, backend: any ChargingBackend) throws -> ChargingAction {
        let action = decide(context: context)
        try perform(action, backend: backend)
        return action
    }

    /// 执行单个动作并回读校验——所有"外部决策的动作"（如 PowerEventPolicy.sleepAction
    /// 产出的睡前停充）共用的同一校验规格（审计中-2：避免 WP6 复制校验逻辑或伪造 context）。
    ///
    /// - noop → 不触碰 backend。
    /// - enable/disable → `backend.setChargingEnabled` → **回读校验**：key 取
    ///   `backend.keyNames.first ?? backend.name`；回读自身抛错（传输故障）**原样透传**，
    ///   不得包装；值不一致 → `BackendError.verifyFailed(key:desired:actual:)`。
    @discardableResult
    public func perform(_ action: ChargingAction, backend: any ChargingBackend) throws -> ChargingAction {
        guard action != .noop else { return .noop }

        let desired = action == .enableCharging
        try backend.setChargingEnabled(desired)

        let actual = try backend.chargingEnabled()
        guard actual == desired else {
            throw BackendError.verifyFailed(
                key: backend.keyNames.first ?? backend.name,
                desired: desired,
                actual: actual
            )
        }
        return action
    }
}