import Foundation
import CellarCore

// MARK: - Phase 5 v1.4 校准调度（daemon 侧：配置命令 + 状态写透 + 终态记录；全部锁内）

/// 校准调度的 daemon 侧实现（扩展文件拆分——DaemonCore+Calibration.swift 触及
/// 400 行上限；可见性/属主不变量与同目录其他扩展同款：cellar-daemon 为
/// executable target，internal 符号模块外不可达）。语义决策全部经
/// CellarCore.CalibrationSchedulePolicy（CellarCoreCheck 场景域钉死）转移，本扩展
/// 只做副作用（policy 字段更新/状态落盘/日志）。
extension DaemonCore {
    // MARK: - 锚点与状态写透

    /// 锚点 Int（epoch 秒）→ Date（纯函数边界转换；nil = 从未启动——首次就绪语义）。
    func calibrationAnchorDateLocked() -> Date? {
        calibrationState.lastStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// 校准状态写透（内存缓存已改 → 落盘；**失败仅 error 日志不阻塞主流程**——
    /// 非宝贵资产定位：丢失后果仅为锚点重置多发一次校准/少一条展示记录，方案 §2.2）。
    /// 锁内调用；读路径恒走内存缓存（buildStatusLocked 不触盘）。
    func persistCalibrationStateLocked(events: inout [LogEvent]) {
        do {
            try calibrationStateStore.save(calibrationState)
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "calibration-state.json 写入失败：\(error)（内存缓存继续生效——非宝贵资产，丢失后果低害）"
            ))
        }
    }

    /// 校准终态记录（UD-5 三点口径共用出口）：
    /// - 第①点取消路径（cancelActionLocked 校准分支）：startedAt 传在手
    ///   action.startedAt（state 丢失仍有源可取，R2 P3）；
    /// - 第②点空闲臂观察（performTickLocked）：startedAt 传 nil → 取 state 锚点
    ///   （动作已清，仅锚点可作 startedAt 源）；
    /// - 第③点 startedAt 去重：`lastCalibration.startedAt == 本次 startedAt`
    ///   → 已记录不覆写（单次写入语义，防锁存存活期内逐 tick 重写漂移 endedAt）。
    ///   去重键**在手值优先**（P2-1）：state 写失败后锚点滞留旧值不会让下一次
    ///   终态记录被误跳过——锚点仅作 ② 观察路径（nil）的回落源。
    /// 在手值与锚点均缺失 → 跳过（无源可记，不虚构 startedAt）。
    func recordCalibrationOutcomeLocked(
        outcome: CalibrationOutcome, startedAt: Date?, events: inout [LogEvent]
    ) {
        guard let recordStartedAt = startedAt.map({ Int($0.timeIntervalSince1970) })
            ?? calibrationState.lastStartedAt else {
            return
        }
        if let last = calibrationState.lastCalibration, last.startedAt == recordStartedAt {
            return   // 第③点：同一次启动的终态已记录。
        }
        let now = Int(Date().timeIntervalSince1970)
        calibrationState.lastCalibration = CalibrationState.LastCalibrationRecord(
            startedAt: recordStartedAt, endedAt: now, outcome: outcome.rawValue
        )
        persistCalibrationStateLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "上次校准记录已写入：outcome=\(outcome.rawValue)（startedAt=\(recordStartedAt)）"
        ))
    }

    // MARK: - setCalibrationSchedule XPC（方案 §2.3，照 setFanConfig 先例）

    /// setCalibrationSchedule：三键缺席保持合并 → `policy.calibrationSchedule`
    /// 应用（**不改 mode**——本命令的专属修改面，F-1 纪律：与 setLimits/disable/
    /// enable 三重建点互斥）→ 持久化。无即时执行副作用（判定由下一心跳 tick 的
    /// 调度臂消费——凌晨窗口语义）；不取消在轨校准（R-1「随时可取消」由用户显式
    /// 取消承担）。
    func setCalibrationScheduleConfig(_ wire: CalibrationScheduleWire) throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        let base = policy.calibrationSchedule ?? .default
        guard let merged = wire.mergedPolicy(base: base) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setCalibrationSchedule 拒绝：调度参数越界（validated 整包 nil——绝不落半合法策略）"
            ))
            throw CalibrationScheduleSetError.invalidParameters
        }
        policy.calibrationSchedule = merged
        persistPolicyLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "校准调度已更新：enabled=\(merged.enabled) intervalDays=\(merged.intervalDays) startHour=\(merged.startHour)（下一心跳判定臂消费）"
        ))
        return buildStatusLocked()
    }
}

/// setCalibrationSchedule 拒绝（照 FanSetError 先例；message = 用户可读文案，
/// XPC errorReply 原文透传）。
enum CalibrationScheduleSetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 参数越界（validated 整包 nil——不落半合法策略；类型混淆已在 validateRequest
    /// 整包拒绝，XPCServer 臂值域校验与 validated 同源）。
    case invalidParameters

    public var message: String {
        switch self {
        case .invalidParameters: return "校准调度参数越界（周期 1-180 天，窗口起点 0-23 时）"
        }
    }

    public var description: String { message }
}
