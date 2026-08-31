/// 电源事件词表（WP6 触发契约，§0.5 定版）：决策的触发来源收敛于此词表，
/// WP6 不允许在词表外私加触发路径。
public enum PowerEvent: Equatable, Sendable {
    case powerConnected
    case powerDisconnected
    case batteryLevelChanged(percent: Int)  // 电量整数百分点变化（WP6 周期采样发出）
    case periodicTick                        // 周期心跳兜底（WP6 定时器发出）
    case systemSleep, systemWake
    case policyChanged                       // 用户改策略（XPC setLimits）
}

public enum PowerEventPolicy {
    /// 所有事件一律 true——任何事件后都必须全量重评估（评审 A-1：事件即触发契约）。
    public static func requiresReevaluation(on event: PowerEvent) -> Bool {
        true
    }

    /// 睡眠动作（§0.3 定版）：外接且当前允许充电 → 停充；否则 noop。
    /// 理由：CHTE 是开关键不是限充键，睡眠期间 daemon 不运行、无人守上限，
    /// 保持使能会无看管越过上限；睡眠耗电极低，停充无代价。
    /// ⚠️ 执行约束（评审 B-2，WP6 遵守）：该停充动作与 enforce 同规格——写后回读校验，
    /// 不一致按 verifyFailed 上报 os_log 告警（睡眠通知同步等待回复，不允许静默失败）。
    public static func sleepAction(externalConnected: Bool, currentChargingEnabled: Bool) -> ChargingAction {
        externalConnected && currentChargingEnabled ? .disableCharging : .noop
    }
}