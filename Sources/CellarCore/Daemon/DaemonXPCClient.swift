import Foundation

#if canImport(XPC)
import XPC
#endif

// MARK: - CLI/App 侧 XPC 客户端（0.21.0 M2 自 DaemonXPC.swift 拆出——M1b 审查登记：
// DaemonXPC.swift 819 行超 800 行硬上限；本文件为**纯移动零语义变更**，wire 面
// （DaemonXPC/DaemonStatus/键常量）仍归 DaemonXPC.swift 单一真相，两文件同 target
// 同模块，拆分无可见性影响。）

#if canImport(XPC)
/// CLI 侧客户端：raw XPC + 异步回包 + 信号量 5 秒等待（评审 E-4——
/// `send_message_with_reply_sync` 无超时参数，超时必须自行实现）。
public struct DaemonXPCClient: Sendable {
    /// 保持 throws 契约（规格 §2）。⚠️ Swift 导入下 `xpc_connection_create_mach_service`
    /// 返回非可选句柄——连接"建立失败"不可观测，实际失败形态（daemon 未运行）在
    /// exchange 中经连接无效事件暴露为 .connectionFailed。
    public init() throws {}

    public func getStatus() throws -> DaemonStatus {
        try exchange(cmd: "getStatus")
    }

    /// ⚠️ 60 地板双重复核的一侧：CLI 侧已用 LimitPolicy 构造校验；daemon 侧 setLimits 再核验一次。
    /// 负数经 clamping 收敛为 0（不会是合法策略，daemon 侧报地板错误；防 UInt64 转换崩溃）。
    /// autoDischarge：nil = 不发键（daemon 缺席保持——非开关调用点一律传 nil，
    /// 防 60s 轮询窗口内用旧值覆写 CLI 刚改的限值）。
    public func setLimits(
        upperLimit: Int, hysteresis: Int, autoDischarge: Bool? = nil
    ) throws -> DaemonStatus {
        try exchange(
            cmd: "setLimits",
            upper: UInt64(clamping: upperLimit),
            hysteresis: UInt64(clamping: hysteresis),
            auto: autoDischarge.map { $0 ? 1 : 0 }
        )
    }

    public func disable() throws -> DaemonStatus {
        try exchange(cmd: "disable")
    }

    public func enable() throws -> DaemonStatus {
        try exchange(cmd: "enable")
    }

    /// 一次性动作：充满一次（WP2）。前置（外接 && mode=active）不满足 → daemonError
    /// 原文；动作已在轨 → 幂等回当前状态。0.21.0 §1.3：27 编排开关关 → 拒绝原文
    ///（「系统限充执行已停用——请在通用页开启后使用」）；开 → daemon 置 pending(100)
    ///（set 路径复活——App 消费执行）。
    public func fullOnce() throws -> DaemonStatus {
        try exchange(cmd: "fullOnce")
    }

    /// 0.21.0 §1.3：恢复限充（27 复活配套——daemon 置 pending(policy.upperLimit)
    /// 交 App set 回；R3-P3-1 编排开关关 → 拒绝原文）。
    public func restoreChargeLimit() throws -> DaemonStatus {
        try exchange(cmd: NativeLimitSet.restoreCommand)
    }

    /// 取消当前一次性动作（无动作时幂等成功，回当前状态）。
    public func cancelAction() throws -> DaemonStatus {
        try exchange(cmd: "cancelAction")
    }

    /// WP2'：放电到上限（无参数——目标 = daemon 当前策略上限启动时快照）。
    /// 前置（外接 && mode=active && percent > 目标 && 能力在位）不满足 → daemonError
    /// 原文；动作已在轨 → 幂等回当前状态。
    public func dischargeToLimit() throws -> DaemonStatus {
        try exchange(cmd: "dischargeToLimit")
    }

    /// WP3：开始校准（手动触发四相状态机；无参数——相位序列由 daemon 执行）。
    /// 前置拒绝（mode/外接/能力）→ daemonError 原文；校准已在轨 → 幂等回当前状态；
    /// 其他动作在轨 → actionOccupied 拒绝原文。
    public func startCalibration() throws -> DaemonStatus {
        try exchange(cmd: "startCalibration")
    }

    /// WP3：取消校准（独立命令臂；幂等——无动作亦成功回当前状态）。
    public func cancelCalibration() throws -> DaemonStatus {
        try exchange(cmd: "cancelCalibration")
    }

    /// Phase 5 v1.1：设置风扇策略（可选字段缺席 = daemon 保持现值；策略值域
    /// 0/2/3 非法值 daemonError 原文回传）。**不改 mode**（与
    /// setLimits 的「更新即切 active」语义正交）；boost 期立即按新配置重算重写。
    public func setFan(_ fan: FanWire) throws -> DaemonStatus {
        try exchange(cmd: FanWireKeys.command, upper: 0, hysteresis: 0, auto: nil, fan: fan)
    }

