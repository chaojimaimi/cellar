import Foundation

// MARK: - WP3 自动校准（手动触发版）—— CellarCore 纯函数/纯值层（方案 §2.1）

/// 校准动作族常量与相位转移纯函数。
///
/// 与 fullOnce/dischargeToLimit 同构分层：daemon 只做副作用（写 CHTE/CHIE、
/// 删文件、日志），全部语义决策经本文件转移——CellarCoreCheck 矩阵穷举钉死的
/// 转移与 daemon 运行时同源。
public enum Calibration {
    /// 动作类型字面量（action.json kind；ActionStore 白名单成员）。
    public static let kind = "calibration"
    /// 相位超时常量：充电满 6h（10%→100% 实测 ~3-5h，含全充窗口）、静置 2h、
    /// 放电 12h（80%→10% 负载放电 ~3-5h，睡眠掉电慢故放宽）、整体防御兜底 24h
    /// （deadline 仅作 hold 相 24h 整体兜底判据，相位决策不用——相位各有超时）。
    public static let chargeFullTimeout: TimeInterval = 6 * 3600
    public static let holdDuration: TimeInterval = 2 * 3600
    public static let dischargeTimeout: TimeInterval = 12 * 3600
    public static let totalDeadline: TimeInterval = 24 * 3600
    /// 放电目标（红线注记：限充下限 60% 约束的是 upperLimit 设定值——LimitPolicy
    /// 构造校验——而非校准放电目标；10% 为业界校准标准下限，BMS 自保护兜底）。
    public static let dischargeTargetPercent = 10
    /// 放电相温度中止（单点，与 Discharge.temperatureLimitC 同值不同义独立演化）。
    public static let temperatureLimitC = 40.0
    /// CHIE 保活失败上限（复用轨道 keepAliveFailures，判例同 dischargeToLimit）。
    public static let keepAliveFailureLimit = 3

    /// 相位（持久化原始值；App 侧同源映射展示词）。
    public enum Phase: String, Sendable {
        case chargeFull, hold, discharge
    }
}

/// 校准 lastAction 字面量族（wire 格式永不本地化）。**无 calibration:start**——
/// 启动相即 `calibration:chargeFull` 持续字面量（sleepNow 跳过分支直写相位字面量，
/// R1 P2-2 钉死）。
public enum CalibrationLiteral {
    /// 相位持续字面量（每 tick 返回当前相位；相位转移通知经 App 端 notificationEvents
    /// 转移检测，不锁存）。
    public static func phase(_ p: Calibration.Phase) -> String { "calibration:\(p.rawValue)" }
    public static func done() -> String { "calibration:done" }
    public static func cancel() -> String { "calibration:cancel" }
    public static func timeout() -> String { "calibration:timeout" }
    public static func safety() -> String { "calibration:safety" }
    public static func cancelCrashRecovery() -> String { "calibration:cancel(crash-recovery)" }

    /// 校准中止原因（abort 输出 reason 字段；daemon 日志与字面量分流的依据）。
    public enum AbortReason {
        /// 充电/静置相物理拔电。
        public static let unplug = "unplugInChargePhase"
        /// 相位超时（含 hold 相整体兜底超时）。
        public static let timeout = "timeout"
        /// 放电相温度 ≥40°C。
        public static let temperature = "temperature"
        /// CHIE 保活连续失败 ≥3（外部恢复充电无法压制）。
        public static let keepAliveExhausted = "extRestoredExhausted"
    }
}

/// 校准启动前置拒绝（daemon 上抛 → XPC errorReply 原文；description = 用户可读文案）。
public enum CalibrationStartRejection: Error, Equatable, Sendable, CustomStringConvertible {
    /// mode != "active"（含 disabled）。
    case modeNotActive
    /// 未确认外接电源（未外接或外接状态未知——快照失败且无上次已知值）。
    case noExternalPower
    /// 其他动作在轨（互斥双向：校准启动前必须先完成/取消在轨动作，方案 §3.9）。
    case actionOccupied
    /// 能力不可用（capabilities 缺 calibration——App 已按能力隐藏，本 case 为
    /// XPC 纵深防御）。
    case capabilityUnavailable
    /// action.json 写入失败（动作不启动——持久化是动作存活的前提）。
    case persistenceFailed

