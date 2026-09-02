import Foundation

// MARK: - WP2' dischargeToLimit（放电到上限）—— CellarCore 纯函数/纯值层

/// dischargeToLimit 动作族常量与判定纯函数（方案 WP2' §2.2/§2.3）。
///
/// 与 WP2 fullOnce 同构分层：daemon 只做副作用（写 CHIE/CHTE、删文件、日志），
/// 全部语义决策经本文件与 OneShotTrack 扩展（锁内单实例）转移——CellarCoreCheck
/// 矩阵穷举钉死的轨道转移与 daemon 运行时同源。
public enum Discharge {
    /// 动作类型字面量（action.json kind；ActionStore 白名单 {fullOnce, dischargeToLimit}）。
    public static let dischargeToLimitKind = "dischargeToLimit"
    /// 超时窗口（2 小时；deadline 为 start 时绝对 Date，SIGHUP 不重算——§1.7 算术
    /// 注记：100→上限主场景 50 分钟–3.3h，100→60 靠地板先终止）。
    public static let dischargeTimeout: TimeInterval = 2 * 3600
    /// 硬地板（百分位）：percent ≤ 60 → 紧急终止恢复（LimitPolicy 保证目标 ≥60）。
    public static let floorPercent = 60
    /// 温度上限 °C：≥40 → 紧急终止（**单点即触发**——评审 P2-2：与 ext 去抖不对称
    /// 是刻意的，温度误报仅提前终止方向安全，ext 误报丢动作）。
    public static let temperatureLimitC = 40.0
    /// ext 异常去抖所需连续 tick 数（N=2 = 60s 驻留；评审 P0-3：E3 恢复过渡态遥测
    /// 异常窗 58s，单点在 PD 重协商期不可信）。
    public static let extDebounceTicks = 2
    /// CHIE 保活连续失败上限（3 → 取消 + 告警）。
    public static let keepAliveFailureLimit = 3
    /// 监护缺失连续 tick 上限（backend/采样早退 ≥3 tick = 90s → 终止 + 告警，评审 P1-5）。
    public static let monitoringLossLimit = 3
    /// 终态/取消恢复 CHIE 重试总次数（重试阶梯，红线 5；含首次尝试）。
    public static let terminalRestoreAttempts = 3
    /// sleepNow 同步路径恢复 CHIE 总尝试数（**1 = 零重试**：仅首次尝试、失败不重试
    /// ——§1.5 同步路径约束，无 sleep 立即重试会阻塞 IOAllowPowerChange；余量交
    /// §2.4 残留不变量与唤醒兜底）。
    public static let sleepNowRestoreAttempts = 1

    /// CHIE 值协议（SMC-NOTES §7.5 实证）：0x00 = 适配器使能 · 0x08 = 禁用。
    public static let chieEnabledBytes: [UInt8] = [0x00]
    public static let chieDisabledBytes: [UInt8] = [0x08]

    /// 创建放电动作（deadline = now + 2h；targetPercent = 启动时策略上限快照）。
    public static func start(
        now: Date,
        kind: String = dischargeToLimitKind,
        targetPercent: Int
    ) -> OneShotAction {
        OneShotAction(
            kind: kind,
            startedAt: now,
            deadline: now.addingTimeInterval(dischargeTimeout),
            targetPercent: targetPercent
        )
    }

    /// CHIE 回读 → 适配器状态语义（TahoeBackend.adapterEnabled 的映射来源）：
    /// 0x00 → true · 0x08 → false · 其余值（含长度不符）→ nil（未知状态显式表达，
    /// 调用方按需恢复 fail-closed，禁止猜测语义）。
    public static func adapterState(from bytes: [UInt8]) -> Bool? {
        switch bytes {
        case chieEnabledBytes: return true
        case chieDisabledBytes: return false
        default: return nil
        }
    }

    /// §2.4 CHIE 残留不变量巡检判定（安全红线）：适配器必须为已使能（0x00）。
    /// false（禁用）/ nil（未知值）→ 需要巡检恢复（fail-closed——未知值可能是残留禁用）。
    public static func residualPatrolNeeded(enabled: Bool?) -> Bool {
        enabled != true
    }

