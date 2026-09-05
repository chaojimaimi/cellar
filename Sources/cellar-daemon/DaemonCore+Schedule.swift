import Foundation
import CellarCore

// MARK: - Phase 5 v1.6 充电日程（daemon 侧：状态写透 + 日程臂执行 + 配置命令；全部锁内）

/// 充电日程的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 本体零新增日程逻辑，
/// 工单钉死；可见性/属主不变量与 DaemonCore+CalibrationSchedule.swift 同款：
/// cellar-daemon 为 executable target，internal 符号模块外不可达）。转移的语义
/// 决策全部经 CellarCore.matchingEntry/desiredState/transitionRequired
///（CellarCoreCheck 场景域钉死）完成，本扩展只做副作用（policy 落地/状态落盘/
/// 写使能、日志）。
///
/// ⚠️ 转移执行禁令（工单 P0 级防呆，UD-5 排除清单）：applyEntry/restoreBase 一律
/// 走 `applyPolicyLocked` + `persistPolicyLocked` 段——**禁止调用 setLimits()/
/// disable()/enable() 整函数**（三者分别携带隐式取消在轨动作、auto 翻转清门、
/// clearUserActionLatch 等用户动作副作用；UD-4 已保证日程臂只在空闲语境执行）。
/// 唯一例外：applyEntry(chargingDisabled) 复用 disable 的「写 enableCharging +
/// mode disabled」段（照其 controller.perform 写后回读校验语义实现，不调 disable()
/// 整函数）。
extension DaemonCore {
    // MARK: - 状态写透