    /// Phase 5 v1.4：设置校准调度（可选字段缺席 = daemon 保持现值；**不改 mode**）。
    /// 旧 daemon → 「未知命令」daemonError（App detectStaleBeforeReject 升级提示
    /// 既有闭环，UD-7）。
    public func setCalibrationSchedule(_ schedule: CalibrationScheduleWire) throws -> DaemonStatus {
        try exchange(
            cmd: CalibrationScheduleWireKeys.command, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: schedule
        )
    }

    /// Phase 5 v1.5：设置充电热暂停策略（可选字段缺席 = daemon 保持现值；**不改
    /// mode**；值域 35-45°C / 滞回 1-8°C，保护不可被配置关闭——UD-2 值域钳制）。
    /// 旧 daemon → 「未知命令」daemonError（detectStaleBeforeReject 升级提示既有
    /// 闭环，R-4）。
    public func setThermal(_ thermal: ThermalWire) throws -> DaemonStatus {
        try exchange(
            cmd: ThermalWireKeys.command, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: nil, thermal: thermal
        )
    }

    /// Phase 5 v1.6：设置充电日程（配置 JSON 字符串键——**协议首个字符串键**，UD-6；
    /// daemon 侧三级校验长度/JSON/validated，任一失败 → daemonError 原文；**不改
    /// mode、不取消在轨**，成功即 tick——命中窗口条目 ≤1 tick 生效）。旧 daemon →
    /// 「未知命令」daemonError（App detectStaleBeforeReject 升级提示既有闭环，R-7）。
    public func setChargeSchedule(_ json: String) throws -> DaemonStatus {
        try exchange(
            cmd: ChargeScheduleWireKeys.command, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: nil, thermal: nil,
            schedule: ChargeScheduleWire(scheduleJson: json)
        )
    }

    /// Phase 5 v1.8：设置 MagSafe LED 模式（0=跟随系统 / 1=常灭 / 3=常绿 / 4=常琥珀；
    /// **不改 mode**；disabled 期 daemon 仅存配置不写灯，enable 后 tick 重申）。
    /// 旧 daemon → 「未知命令」daemonError（App detectStaleBeforeReject 升级提示
    /// 既有闭环）。
    public func setMagSafeLed(_ mode: UInt8) throws -> DaemonStatus {
        try exchange(
            cmd: MagSafeLED.commandName, upper: 0, hysteresis: 0,
            auto: nil, fan: nil, calSched: nil, thermal: nil,
            magSafeLedMode: UInt64(mode)
        )
    }

    /// v0.19.20：设置充电编排开关（UINT64 0/1 键型照既有开关统一，R2 P3；**不改
    /// mode**）。旧 daemon → 「未知命令」daemonError（App detectStaleBeforeReject
    /// 升级提示既有闭环）。
    public func setOrchestration(_ enabled: Bool) throws -> DaemonStatus {
        try exchange(
            cmd: OrchestrationWireKeys.command, upper: 0, hysteresis: 0,
            orchestrationEnabled: enabled ? 1 : 0
        )
    }

    /// 0.21.0 §2.4：CHIE 迟滞备用通道开关（UINT64 0/1 键型照编排开关统一；**不改
    /// mode**；daemon 侧 persist + 即时 tick——挂载/退出 ≤1 tick 评估，回读单一真相）。
    /// 旧 daemon → 「未知命令」daemonError（App detectStaleBeforeReject 升级提示
    /// 既有闭环）。
    public func setChHysteresisEnabled(_ enabled: Bool) throws -> DaemonStatus {
        try exchange(
            cmd: CHHysteresisWireKeys.command, upper: 0, hysteresis: 0,
            chHysteresisEnabled: enabled ? 1 : 0
        )
    }

    /// v0.19.20：编排执行回报（App ShortcutRunner 消费 pending 后调用；token 幂等
    /// ——不匹配静默丢弃；detail 仅失败时携带）。鉴权同变更类命令门（R1 P1-4）：
    /// 非管理员回报被拒 → pending 未清 → TTL 过期后 daemon 重发（R2 P1 降级链）。
    public func reportOrchestration(token: String, ok: Bool, detail: String?) throws -> DaemonStatus {
        try exchange(
            cmd: OrchestrationWireKeys.reportCommand, upper: 0, hysteresis: 0,
            orchestrationReport: OrchestrationReportWire(token: token, ok: ok ? 1 : 0, detail: detail)
        )
    }

    // MARK: - 内部