    public var message: String {
        switch self {
        case .modeNotActive: return "「电池校准」需要限充处于启用状态（当前已停用）"
        case .noExternalPower: return "「电池校准」需要连接外接电源"
        case .actionOccupied: return "有其他动作进行中，请先完成或取消"
        case .capabilityUnavailable: return "当前机型不支持校准功能"
        case .persistenceFailed: return "「电池校准」启动失败：无法写入动作文件"
        }
    }

    public var description: String { message }
}

/// 校准启动前置（方案 §2.1）：mode active ∧ 外接 ∧ 无在轨动作 ∧ 能力在位。
/// externalConnected 为 nil（快照失败且无上次已知值）→ 拒绝（不无据启动）。
public func calibrationStartPrecondition(
    mode: String,
    externalConnected: Bool?,
    actionActive: Bool,
    capabilityPresent: Bool
) -> CalibrationStartRejection? {
    guard mode == "active" else { return .modeNotActive }
    guard externalConnected == true else { return .noExternalPower }
    guard !actionActive else { return .actionOccupied }
    guard capabilityPresent else { return .capabilityUnavailable }
    return nil
}

// MARK: - 相位转移（方案 §2.1 判定次序，逐条短路）

/// 校准 tick 输入（daemon 锁内组装）。**监护缺失不经本转移**——backend/采样早退
/// 路径计数（方案 §2.2 门控扩展：noteMonitoringLoss/terminateMonitoringLoss 两轨道
/// 方法按 kind/phase 门控）。
public struct CalibrationTickInput: Equatable, Sendable {
    public let percent: Int
    public let temperatureC: Double
    public let externalConnected: Bool
    public let isCharging: Bool
    public let fullyCharged: Bool?
    public let now: Date
    /// 内存相位（轨道 action.phase 解析；nil/未知 → 防御按 chargeFull 处理）。
    public let phase: Calibration.Phase?
    /// 相位起始时刻（advance 时由 daemon 更新；nil 防御视作未超时）。
    public let phaseStartedAt: Date?
    /// 整体兜底 deadline（action.deadline = start+24h；仅 hold 相使用，相位决策不用）。
    public let deadline: Date
    /// chargeFull 相完成判定去抖计数（daemon 持有轨道计数，经结果回写）。
    public let debounceTicks: Int
    /// CHIE 保活失败计数（daemon 持有轨道计数，经结果回写）。
    public let keepAliveFailures: Int
    /// CHIE 保活状态（仅 discharge 相有效：daemon 先读改写再传入）。
    public let chieStatus: DischargeKeepAliveStatus?

    public init(
        percent: Int,
        temperatureC: Double,
        externalConnected: Bool,
        isCharging: Bool,
        fullyCharged: Bool?,
        now: Date,
        phase: Calibration.Phase?,
        phaseStartedAt: Date?,
        deadline: Date,
        debounceTicks: Int,
        keepAliveFailures: Int,
        chieStatus: DischargeKeepAliveStatus?
    ) {
        self.percent = percent
        self.temperatureC = temperatureC
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.fullyCharged = fullyCharged
        self.now = now
        self.phase = phase
        self.phaseStartedAt = phaseStartedAt
        self.deadline = deadline
        self.debounceTicks = debounceTicks
        self.keepAliveFailures = keepAliveFailures
        self.chieStatus = chieStatus
    }
}

/// 校准 tick 输出（daemon 依此执行副作用：落盘/写 CHTE/写 CHIE/删文件/字面量）。
public enum CalibrationTickOutput: Equatable, Sendable {
    /// 驻留（daemon 按相位执行保活副作用；字面量 = 当前相位）。
    case stay(phase: Calibration.Phase)
    /// 相位推进（daemon 先落盘再按序撤停充/写 CHIE，最后内存推进；失败臂不推进）。
    case advance(to: Calibration.Phase)
    /// RESTORE：瞬时收尾（daemon 恢复 CHIE + enforce + done 终态）。
    case restoreAndComplete
    /// 中止（daemon 按需恢复 CHIE + enforce + 终态字面量 + 删文件；reason 仅日志，
    /// safety 决定字面量族）。
    case abort(reason: String, safety: Bool)
}