    /// 日程状态写透（内存缓存已改 → 落盘；**失败仅 error 日志不阻塞主流程**——
    /// 非宝贵资产定位：丢失后果为 R-8 已知边界（在窗丢失 = base 快照失不可得，
    /// 条目值成为新 base；退出丢失 = 下 tick 重判重恢复），方案 §2.2。
    /// 锁内调用；读路径恒走内存缓存（buildStatusLocked 不触盘）。
    func persistScheduleStateLocked(events: inout [LogEvent]) {
        do {
            try scheduleStateStore.save(scheduleState)
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "schedule-state.json 写入失败：\(error)（内存缓存继续生效——非宝贵资产，R-8 丢失后果低害）"
            ))
        }
    }

    // MARK: - 日程臂（performTickLocked 空闲 active 臂内、校准调度臂之后调用）

    /// 日程臂执行体（UD-4 挂点语义）：无侧重算 desired → transitionRequired 判定
    /// → 执行转移。**原子性（UD-3）**：转移成功（applyPolicyLocked+persist 无拒；
    /// chargingDisabled 以 enableCharging 写后回读通过为准）后才写 state +
    /// lastAction 字面量；失败 warn/info 顺延下 tick 重试。restoreBase 成功口径 =
    /// policy 落地 + persist（SMC 收敛交同拍 enforce + 下 tick 重试兜底，R1 P2-4）。
    ///
    /// - Parameters:
    ///   - actionName: 本 tick 的 lastAction 字面量（转移成功时改写为
    ///     `schedule:entered:<id 前 8>` / `schedule:restored`——UD-5 字面量族）。
    ///   - handled: 输出「转移后 policy.mode 已非 active」——调用方据此当拍跳过
    ///     enforce（chargingDisabled 进窗 = disable 全路径；恢复到 disabled base
    ///     同理；limit/恢复 active 转移后同拍 enforce 自然按新值执法）。无转移/
    ///     转移失败保持 active → false。
    func applyScheduleTransitionLocked(
        now: Date, actionName: inout String, handled: inout Bool, events: inout [LogEvent]
    ) {
        handled = false
        // 防御：臂只在「空闲 ∧ active」语境被调（UD-4——调用点即 performTickLocked
        // 空闲 active 分支；此处兜底防调用点漂移：动作活跃期边沿挂起、disabled
        // mode 是日程之上的总闸，两者都不评估）。
        guard !actionTrack.isActive, policy.mode == "active" else { return }
        // 配置缺省 → 空配置（enabled=false 空表）：desired 恒 .base——配置被移除/
        // 校验丢弃（R-9 回落）时若有在窗残留，仍走同一条恢复路径，不悬挂。
        let config = policy.schedule ?? .default
        let state = scheduleState
        let desired = desiredState(now: now, calendar: .current, config: config)
        guard let transition = transitionRequired(
            desired: desired, state: state, config: config
        ) else { return }
        switch transition {
        case .applyEntry(let entry):
            applyScheduleEntryLocked(now: now, entry: entry, actionName: &actionName, events: &events)
        case .restoreBase(let baseUpperLimit, let baseMode):
            restoreScheduleBaseLocked(
                baseUpperLimit: baseUpperLimit, baseMode: baseMode,
                actionName: &actionName, events: &events
            )
        }
        // 转移落地后 mode 已非 active（chargingDisabled 进窗 / 恢复到 disabled
        // base）→ 当拍跳过 enforce；mode 仍 active（limit 进窗 / 恢复 active）
        // → 同拍 enforce 自然按新值执法。
        handled = policy.mode != "active"
    }

    /// applyEntry 转移（UD-2：进窗即快照 base——当时的 policy mode/upperLimit 进
    /// state；成功后才写 state + 字面量）。chargingDisabled==true 优先（UD-1：
    /// 窗口内等效 disable，upperLimit 忽略）。
    private func applyScheduleEntryLocked(
        now: Date, entry: ChargeScheduleEntry, actionName: inout String, events: inout [LogEvent]
    ) {
        // base 快照（UD-2/R1 P0）：进窗时刻的 policy 值——退出边沿恢复**本快照**，
        // 窗口内手动修改是临时的（验收①：base 80、窗内改 75 → 退出恢复 80）。
        let baseUpperLimit = policy.upperLimit
        let baseMode = policy.mode
        var applied = false
        if entry.chargingDisabled == true {
            // disable 的「写 enableCharging（controller.perform 写后回读校验）+
            // mode disabled」段（工单转移执行禁令唯一例外——不调 disable() 整函数，
            // 其隐式取消/锁存副作用被 UD-5 排除清单禁止）。失败保持 active 顺延（R-4）。
            if let backend {
                do {
                    _ = try controller.perform(.enableCharging, backend: backend)
                    if applySchedulePolicyLocked(mode: "disabled", upperLimit: policy.upperLimit, events: &events) {
                        events.append(LogEvent(
                            category: .control, level: .info,
                            message: "日程 \(entry.id.prefix(8))：窗口内完全放开充电（写使能回读通过，mode=disabled——系统默认充电）"
                        ))
                        applied = true
                    }
                } catch {
                    events.append(LogEvent(
                        category: .control, level: .warn,
                        message: "日程 \(entry.id.prefix(8))：写使能失败（\(error)）——保持 active 顺延下 tick 重试"
                    ))
                }
            } else {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "日程 \(entry.id.prefix(8))：无控制后端，放开充电不可执行——保持 active 顺延"
                ))
            }
        } else if let limit = entry.upperLimit {
            // applyPolicyLocked + persist 段（禁调 setLimits() 整函数——见文件头
            // 转移执行禁令）；mode 仍 active。
            if applySchedulePolicyLocked(mode: policy.mode, upperLimit: limit, events: &events) {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "日程 \(entry.id.prefix(8))：窗口内限充 \(limit)%（base 快照 \(baseUpperLimit)%，退出边沿恢复快照）"
                ))
                applied = true
            }
        } else {
            // 惰性条目（chargingDisabled==false ∧ upperLimit==nil——validated 形式
            // 合法但无动作）：仅簿记，零策略写入；退出边沿照常恢复（值不变，幂等）。
            applied = true
        }
        guard applied else { return }
        // 原子性（UD-3）：转移成功后才写 state（base 快照进窗时刻值）+ 字面量。
        scheduleState = ScheduleState(
            lastAppliedEntryId: entry.id, baseUpperLimit: baseUpperLimit,
            baseMode: baseMode, lastAppliedAt: Int(now.timeIntervalSince1970)
        )
        persistScheduleStateLocked(events: &events)
        actionName = ChargeScheduleLiteral.entered(id: entry.id)
    }

    /// restoreBase 转移（UD-2：恢复 **state 快照的** base 值——非退出时刻现值；
    /// 成功口径 = policy 落地 + persist，R1 P2-4——SMC 收敛交同拍 enforce + 下 tick
    /// 重试兜底）。成功后清空 state（下一进入边沿重新快照——「耗尽语义」）。
    private func restoreScheduleBaseLocked(
        baseUpperLimit: Int?, baseMode: String?, actionName: inout String, events: inout [LogEvent]
    ) {
        // 防御：快照字段缺失/越域（state 部分损坏）→ 就地回落现值——恢复为「尽力
        // 还原」，绝不因脏快照卡死恢复路径（garbage mode 落回当前 mode）。
        let restoreMode = (baseMode == "active" || baseMode == "disabled") ? baseMode! : policy.mode
        let restoreUpper = baseUpperLimit ?? policy.upperLimit
        if applySchedulePolicyLocked(mode: restoreMode, upperLimit: restoreUpper, events: &events) {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "日程窗口结束：已恢复进窗快照（upper=\(restoreUpper)% mode=\(restoreMode)）"
            ))
            scheduleState = ScheduleState()
            persistScheduleStateLocked(events: &events)
            actionName = ChargeScheduleLiteral.restored
        }
    }

    /// 转移共用落地段（applyPolicyLocked + persist；工单指定的复用段落）。返回
    /// false = 目标策略 validated 拒（防御：日程域内值理论不可达——越域值只会来自
    /// 手改的 state 快照——顺延不推进，UD-3 原子性）。
    @discardableResult
    private func applySchedulePolicyLocked(
        mode: String, upperLimit: Int, events: inout [LogEvent]
    ) -> Bool {
        guard let newPolicy = DaemonPolicy.validated(
            mode: mode, upperLimit: upperLimit, hysteresis: policy.hysteresis,
            autoDischargeEnabled: policy.autoDischargeEnabled, fan: policy.fan,
            calibrationSchedule: policy.calibrationSchedule, thermal: policy.thermal,
            schedule: policy.schedule
        ) else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "日程转移落地被拒（目标策略 validated nil——mode=\(mode) upper=\(upperLimit)），保持现状顺延下 tick"
            ))
            return false
        }
        applyPolicyLocked(newPolicy, events: &events)
        persistPolicyLocked(events: &events)
        return true
    }

    // MARK: - setChargeSchedule XPC（UD-6；照 setCalibrationScheduleConfig 形态）

    /// setChargeSchedule：**三级校验**（① 长度 ≤8192 字节 → ② JSON 解码 → ③
    /// ChargeScheduleConfig.validated，任一失败 throw 错误原文回传——**禁止实现
    /// 第四级 UTF-8 校验**：xpc C-string→String 转换对非法字节静默有损，非法序列
    /// 由 JSON 解码必然失败兜底，R1 P2-1 定版）→ `policy.schedule` 应用（**不改
    /// mode、不取消在轨**——本命令的专属修改面，F-1 纪律：与 setLimits/disable/
    /// enable 三重建点互斥，照 setThermalConfig 先例）→ 持久化 → **即时
    /// performTickLocked**（R1 P2-3，照 setLimits 先例——新建即命中当前窗口的
    /// 条目 ≤1 tick 生效，消除 30s 观感延迟）→ buildStatusLocked。
    func setChargeScheduleConfig(json: String) throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        // ① 长度（字节口径与 xpc_string_get_length 一致；validateRequest/XPCServer
        //    臂已各拦一道，此处兜底直调路径——纵深防御同源常量）。
        guard ChargeScheduleWireKeys.validLength(json) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setChargeSchedule 拒绝：配置超长（\(json.utf8.count) 字节 > \(ChargeScheduleWireKeys.maxJsonLength) 上限）"
            ))
            throw ChargeScheduleSetError.payloadTooLong
        }
        // ② JSON 解码（解码器原文并入错误——不静默吞）。
        let decoded: ChargeScheduleConfig
        do {
            decoded = try ChargeScheduleConfig.decoded(from: json)
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setChargeSchedule 拒绝：配置不是合法 JSON（\(error)）"
            ))
            throw ChargeScheduleSetError.malformedJSON(String(describing: error))
        }
        // ③ validated 整包强校验（结构/值域非法 → nil，绝不落半合法配置）。
        guard let config = ChargeScheduleConfig.validated(
            enabled: decoded.enabled, entries: decoded.entries
        ) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setChargeSchedule 拒绝：配置结构非法（validated 整包 nil）"
            ))
            throw ChargeScheduleSetError.invalidParameters
        }
        policy.schedule = config
        persistPolicyLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "充电日程已更新：enabled=\(config.enabled) entries=\(config.entries.count)（即时 tick——命中窗口条目 ≤1 tick 生效）"
        ))
        performTickLocked(events: &events)
        return buildStatusLocked()
    }
}

/// setChargeSchedule 拒绝（三级校验任一失败；message = 用户可读文案，XPC errorReply
/// 原文透传 App 上屏——形态照 ThermalSetError 先例）。
enum ChargeScheduleSetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 第①级：长度越界（≤8192 字节硬上限——R-3 输入面收口）。
    case payloadTooLong
    /// 第②级：JSON 解码失败（解码器原文并入——不静默吞）。
    case malformedJSON(String)
    /// 第③级：validated 整包拒绝（结构/值域非法——绝不半合法）。
    case invalidParameters

    public var message: String {
        switch self {
        case .payloadTooLong:
            return "充电日程配置超长（上限 \(ChargeScheduleWireKeys.maxJsonLength) 字节）"
        case .malformedJSON(let detail):
            return "充电日程配置不是合法 JSON：\(detail)"
        case .invalidParameters:
            return "充电日程参数非法（条目 ≤8 且 id 唯一、weekdays 1-7 去重升序、时段 0-1439 分钟且起止不等、上限 60-100、动作字段至少一项）"
        }
    }

    public var description: String { message }
}