    /// 完成判定：percent ≤ targetPercent（**不依赖 Amperage**——§7.5.2 禁用态遥测
    /// 冻结实证，电量下降为唯一可信判据）。targetPercent 缺席（防御，不合法）→ false。
    public static func isComplete(percent: Int, targetPercent: Int?) -> Bool {
        guard let targetPercent else { return false }
        return percent <= targetPercent
    }

    /// 超时判定：now >= deadline → 超时（deadline 为绝对 Date）。
    public static func isTimedOut(action: OneShotAction, now: Date) -> Bool {
        now >= action.deadline
    }

    /// 启动前置拒绝（纯函数；daemon 上抛 → XPC errorReply 原文，App 上屏）：
    /// - mode != "active"（含 disabled）→ 拒绝（fullOnce 同构）；
    /// - external != true（未外接或未知）→ 拒绝（不无据启动——禁用适配器前必须
    ///   确认适配器在场，否则整机切电池）；
    /// - percent 缺席（快照失败且无上次已知值）或 ≤ 目标 → 拒绝（无放电空间，
    ///   60% 地板已由 LimitPolicy 保证目标 ≥60）。
    public static func startPrecondition(
        mode: String,
        externalConnected: Bool?,
        percent: Int?,
        targetPercent: Int
    ) -> DischargeStartRejection? {
        guard mode == "active" else { return .modeNotActive }
        guard externalConnected == true else { return .noExternalPower }
        guard let percent, percent > targetPercent else {
            return .notAboveTarget(percent: percent ?? 0, target: targetPercent)
        }
        return nil
    }
}

/// 放电启动前置拒绝（与 OneShotStartRejection 同构：message = 用户可读文案）。
public enum DischargeStartRejection: Error, Equatable, Sendable, CustomStringConvertible {
    /// mode != "active"。
    case modeNotActive
    /// 未确认外接电源（未外接或外接状态未知）。
    case noExternalPower
    /// 电量未高于目标上限（无放电空间；percent 未知按 0 呈现原文）。
    case notAboveTarget(percent: Int, target: Int)
    /// action.json 写入失败（持久化是动作存活的前提——失败即回滚 CHIE 并拒绝）。
    case persistenceFailed
    /// 能力不可用（Legacy 后端 / CHIE 缺席 / 探测失败——App 按钮已按 capabilities
    /// 隐藏，本 case 为 XPC 纵深防御）。
    case capabilityUnavailable

    public var message: String {
        switch self {
        case .modeNotActive: return "「放电到上限」需要限充处于启用状态（当前已停用）"
        case .noExternalPower: return "「放电到上限」需要连接外接电源"
        case .notAboveTarget(let percent, let target):
            return "「放电到上限」需要当前电量高于目标上限（当前 \(percent)%，目标 \(target)%）"
        case .persistenceFailed: return "「放电到上限」启动失败：无法写入动作文件"
        case .capabilityUnavailable: return "当前机型不支持放电功能"
        }
    }

    public var description: String { message }
}

// MARK: - tick 判定链输入与输出

/// CHIE 保活状态（daemon 在调用侧完成回读/重写后传入；tick 判定链的输入之一）：
/// 与 ext 去抖**互补**（评审 P0-3 注记）——CHIE 被重置先被保活纠正并清零 ext 计数，
/// ext 持续 true 而 CHIE 回读 0x8 才是真异常。
public enum DischargeKeepAliveStatus: Equatable, Sendable {
    /// 回读 == 0x08（禁用生效，无需干预）。
    case held
    /// 回读 ≠ 0x8 → 已重写 0x8 成功（保活纠正；ext 去抖计数清零）。
    case rewritten
    /// 回读/重写失败（连续失败计数 +1；≥3 → 取消 + 告警）。
    case failed
}

/// 放电 tick 判定链输出（daemon 依此执行副作用：恢复 CHIE / enforce CHTE / 删文件 / 字面量落状态）。
public enum DischargeTickOutcome: Equatable, Sendable {
    /// 常态继续（保活 + start 字面量）。
    case keepAlive
    /// 完成（percent ≤ targetPercent → 恢复 CHIE + done 终态）。
    case completed
    /// 超时（deadline → 恢复 + timeout 终态）。
    case timedOut
    /// 安全终止（温度/地板/监护缺失 → safety 字面量**锁存**；reason 仅供 daemon 日志）。
    case safetyTerminated(reason: String)
    /// 取消（ext 异常/保活失败 → cancel 字面量**不锁存**，literal 随结果返回供调用方直写）。
    case cancelled(reason: String, literal: String)
    /// 轨道空载（防御分支：daemon 在活跃分支内不会遇到）。
    case idle
}