/// tick 结果（输出 + 计数器回写——去抖/保活失败计数为轨道存储，转移纯函数不持有状态）。
public struct CalibrationTickResult: Equatable, Sendable {
    public let output: CalibrationTickOutput
    /// chargeFull 相完成判定去抖计数（转移后新值；非 chargeFull 相恒 0）。
    public let debounceTicks: Int
    /// CHIE 保活失败计数（转移后新值；非 discharge 相恒 0）。
    public let keepAliveFailures: Int
}

/// 相位转移纯函数（方案 §2.1 判定次序定版，逐条短路）：
/// - **通用规则（R1 P2-4）：完成/推进判定成立时（含去抖未满）不判相位超时**——
///   长睡唤醒报推进/完成而非 abort。
/// - `chargeFull`：充满判定（复用 OneShot.isFullOnceComplete 主判据 + ≥99 降级）
///   + 2 tick 去抖（复用 debounceTick，中断归零）→ advance(hold)；ext==false →
///   abort(unplug)；相位超时 → abort(timeout)；否则 stay（保活使能）。
/// - `hold`：now ≥ phaseStartedAt + holdDuration → advance(discharge)；ext==false →
///   abort(unplug)；整体兜底（action.deadline，24h）→ abort(timeout)；否则 stay
///   （保活停充——满电停充维持）。
/// - `discharge`：percent ≤ 10 → restoreAndComplete；温度 ≥40 → abort(temp, safety)；
///   CHIE 保活：failed 计数 ≥3 → abort(extRestoredExhausted, safety)，rewritten/
///   held 清零；相位超时 → abort(timeout)；否则 stay（CHIE 保活写 0x8）。
///   monitoringLoss **不经本函数**（早退路径构造 reason）。
/// - **有意简化（R1 P3-4 登记）**：discharge 相省略 ext 异常去抖（dischargeToLimit
///   有 extRestored 取消判例）——瞬态外部重开由 CHIE 保活逐 tick 纠正，持续无视
///   重写由 keepAliveFailures ≥3 兜底，极端残余由 12h 相位超时兜底。
public func calibrationTick(_ input: CalibrationTickInput) -> CalibrationTickResult {
    let phase = input.phase ?? .chargeFull
    switch phase {
    case .chargeFull:
        let completedNow = OneShot.isFullOnceComplete(
            fullyCharged: input.fullyCharged,
            isCharging: input.isCharging,
            percent: input.percent
        )
        let step = OneShot.debounceTick(
            conditionSatisfied: completedNow, counter: input.debounceTicks
        )
        if step.satisfied {
            return CalibrationTickResult(
                output: .advance(to: .hold), debounceTicks: 0, keepAliveFailures: 0
            )
        }
        if !input.externalConnected {
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.unplug, safety: true),
                debounceTicks: 0, keepAliveFailures: 0
            )
        }
        // 完成判定成立（含去抖未满）不判相位超时——长睡唤醒报推进而非 abort。
        if !completedNow && phaseTimedOut(
            phaseStartedAt: input.phaseStartedAt, now: input.now, timeout: Calibration.chargeFullTimeout
        ) {
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
                debounceTicks: 0, keepAliveFailures: 0
            )
        }
        return CalibrationTickResult(
            output: .stay(phase: .chargeFull),
            debounceTicks: step.counter, keepAliveFailures: 0
        )

    case .hold:
        if let started = input.phaseStartedAt,
           input.now >= started.addingTimeInterval(Calibration.holdDuration) {
            return CalibrationTickResult(
                output: .advance(to: .discharge), debounceTicks: 0, keepAliveFailures: 0
            )
        }
        if !input.externalConnected {
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.unplug, safety: true),
                debounceTicks: 0, keepAliveFailures: 0
            )
        }
        // 整体兜底（deadline 仅作 hold 相 24h 整体兜底判据，相位决策不用——R3 P3-1）。
        if input.now >= input.deadline {
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
                debounceTicks: 0, keepAliveFailures: 0
            )
        }
        return CalibrationTickResult(
            output: .stay(phase: .hold), debounceTicks: 0, keepAliveFailures: 0
        )

    case .discharge:
        // 完成判定前置（percent ≤ 10；与温度/超时同 tick 完成优先——R2 P2-4 同判例）。
        if input.percent <= Calibration.dischargeTargetPercent {
            return CalibrationTickResult(
                output: .restoreAndComplete, debounceTicks: 0, keepAliveFailures: 0
            )
        }
        // 温度 ≥40°C 单点中止（与 Discharge 同值不同义独立演化）。
        if input.temperatureC >= Calibration.temperatureLimitC {
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.temperature, safety: true),
                debounceTicks: 0, keepAliveFailures: 0
            )
        }
        // CHIE 保活（chieStatus 为 daemon 读改写后的语义；failed 递增计数）。
        switch input.chieStatus {
        case .failed:
            let failures = input.keepAliveFailures + 1
            guard failures >= Calibration.keepAliveFailureLimit else {
                return CalibrationTickResult(
                    output: .stay(phase: .discharge), debounceTicks: 0, keepAliveFailures: failures
                )
            }
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.keepAliveExhausted, safety: true),
                debounceTicks: 0, keepAliveFailures: 0
            )
        case .rewritten, .held:
            break
        case nil:
            // 防御：非 discharge 相不传 chieStatus；nil 视作保活正常（计数清零）。
            break
        }
        if phaseTimedOut(
            phaseStartedAt: input.phaseStartedAt, now: input.now, timeout: Calibration.dischargeTimeout
        ) {
            return CalibrationTickResult(
                output: .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
                debounceTicks: 0, keepAliveFailures: 0
            )
        }
        return CalibrationTickResult(
            output: .stay(phase: .discharge), debounceTicks: 0, keepAliveFailures: 0
        )
    }
}