    /// 一次请求-回包交换：发消息 → 等回包（≤5s）→ 解析。
    /// - 连接无效事件（daemon 未运行/未安装）→ .connectionFailed
    /// - 超时无回包 → .timeout
    /// - ok=false → .daemonError(原文)
    private func exchange(
        cmd: String, upper: UInt64 = 0, hysteresis: UInt64 = 0, auto: UInt64? = nil,
        fan: FanWire? = nil, calSched: CalibrationScheduleWire? = nil,
        thermal: ThermalWire? = nil, schedule: ChargeScheduleWire? = nil,
        magSafeLedMode: UInt64? = nil, orchestrationEnabled: UInt64? = nil,
        orchestrationReport: OrchestrationReportWire? = nil,
        chHysteresisEnabled: UInt64? = nil
    ) throws -> DaemonStatus {
        // Swift 导入下连接句柄非可选（失败经事件暴露，见 init 注释）。
        // ⚠️ xpc 对象引用计数由 ARC 自动管理：不得手动 xpc_release（双重释放崩溃）。
        let connection = xpc_connection_create_mach_service(DaemonXPC.machServiceName, nil, 0)
        let message = DaemonXPC.makeMessage(
            cmd: cmd, upper: upper, hysteresis: hysteresis, auto: auto,
            fan: fan, calSched: calSched, thermal: thermal, schedule: schedule,
            magSafeLedMode: magSafeLedMode, orchestrationEnabled: orchestrationEnabled,
            orchestrationReport: orchestrationReport, chHysteresisEnabled: chHysteresisEnabled
        )
        let waiter = ReplyWaiter()

        xpc_connection_set_event_handler(connection) { object in
            waiter.receive(object)
        }
        xpc_connection_set_target_queue(connection, DispatchQueue.global(qos: .userInitiated))
        xpc_connection_resume(connection)
        xpc_connection_send_message(connection, message)

        // 异步回包 + 信号量 5 秒超时（reply_sync 无超时参数，评审 E-4）。
        let outcome = waiter.wait(timeout: .now() + DaemonXPC.replyTimeoutSeconds)

        // 收包/超时/错误事件齐备后关闭连接（连接与消息对象随作用域由 ARC 回收）。
        xpc_connection_cancel(connection)

        switch outcome {
        case .timedOut:
            throw DaemonClientError.timeout
        case .invalidPeer:
            throw DaemonClientError.connectionFailed
        case .reply(let object):
            return try Self.parse(reply: object)
        }
    }

    /// 解析回包字典（对象随参数作用域由 ARC 回收，勿手动 release）。
    private static func parse(reply object: xpc_object_t) throws -> DaemonStatus {
        guard xpc_get_type(object) == XPC_TYPE_DICTIONARY else {
            throw DaemonClientError.connectionFailed
        }
        let ok = xpc_dictionary_get_bool(object, DaemonXPC.okKey)
        if ok {
            guard let json = xpc_dictionary_get_string(object, DaemonXPC.statusKey) else {
                throw DaemonClientError.daemonError("daemon 回包缺少状态载荷")
            }
            return try DaemonXPC.decodeStatus(String(cString: json))
        }
        if let error = xpc_dictionary_get_string(object, DaemonXPC.errorKey) {
            throw DaemonClientError.daemonError(String(cString: error))
        }
        throw DaemonClientError.daemonError("daemon 返回未知错误")
    }
}

/// 回包等待盒：事件处理器（全局队列）写入、等待方（调用线程）读取。
///
/// ⚠️ 生命周期：handler 参数对象为借用（+0），跨回调持有依赖 Swift ARC——
/// 存入 `state` 时编译器自动 retain，读取/离开作用域时自动 release；
/// 本类型不做任何手动 xpc_retain/xpc_release。
private final class ReplyWaiter: @unchecked Sendable {
    private enum State {
        case pending
        case received(xpc_object_t)
        case invalidPeer
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var state: State = .pending

    /// 事件回调（可被多次调用；首个有效结果生效，后续事件被 ARC 回收）。
    func receive(_ object: xpc_object_t) {
        lock.lock()
        if case .pending = state {
            if xpc_get_type(object) == XPC_TYPE_ERROR {
                // 连接无效（daemon 未运行等）：错误常量对象不存储（immortal）。
                state = .invalidPeer
            } else {
                state = .received(object)   // 存储时 ARC 自动 retain（跨回调安全）
            }
        }
        lock.unlock()
        semaphore.signal()
    }

    /// 等待回包（超时返回 timedOut）。返回 .reply 时对象由 .received 持有，
    /// 调用方使用期间保持存活（ARC），离开作用域自动回收。
    func wait(timeout: DispatchTime) -> Outcome {
        _ = semaphore.wait(timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .pending:
            return .timedOut
        case .received(let object):
            return .reply(object)
        case .invalidPeer:
            return .invalidPeer
        }
    }

    enum Outcome {
        case timedOut
        case invalidPeer
        case reply(xpc_object_t)
    }
}
#endif