// MARK: - 轨道扩展：放电判定链（OneShotTrack 单一轨道承载两种动作）

extension OneShotTrack {
    /// 全部放电计数器归零（启动/取消/终态/崩溃恢复共用）。
    /// internal：跨文件访问（OneShot.swift 的 startIfIdle/cancel 等调用于本扩展定义；
    /// 存储属性本体在 OneShot.swift 主声明——扩展不能加存储属性）。
    mutating func resetDischargeCounters() {
        extDebounceTicks = 0
        keepAliveFailures = 0
        monitoringLossTicks = 0
    }

    /// 放电维护判定链（方案 §2.3 次序定版，**逐条短路**）：
    /// 监护缺失 → ①CHIE 保活（失败 ≥3 → 取消）→ ②ext 异常去抖（N=2，含保活互作用）
    /// → ③温度 ≥40°C 单点终止 → ④完成判定**前置**（与地板/超时同 tick 完成优先，
    /// 评审 P2-3）→ ⑤percent ≤ 60 硬地板 → ⑥超时（deadline）→ 常态。
    /// 终态（completed/timedOut/safetyTerminated）→ 锁存字面量 + 清空动作；
    /// cancelled → 不锁存（字面量随结果返回，daemon 直写 lastStatus——fullOnce cancel 同构）。
    public mutating func tickDischarge(
        now: Date,
        percent: Int,
        temperatureC: Double,
        externalConnected: Bool,
        chieStatus: DischargeKeepAliveStatus,
        monitoringAvailable: Bool
    ) -> DischargeTickOutcome {
        guard let action else { return .idle }
        let kind = action.kind

        // 监护缺失（评审 P1-5）：backend/采样失败早退期间其余判定不可信——
        // 只推进计数；连续 ≥3 tick（90s）→ 安全终止；恢复可用即清零。
        guard monitoringAvailable else {
            monitoringLossTicks += 1
            guard monitoringLossTicks >= Discharge.monitoringLossLimit else { return .keepAlive }
            latchedLiteral = OneShotLiteral.safety(kind: kind)
            self.action = nil
            resetDischargeCounters()
            return .safetyTerminated(reason: "monitoringLoss")
        }
        monitoringLossTicks = 0

        // ① CHIE 保活（与 ext 去抖互补：CHIE 被重置先纠正并清零 ext 计数）
        switch chieStatus {
        case .failed:
            keepAliveFailures += 1
            if keepAliveFailures >= Discharge.keepAliveFailureLimit {
                return terminateDischargeCancelled(reason: "keepAliveFailure")
            }
            // 未达上限：继续后续判定（完成亦恢复 CHIE，不因保活失败压住完成）
        case .rewritten:
            keepAliveFailures = 0
            extDebounceTicks = 0
        case .held:
            keepAliveFailures = 0
        }

        // ② ext 异常去抖（N=2）：**仅当 CHIE 真实驻留 0x8**（held）才计数——
        // CHIE 被重置先被保活纠正（rewritten 已清零）；ext=false 即清零（中断归零）。
        if chieStatus == .held && externalConnected {
            extDebounceTicks += 1
            if extDebounceTicks >= Discharge.extDebounceTicks {
                return terminateDischargeCancelled(reason: "extRestored")
            }
        } else if !externalConnected {
            extDebounceTicks = 0
        }

        // ③ 温度 ≥40°C → 紧急终止（单点即触发——刻意不对称，评审 P2-2）
        if temperatureC >= Discharge.temperatureLimitC {
            latchedLiteral = OneShotLiteral.safety(kind: kind)
            self.action = nil
            resetDischargeCounters()
            return .safetyTerminated(reason: "temperature")
        }

        // ④ 完成判定前置（percent ≤ 目标；不依赖 Amperage——§7.5.2 冻结实证）。
        // 顺序在 ⑤⑥ 之前 = 同 tick 完成与地板/超时并存 → 完成优先（评审 P2-3）。
        if Discharge.isComplete(percent: percent, targetPercent: action.targetPercent) {
            latchedLiteral = OneShotLiteral.done(kind: kind)
            self.action = nil
            resetDischargeCounters()
            return .completed
        }

        // ⑤ 硬地板 percent ≤ 60 → 紧急终止（目标恒 ≥60，地板先于超时终止）
        if percent <= Discharge.floorPercent {
            latchedLiteral = OneShotLiteral.safety(kind: kind)
            self.action = nil
            resetDischargeCounters()
            return .safetyTerminated(reason: "floor")
        }

        // ⑥ 超时（deadline 绝对 Date；完成已在 ④ 短路——长睡唤醒报 done 而非 timeout）
        if Discharge.isTimedOut(action: action, now: now) {
            latchedLiteral = OneShotLiteral.timeout(kind: kind)
            self.action = nil
            resetDischargeCounters()
            return .timedOut
        }

        return .keepAlive
    }