/// 相位超时判定（phaseStartedAt nil 防御：视作未超时——不无据 abort）。
private func phaseTimedOut(phaseStartedAt: Date?, now: Date, timeout: TimeInterval) -> Bool {
    guard let phaseStartedAt else { return false }
    return now >= phaseStartedAt.addingTimeInterval(timeout)
}

// MARK: - 轨道扩展：校准终态锁存

extension OneShotTrack {
    /// 校准相位字段更新（启动注入 chargeFull 与推进后的相位/相位起始——daemon 经
    /// 本方法转移，action setter 模块外不可达；时序纪律 = 推进副作用 ④：落盘/
    /// 撤停充/CHIE 写均完成后才推进内存，方案 §2.2 次序钉死）。
    public mutating func setCalibrationPhase(_ phase: Calibration.Phase, startedAt: Date) {
        action?.phase = phase.rawValue
        action?.phaseStartedAt = startedAt
    }

    /// 校准 tick 计数器回写（去抖/保活失败计数——转移纯函数不持有状态，结果经
    /// 本方法回写轨道；daemon 锁内调用，转移仍全部经本类型方法——单一属主
    /// 不变量不破）。
    public mutating func applyCalibrationCounters(debounceTicks: Int, keepAliveFailures: Int) {
        self.debounceTicks = debounceTicks
        self.keepAliveFailures = keepAliveFailures
    }

    /// 校准终态锁存（done/safety/timeout——daemon 发起终态，App 轮询必见：
    /// 不锁存会被下一常规 tick 的 enforce:xxx 覆盖，M3 判例同 daemon 发起取消；
    /// 用户取消仍走 cancel()/cancelLatched() 既有方法）。清空动作 + 计数器归零。
    @discardableResult
    public mutating func terminateCalibration(_ literal: String) -> String {
        action = nil
        latchedLiteral = literal
        debounceTicks = 0
        resetDischargeCounters()
        return literal
    }
}