    /// 取消型终态（ext 异常/保活失败）：cancel 字面量**锁存**（审查 M3——daemon 发起
/// 的取消经 App 轮询通知，不锁存会被下一常规 tick 的 enforce:xxx 覆盖：App 面板
/// 关闭以 60s 档轮询时可能永远见不到 cancel → 通知机制性漏发。锁存后 App 轮询
/// 必见终态，直到下次用户动作清除——与 done/safety 锁存同形态）。清空动作 + 计数器归零。
    private mutating func terminateDischargeCancelled(reason: String) -> DischargeTickOutcome {
        let literal = OneShotLiteral.cancel(kind: action?.kind ?? Discharge.dischargeToLimitKind)
        action = nil
        latchedLiteral = literal
        resetDischargeCounters()
        return .cancelled(reason: reason, literal: literal)
    }

    /// 监护缺失计数推进（performTickLocked 早退路径调用；仅 discharge 活跃时生效）。
    /// 返回 true = 连续 ≥3 tick（90s）→ 调用方执行终止恢复（terminateMonitoringLoss）。
    public mutating func noteMonitoringLoss() -> Bool {
        guard action?.kind == Discharge.dischargeToLimitKind else { return false }
        monitoringLossTicks += 1
        return monitoringLossTicks >= Discharge.monitoringLossLimit
    }

    /// 监护缺失终止（noteMonitoringLoss 返回 true 后由 daemon 调用）；
    /// safety 字面量锁存 + 清空动作。空轨/非放电 → nil（防御）。
    @discardableResult
    public mutating func terminateMonitoringLoss() -> String? {
        guard action?.kind == Discharge.dischargeToLimitKind else { return nil }
        let kind = action!.kind
        action = nil
        latchedLiteral = OneShotLiteral.safety(kind: kind)
        resetDischargeCounters()
        return latchedLiteral
    }
}

// MARK: - CHIE 恢复与残留巡检（daemon/检查侧共用的 IO 帮助——后端注入）

/// CHIE 适配器控制帮助（写后回读校验 + 重试阶梯；供 daemon 终态/取消/睡眠/启动
/// 恢复与 CellarCoreCheck 故障注入验证共用——与 LimitController.perform 同分层）。
public enum DischargeAdapterControl {
    /// 恢复适配器使能（CHIE=0x00）：写 + 回读校验，失败**立即**重试至多
    /// `attempts` 次（总尝试数，含首次；本函数内部无 sleep——睡眠路径约束见
    /// `Discharge.sleepNowRestoreAttempts`）。彻底失败 → 返回最后一次错误
    /// （调用方负责告警；残留交 §2.4 巡检兜底）；成功 → nil。
    ///
    /// 回读语义：`adapterEnabled()` 返回 true（0x00）即恢复成功；false/nil（未知）
    /// → 本次尝试失败（保持 verifyFailed 显式化风格）。
    public static func restoreEnabled(backend: any ChargingBackend, attempts: Int) -> Error? {
        guard attempts >= 1 else { return nil }
        var lastError: Error = BackendError.adapterControlUnsupported
        for attempt in 1...attempts {
            do {
                try backend.setAdapterEnabled(true)
                let state = try backend.adapterEnabled()
                if state == true { return nil }
                throw BackendError.verifyFailed(key: "CHIE", desired: true, actual: state ?? false)
            } catch {
                lastError = error
                if attempt == attempts { return lastError }
            }
        }
        return lastError
    }
}