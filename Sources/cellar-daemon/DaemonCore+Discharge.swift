import Foundation
import CellarCore

// MARK: - WP2' dischargeToLimit（放电到上限，方案 §2 全部）

/// WP2' 放电动作的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 触及 800 行
/// 硬上限；可见性/属主不变量与 DaemonCore+OneShot.swift 同款：cellar-daemon 为
/// executable target，internal 符号模块外不可达）。
///
/// 语义决策全部经 CellarCore.Discharge / OneShotTrack（锁内单实例）转移，本扩展
/// 只做副作用（写 CHTE/CHIE、删文件、终态字面量落状态）与日志——判定链经
/// CellarCoreCheck 矩阵穷举钉死，daemon 运行时与测试同源。
extension DaemonCore {
    /// 放电启动发起方（§2.2 拆分判别）：manual = XPC 用户动作；auto = tick 内自动触发。
    enum Initiator {
        case manual, auto
    }

    /// dischargeToLimit 锁内启动结果（幂等分支零副作用：动作已在轨 → .alreadyActive，
    /// 调用方仅 .started 才执行后续副作用）。
    enum DischargeStartOutcome {
        case started, alreadyActive
    }

    /// dischargeToLimit XPC（方案 §2.3 启动序列，§2.2 拆分定稿）：
    /// 取锁 → locked(.manual) → **仅 .started 才 performTickLocked**（即时 tick，
    /// M2 语义）→ buildStatusLocked。
    ///
    /// catch（R1 P1-1 + R2 P3 注记）：手动路径在 catch 中先补一次常规 tick 再上抛
    /// ——覆盖面大于原两臂（前置/能力拒绝、CHTE 写失败原先不 tick，现也补一次
    /// enforce：良性、幂等）；原 CHIE 校验/save 失败两臂的 M2 即时收敛语义由本
    /// catch 等价承接。locked 内任何路径不 tick（递归不可能）。
    func dischargeToLimit() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        let outcome: DischargeStartOutcome
        do {
            outcome = try dischargeToLimitLocked(now: Date(), initiator: .manual, events: &events)
        } catch {
            performTickLocked(events: &events)
            throw error
        }
        if outcome == .started {
            performTickLocked(events: &events)
        }
        return buildStatusLocked()
    }

    /// dischargeToLimit 锁内启动（唯一副作用序列；失败臂按臂注记，**全程不 tick**）：
    /// 幂等检查（动作在轨 → .alreadyActive，零副作用直接返回）→ 能力守卫 → 前置
    /// 快照+startPrecondition → 合盖拒绝闸（0.20 M1a）→ CHTE=0（撤停充，CHTE 可写
    /// 门控：26 执行 / 27 跳过）→ CHIE=0x8 写+回读 → startIfIdle(timeout: 2h)
    /// → actionStore.save → .started。
    ///
    /// 0.20 M1a §2.2 #1/#2/#3 路由：能力守卫改校验 CHIE 控制面可写（26 = tahoe
    /// 后端原路径优先；27 = CHIE 探测 writable）；CHIE 读写经 DischargeAdapterControl
    /// client 直挂（26 上与 TahoeBackend CHIE 路径同源同字节——行为不变）。
    ///
    /// 失败臂（R1 P1-1 + R2 P3 按臂注记）：
    /// - 前置/能力/合盖拒绝与 CHTE 写失败臂：无副作用、无 tick（与现实现一致）；
    /// - CHIE 回读校验失败臂：仅事件记录 + 上抛，**不做 CHIE 恢复**（写入态未知，
    ///   恢复交 §2.4 CHIE 残留不变量巡检——与现实现一致），无 tick；
    /// - actionStore.save 失败臂：restoreEnabled（CHIE 恢复重试阶梯）+ cancel 回滚
    ///   + 事件记录，无 tick（R2 P2-B：此回滚**不记**冷却——启动失败非「已建立
    ///   动作的终止」，动作从未持久化/可见；失败重试节奏 = 每 tick 判定重判）。
    ///
    /// initiator == .auto 且 .started → latchAutoStart（锁存在 save 成功之后——与
    /// startIfIdle 清锁存时序自洽）；manual 不锁存（用户刚点过按钮，XPC 回包即知）。
    func dischargeToLimitLocked(
        now: Date, initiator: Initiator, events: inout [LogEvent]
    ) throws -> DischargeStartOutcome {
        // 幂等：动作已在轨（任意类型）→ .alreadyActive（非错误——App 按钮随状态消失）。
        guard !actionTrack.isActive else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "dischargeToLimit 重复请求：动作已在进行中，回当前状态（幂等）"
            ))
            return .alreadyActive
        }
        // 能力纵深防御（App 已按 capabilities 隐藏按钮/开关；XPC 侧独立核验，评审
        // P1-1 fail-closed）：CHIE 放电控制面可写才放行（0.20 M1a §2.2 #1——
        // Legacy 后端/CHIE 缺席/探测失败 → 拒绝；27 可启动放电）。
        guard let client = dischargeControlClientLocked else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 拒绝：放电控制面不可用（capabilityUnavailable）"
            ))
            // 0.20.1 §2.1 事件落盘（挂钩表第二行·拒绝臂）：LogEvent 环随进程消失
            // 不可溯源，持久轨迹直写 stderr（同 topoff 惯例，锁内调用）。
            Self.persistLog(DischargePersistEvent.rejected(reason: "能力不可用（capabilityUnavailable）").message)
            throw DischargeStartRejection.capabilityUnavailable
        }
        // 前置快照（新鲜优先；失败回落上次已知值；均未知 → 前置拒绝，不无据启动）。
        let snapshot: BatterySnapshot?
        do {
            snapshot = try monitor.snapshot()
        } catch {
            snapshot = nil
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "dischargeToLimit 前置：电池快照失败（\(error)），使用上次已知外接状态"
            ))
        }
        let target = policy.upperLimit
        let percent = snapshot?.percent ?? lastStatus?.lastPercent
        let external = snapshot?.externalConnected ?? lastStatus?.lastExternalConnected
        if let rejection = Discharge.startPrecondition(
            mode: policy.mode,
            externalConnected: external,
            percent: percent,
            targetPercent: target
        ) {
            // 0.20.1 §2.1 事件落盘（挂钩表第二行·拒绝臂）：前置拒绝（mode/外接/电量）。
            Self.persistLog(DischargePersistEvent.rejected(reason: "\(rejection)").message)
            throw rejection
        }
        // 合盖拒绝闸（0.20 M1a §2.2 合盖管道；mini-spike 结论见 ClamshellProbe；
        // **P1 评审修法 (a)：仅 27 终态生效**——clamshellGateActiveLocked 同源门，
        // 26 clamshell-mode 手动放电放行照旧、26 行为零变化）：合盖检出 → 拒绝
        // （诚实原因）；强字段不可得 → 弱检查（ext=true 由前置保证 ∧ 屏幕唤醒
        // 代理）+ 局限登记（docs/DEVICES.md 键世代表）。
        let clamshellClosed = ClamshellProbe().clamshellClosed()
        let userActive = clamshellClosed == nil ? ClamshellProbe().userIsActive() : nil
        if ClamshellGate.startRejected(
            gateActive: clamshellGateActiveLocked,
            closed: clamshellClosed, userActive: userActive, externalConnected: external
        ) {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "dischargeToLimit 拒绝：合盖状态（防合盖放电黑屏——\(clamshellClosed == nil ? "弱检查" : "强检查")命中）"
            ))
            // 0.20.1 §2.1 事件落盘（挂钩表第二行·拒绝臂）：合盖拒绝闸。
            Self.persistLog(DischargePersistEvent.rejected(
                reason: "合盖状态（防合盖放电黑屏——\(clamshellClosed == nil ? "弱检查" : "强检查")命中）"
            ).message)
            throw DischargeStartRejection.clamshellClosed
        }

        // 启动序列 #2（§2.2）：先 CHTE=00000000（撤停充——把未测胞 CHTE=停充×CHIE=0x8
        // 从状态空间消除，评审 P1-2；恢复端由 enforce 收敛）——CHTE 可写门控：26
        // 执行、27 跳过（放电前无需 CHTE；27 控制键不在位）。
        if let backend {
            do {
                _ = try controller.perform(.enableCharging, backend: backend)
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "dischargeToLimit 启动：CHTE 撤停充失败（\(error)），不进入动作态"
                ))
                throw error
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "dischargeToLimit 启动：27 跳过 CHTE 撤停充（控制键不在位，放电前无需 CHTE）"
            ))
        }
        // 启动序列 #3（§2.2）：CHIE=0x8 写 + 回读校验（DischargeAdapterControl
        // client 直挂——26 上与 TahoeBackend CHIE 路径同源同字节，行为不变）。
        do {
            try DischargeAdapterControl.setAdapterEnabled(false, client: client)
            let state = try DischargeAdapterControl.adapterState(client: client)
            guard state == false else {
                throw BackendError.verifyFailed(key: "CHIE", desired: false, actual: state ?? true)
            }
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 启动：CHIE=0x08 写入/回读校验失败（\(error)）——不进入动作态，CHTE 走常规 enforce 恢复（CHIE 残留交 §2.4 巡检）"
            ))
            throw error
        }

        // ActionState 落盘：写失败 → **立即恢复 CHIE=0x0** + 上抛（不留下半启动态）。
        // ⚠️ timeout 必须显式传 discharge 2h 窗口（startIfIdle 默认是 fullOnce 的 4h——
        // 各动作族超时窗口不得混用，§2.3 超时终止语义按 2h 算术注记）。
        _ = actionTrack.startIfIdle(
            now: now,
            kind: Discharge.dischargeToLimitKind,
            targetPercent: target,
            timeout: Discharge.dischargeTimeout
        )
        do {
            try actionStore.save(actionTrack.action!)
        } catch {
            let restoreError = DischargeAdapterControl.restoreEnabled(
                client: client, attempts: Discharge.terminalRestoreAttempts
            )
            if let restoreError {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "dischargeToLimit 启动回滚：CHIE 恢复失败（\(restoreError)）——残留交 §2.4 残留不变量兜底"
                ))
            }
            _ = actionTrack.cancel()
            events.append(LogEvent(
                category: .control, level: .error,
                message: "dischargeToLimit 启动失败：action.json 写入失败（\(error)）"
            ))
            // 0.20.1 §2.1 事件落盘（挂钩表第二行·拒绝臂）：persistenceFailed。
            Self.persistLog(DischargePersistEvent.rejected(reason: "action.json 写入失败（persistenceFailed）").message)
            throw DischargeStartRejection.persistenceFailed
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "dischargeToLimit 已启动：目标 \(target)%（2 小时超时）"
        ))
        // 0.20.1 §2.1 事件落盘（挂钩表第一行·启动）：成功臂——manual/autostart
        // 发起方 + 目标 + 启动时电量（快照失败回落上次已知值，均未知 = 未知）。
        Self.persistLog(DischargePersistEvent.started(
            initiator: initiator == .manual ? "manual" : "auto",
            target: target,
            percent: percent
        ).message)
        if initiator == .auto {
            // 自动启动必须锁存（App 轮询必见 autostart → 通知必发；M3 判例同取消）。
            actionTrack.latchAutoStart(OneShotLiteral.autoStart(kind: Discharge.dischargeToLimitKind))
        }
        return .started
    }

    /// 放电动作维护分支（performTickLocked 第 5 步放电分支 + 0.20 M1a 观测段维护
    /// 子分支共用——方案 §2.3 判定次序在 CellarCore 轨道转移，本方法仅做 CHIE
    /// 保活读改写 + 副作用执行）：返回本 tick 的 lastAction 字面量。
    ///
    /// 0.20 M1a §2.2 #4 路由：backend 参数 → client（CHIE 控制面直挂）；CHTE 执法
    /// 面取 self.backend（执法段调用点同值；观测段调用点恒 nil）——终态/取消收敛
    /// 由 enforceLimitChargingLocked 的 27 臂承接（编排/topoff 通道，M1b 续接）。
    /// 调用方职责：client 由 dischargeControlClientLocked 保证（执法段不变量封口 /
    /// 观测段路由判定）。
    func maintainDischargeLocked(
        now: Date,
        snapshot: BatterySnapshot,
        client: SMCClient,
        events: inout [LogEvent]
    ) -> String {
        // 合盖拒绝闸——运行中止（0.20 M1a §2.2 合盖管道，30s 粒度；**P1 评审修法
        // (a)：仅 27 终态生效**——26 clamshell-mode 运行续行照旧）：合盖检出 →
        // 中止还原 + 通知（daemon 发起取消 → cancelLatched 锁存——App 轮询必见
        // 终态，审查 M3 同构）。closed == nil 不中止（息屏 ≠ 合盖，局限登记）。
        if ClamshellGate.shouldAbort(gateActive: clamshellGateActiveLocked, closed: lastClamshellClosed) {
            noteDischargeTerminatedLocked(now: now)
            let literal = actionTrack.cancelLatched()
                ?? OneShotLiteral.cancel(kind: Discharge.dischargeToLimitKind)
            restoreDischargeAdapterLocked(client: client, terminal: "合盖中止", events: &events)
            enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            deleteActionFileLocked(events: &events)
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "放电运行中止：检出合盖（防黑屏与不可见耗电）——已恢复适配器使能，取消终态锁存待 App 轮询通知"
            ))
            // 0.20.1 §2.1 事件落盘（挂钩表第五行·取消臂）：daemon 发起的中止。
            Self.persistLog(DischargePersistEvent.cancelled(reason: "合盖检出中止").message)
            return literal
        }
        // ① CHIE 保活（tick 判定链输入；轨道的保活失败计数经本结果推进）：
        // 回读 == 0x08 → held；≠0x8（含 0x00 重置/未知值）→ 重写 0x8 后回读；
        // 任何失败 → failed（连续 3 次由轨道取消）。
        let chieStatus: DischargeKeepAliveStatus
        do {
            let enabled = try DischargeAdapterControl.adapterState(client: client)
            switch enabled {
            case false:
                chieStatus = .held
            case true, nil:
                do {
                    try DischargeAdapterControl.setAdapterEnabled(false, client: client)
                    let rechecked = try DischargeAdapterControl.adapterState(client: client)
                    chieStatus = rechecked == false ? .rewritten : .failed
                } catch {
                    noteControlFailureLocked(error, events: &events, context: "CHIE 保活重写")
                    chieStatus = .failed
                }
            }
        } catch {
            noteControlFailureLocked(error, events: &events, context: "CHIE 保活回读")
            chieStatus = .failed
        }

        // 历时计算输入（0.20.1 §2.1 挂钩表第三行）：tickDischarge 终态臂会清空动作，
        // startedAt 必须在推进前捕获。
        let startedAt = actionTrack.action?.startedAt
        let outcome = actionTrack.tickDischarge(
            now: now,
            percent: snapshot.percent,
            temperatureC: snapshot.temperatureC,
            externalConnected: snapshot.externalConnected,
            chieStatus: chieStatus,
            monitoringAvailable: true
        )

        switch outcome {
        case .completed, .timedOut, .safetyTerminated:
            // 统一完成记录（五落点之一）：终态即记冷却 + 关翻转门（R1 P1-2——
            // 完成/超时/安全终止后不再被下一 tick 立即重触发）。
            noteDischargeTerminatedLocked(now: now)
            let terminal: String
            switch outcome {
            case .completed: terminal = "完成"
            case .timedOut: terminal = "超时"
            case .safetyTerminated(let reason): terminal = "安全终止(\(reason))"
            default: terminal = "终态"
            }
            // 0.20.1 §2.1 事件落盘（挂钩表第三行·maintain 终态）：outcome + 历时。
            Self.persistLog(DischargePersistEvent.terminal(
                outcome: terminal,
                durationSeconds: startedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? -1
            ).message)
            restoreDischargeAdapterLocked(client: client, terminal: terminal, events: &events)
            // 审查 M2：终态必须**即时** enforce CHTE——启动序列曾写 CHTE=0 放行充电，
            // 若只恢复 CHIE，通知说「限充已恢复」但最长 30s 存在无约束充电
            // （enforce 收敛前电池直接充到上限）。floor=60 案 percent<resume →
            // enableCharging 无害（CHTE 本就是 0）。
            // WP1：传本 tick 快照温度——放电热终止（≥40°C）后恢复路径被守卫拦截
            // 热态回充（方案 §2.3）。
            // 0.20 M1a §2.2 #9：27（backend 缺席）→ 收敛=回归汇聚目标（nil 臂）。
            enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            deleteActionFileLocked(events: &events)
            return actionTrack.latchedLiteral ?? fallbackLiteral(for: outcome)
        case .cancelled(let reason, let literal):
            // 统一完成记录（五落点之一）：取消即记——修复「用户取消后被立即重触发」
            // 漏洞（R1 P1-2；过度抑制无害：完成后 percent ≤ 目标本就不满足触发门）。
            noteDischargeTerminatedLocked(now: now)
            // 0.20.1 §2.1 事件落盘（挂钩表第五行·取消臂）：轨道异常取消
            //（keepAliveFailure/extRestored）。
            Self.persistLog(DischargePersistEvent.cancelled(reason: reason).message)
            // 统一取消：恢复 CHIE（重试阶梯 + 告警）→ enforce CHTE（恢复限充语义）。
            restoreDischargeAdapterLocked(client: client, terminal: "取消(\(reason))", events: &events)
            enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            deleteActionFileLocked(events: &events)
            return literal
        case .keepAlive:
            let literal = OneShotLiteral.start(kind: Discharge.dischargeToLimitKind)
            return actionTrack.effectiveLastAction(literal) ?? literal
        case .idle:
            // 防御分支：维护分支仅在轨道活跃时进入，轨道空载不可达。
            return "enforce:noop"
        }
    }

    /// 终态字面量回退（latchedLiteral 理论恒有值——防御分支同 fullOnce 模式）。
    private func fallbackLiteral(for outcome: DischargeTickOutcome) -> String {
        let kind = Discharge.dischargeToLimitKind
        switch outcome {
        case .completed: return OneShotLiteral.done(kind: kind)
        case .timedOut: return OneShotLiteral.timeout(kind: kind)
        case .safetyTerminated: return OneShotLiteral.safety(kind: kind)
        default: return OneShotLiteral.cancel(kind: kind)
        }
    }

    /// 统一完成记录（方案 §2.2，R1 P1-2 定稿）：凡 dischargeToLimit 动作终止/取消
    /// 一律调用——置冷却时刻 + 关适配器翻转门。不区分 manual/auto 起源（过度抑制
    /// 无害：完成后 percent ≤ 目标本就不满足触发门）。落点全集 = maintain 四终态/
    /// 取消、睡眠取消、cancelAction 放电分支、监护缺失终止、启动崩溃恢复。
    /// ⚠️ locked 自身 save 失败回滚**不**调用（R2 P2-B：启动失败非「已建立动作的
    /// 终止」——动作从未持久化/可见；误记会退化为每 30min 才重试）。
    func noteDischargeTerminatedLocked(now: Date) {
        lastAutoDischargeCompletedAt = now
        adapterCycleSinceAutoCompletion = false
        // code-review P1：终止同时 disarm——放电后的 ext false→true 回跳是恢复痕迹
        // 而非物理重插，仅重新武装后（disarm 态回跳触发）的后续转移才开门。
        adapterCycleArmed = false
    }

    /// 终态/取消恢复 CHIE=0x0（写 + 回读校验重试阶梯 —— 取消写失败 ≠ 取消完成，
    /// 红线 5：失败告警后终态照常落盘，残留交 §2.4 CHIE 残留不变量兜底）。
    /// 0.20 M1a §2.2 #4：backend 参数 → client（CHIE 控制面直挂——26 行为不变，
    /// 27 经探测连接真实还原）。
    private func restoreDischargeAdapterLocked(
        client: SMCClient,
        terminal: String,
        events: inout [LogEvent]
    ) {
        let restoreError = DischargeAdapterControl.restoreEnabled(
            client: client, attempts: Discharge.terminalRestoreAttempts
        )
        if let restoreError {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "discharge \(terminal)：CHIE 恢复写失败（\(restoreError)——重试阶梯耗尽），残留交 §2.4 残留不变量巡检"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "discharge \(terminal)：已恢复适配器使能（CHIE=0x00，回读校验通过）"
            ))
        }
    }

    /// 终态/取消后恢复限充语义（「enforce CHTE」，审查 M2 扩展至完成/超时/安全终止）：
/// 数据源 = 最近成功采样（lastStatus，≤30s 陈旧可接受——决策规则与常规 enforce
/// 相同，下 tick 全量重估兜底）；external 恒 true（CHIE=0x00 已确认写入 →
/// 适配器恢复）。失败仅记日志（enforce 常规分支本就会重试）。
///
/// WP1：`temperatureC` = 调用点作用域内可得的温度（nil = 快照失败旁路——
/// 守卫跳过一 tick，按常规决策执行；旁路窗口 ≤1 tick，下 tick 常规守卫按充电
/// 现态重新介入，方案 §2.3）。
///
/// 0.20 M1a §2.2 #9 + **0.20 M1b 兑现**：`backend` 放宽为可选——nil（27，CHTE 不在
/// 位）→ 收敛=回归汇聚目标：≥80 编排链**同拍补发**（观测段路由后同 tick 跑
/// orchestrationTickLocked——动作已清轨，lastApplied != desired 立即 valueChange
/// 补发）；**<80 topoff 随写续接已接通**（同拍汇聚点分流 topoffOwned → channelTick
/// 幂等重写域恢复执法；本臂仅落收敛语义日志，域写由汇聚点统一执行防双写）。
/// 26 传非 nil backend → 原样 CHTE enforce（行为不变）。
    func enforceLimitChargingLocked(backend: (any ChargingBackend)?, temperatureC: Double?, events: inout [LogEvent]) {
        guard let backend else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "终态/取消：27 收敛=回归汇聚目标（充电执法交编排/topoff 通道——≥80 编排链同拍补发，<80 topoff 同拍汇聚点随写续接）"
            ))
            return
        }
        guard let percent = lastStatus?.lastPercent else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "终态/取消：无采样电量，enforce CHTE 延后至下一常规 tick"
            ))
            return
        }
        do {
            let chargingEnabled = try backend.chargingEnabled()
            let context = ChargingContext(
                percent: percent,
                externalConnected: true,   // CHIE=0x00 回读已确认（恢复方校验过）
                chargingEnabled: chargingEnabled
            )
            // 套温度守卫：放电热终止（≥40°C）后 CHTE 现态为使能、percent 恒 < 上限
            // → 守卫 case 2 主动写停充，修复「41°C 热态回充」间隙（方案 §2.3）；
            // 37–40°C 区间恢复按常规决策回充（低于暂停阈值，符合守卫声明语义）。
            let action: ChargingAction
            if let temperatureC {
                let base = controller.decide(context: context)
                // v1.5（UD-4/R1 P2-3）：守卫阈值来源 = 锁内策略（未配置走
                // .default 40/37）——函数体内直接读，6 个调用行不参数化。
                action = ThermalGuard.guarded(
                    base: base,
                    context: context,
                    temperatureC: temperatureC,
                    policy: policy.thermal ?? .default
                ).action
            } else {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "无温度数据，热守卫跳过一 tick"
                ))
                action = controller.decide(context: context)
            }
            _ = try controller.perform(action, backend: backend)   // noop 不触碰 backend
            events.append(LogEvent(
                category: .control, level: .info,
                message: "终态/取消：已按当前策略恢复限充（action=\(action)，温度=\(temperatureC.map { String(format: "%.1f", $0) } ?? "未知")°C，percent=\(percent)% enforce 收敛）"
            ))
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "终态/取消：enforce CHTE 失败（\(error)）（下 tick 常规 enforce 兜底）"
            ))
        }
    }

    /// §2.4 CHIE 残留不变量巡检（**安全红线**）：无动作活跃期的常规 tick 巡检——
    /// 回读 ≠ 0x00 → 写 0x00 + 回读校验 + 告警（lastAction = `dischargeToLimit:safety`，
    /// App 通知通道）+ 走既有自愈计数。不变式：**CHIE=0x8 仅允许在放电动作活跃期
    /// 存在**——本巡检覆盖全部「动作已终态但恢复写失败/重试耗尽」的泄漏路径。
    /// 返回命中时的 safety 字面量（调用方覆写本 tick lastAction）；未命中 → nil。
    ///
    /// 门控（审查 M1）：**必须用探测结果 capabilities**（tahoe ∧ CHIE 在位），
    /// 不得用 `adapterControlSupported`（TahoeBackend 硬编码 true）——CHTE 在位但
    /// CHIE 缺席的 Tahoe 机器若按 supported 门控会陷入「巡检读失败 → 自愈计数 →
    /// 90s 重建」的永久失败循环。capabilities 含 discharge 的机器 CHIE 必在位。
    /// 0.20 M1a §2.2 #7：backend 参数 → client（CHIE 控制面直挂；执法段两处调用
    /// 点 + 观测段新增调用——27 残留巡检兜底落位）。
    @discardableResult
    func patrolCHIEResidualLocked(
        client: SMCClient,
        events: inout [LogEvent]
    ) -> String? {
        guard capabilities?.contains(DaemonXPC.capabilityDischarge) == true else { return nil }
        let enabled: Bool?
        do {
            enabled = try DischargeAdapterControl.adapterState(client: client)
        } catch {
            noteControlFailureLocked(error, events: &events, context: "CHIE 残留巡检回读")
            return nil
        }
        guard Discharge.residualPatrolNeeded(enabled: enabled) else { return nil }
        // 巡检命中：写 0x00 + 回读校验（每次 tick 一次尝试——30s 节奏，连续命中
        // 由 App 侧「同字面量不重复通知」收敛）。
        let restoreError = DischargeAdapterControl.restoreEnabled(client: client, attempts: 1)
        if let restoreError {
            noteControlFailureLocked(restoreError, events: &events, context: "CHIE 残留巡检恢复")
            events.append(LogEvent(
                category: .control, level: .error,
                message: "CHIE 残留巡检：恢复写失败（\(restoreError)）——残留禁用未清除，继续巡检"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "CHIE 残留巡检：检测到非使能状态，已清零并回读确认（放电残留恢复）"
            ))
        }
        return OneShotLiteral.safety(kind: Discharge.dischargeToLimitKind)
    }

    /// 监护缺失计数（评审 P1-5；WP3 门控扩展 R1 P1-1 + R2 P1-1 三道闸之一——**链条
    /// 第一道闸**：外层 guard 不放行则 Discharge.swift 两轨道方法永不执行）：放电
    /// （dischargeToLimit）或校准放电相（calibration ∧ phase==discharge）× backend/
    /// 采样/控制键读取早退 → 连续 ≥3 tick（90s）→ 安全终止 + 告警（恢复尽力；
    /// 失败交 §2.4 不变量）。performTickLocked 步骤 1/2/3 早退路径调用。
    /// 0.20.1 §2.1：`reason` = 早退成因（调用方注入——观测路径/采样失败/控制键读取
    /// 失败等），终止臂随事件落盘（挂钩表第四行）。
    func noteDischargeMonitoringLossLocked(events: inout [LogEvent], reason: String = "未知") {
        guard actionTrack.action?.kind == Discharge.dischargeToLimitKind
            || (actionTrack.action?.kind == Calibration.kind
                && actionTrack.action?.phase == Calibration.Phase.discharge.rawValue) else { return }
        guard actionTrack.noteMonitoringLoss() else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "放电动作监护缺失（连续第 \(actionTrack.monitoringLossTicks) tick，≤\(Discharge.monitoringLossLimit) 不终止）"
            ))
            return
        }
        guard let literal = actionTrack.terminateMonitoringLoss() else { return }
        // 统一完成记录（五落点之四）：监护缺失终止即记冷却（R1 P1-2 全集成员）。
        noteDischargeTerminatedLocked(now: Date())
        // 0.20.1 §2.1 事件落盘（挂钩表第四行）：监护缺失终止——置于恢复尝试之前，
        // 恢复写失败也不丢终止事件。
        Self.persistLog(DischargePersistEvent.monitoringLoss(reason: reason).message)
        // 0.20 M1a §2.2 #6：恢复写经控制面——27 经 DischargeAdapterControl 写
        // CHIE=0x00（终止必须真实还原，防适配器禁用泄漏）；26 tahoe 路径行为不变
        // （dischargeControlClientLocked 同一 client 同字节）。
        if let client = dischargeControlClientLocked {
            let restoreError = DischargeAdapterControl.restoreEnabled(
                client: client, attempts: Discharge.terminalRestoreAttempts
            )
            if let restoreError {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "放电动作监护缺失终止：CHIE 恢复失败（\(restoreError)），残留交 §2.4 不变量"
                ))
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "放电动作监护缺失终止：无控制后端，CHIE 恢复不可执行（残留交 §2.4 不变量）"
            ))
        }
        lastStatus?.lastAction = literal
        deleteActionFileLocked(events: &events)
        events.append(LogEvent(
            category: .control, level: .warn,
            message: "放电动作监护缺失 ≥\(Discharge.monitoringLossLimit) tick：已安全终止（\(literal)）"
        ))
    }

    /// sleepNow 专用放电取消（硬事实 5）：同步路径内恢复 CHIE 立即尝试 1 次
    /// （总尝试数 1 = 零重试；不阻塞 IOAllowPowerChange），余量交 §2.4 残留不变量
    /// 与唤醒兜底；不 enforce CHTE——睡眠策略随后照常自行判定。
    /// 审查 M3：daemon 发起的取消一律**锁存** cancel 字面量——App 轮询必见终态、
    /// 通知必发（不锁存会被下一常规 tick 的 enforce:xxx 覆盖，60s 轮询档漏发）。
    func cancelDischargeForSleepLocked(events: inout [LogEvent]) {
        guard actionTrack.action?.kind == Discharge.dischargeToLimitKind else { return }
        // 统一完成记录（五落点之二）：睡眠取消即记冷却——唤醒后再触发需冷却
        // 30min ∧ 适配器翻转，两门皆过才可（R1 P1-2 修订）。
        noteDischargeTerminatedLocked(now: Date())
        let literal = actionTrack.cancelLatched() ?? OneShotLiteral.cancel(kind: Discharge.dischargeToLimitKind)
        // 0.20.1 §2.1 事件落盘（挂钩表第五行·取消臂）：睡眠取消。
        Self.persistLog(DischargePersistEvent.cancelled(reason: "系统睡眠").message)
        // 0.20 M1a §2.2 #8：同 #6 门控改造——恢复写经控制面（27 经 CHIE 探测连接
        // 真实还原；26 tahoe 行为不变）。
        if let client = dischargeControlClientLocked {
            let restoreError = DischargeAdapterControl.restoreEnabled(
                client: client, attempts: Discharge.sleepNowRestoreAttempts
            )
            if let restoreError {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "睡眠取消放电：CHIE 恢复失败（\(restoreError)）——残留交 §2.4 残留不变量与唤醒兜底"
                ))
            } else {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "睡眠取消放电：已恢复适配器使能（CHIE=0x00）"
                ))
            }
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "睡眠取消放电：无控制后端，CHIE 恢复不可执行"
            ))
        }
        lastStatus?.lastAction = literal
        deleteActionFileLocked(events: &events)
    }

    /// 27 观测段自动放电插桩（0.20 M1a——autoDischarge 能力诚实化）：autoTriggerReady
    /// 判定与启动序列在执法段（DaemonCore.swift 自动触发臂）于 27 不可达，观测段
    /// 承接同款判定（判定链输入/优先序照执法段钉死：巡检命中 > 自动触发 > 编排链
    /// ——编排链对在轨动作本就静默，assertionRequest 规则 2 actionActive → none）。
    /// 判定链全过 → 锁内启动（locked 内部不 tick）；catch 记 warn 后返回（编排链
    /// 照常评估——失败臂无半启动态，残留无约束窗口 ≤1 tick，下 tick 全量收敛）。
    /// ⚠️ internal：performTickLocked（DaemonCore.swift）观测段跨文件调用——
    /// executable internal 模块外不可达，单一属主不变量不破。
    func autoDischargeObservationLocked(
        now: Date, snapshot: BatterySnapshot, client: SMCClient, events: inout [LogEvent]
    ) {
        guard Discharge.autoTriggerReady(
            enabled: policy.autoDischargeEnabled,
            mode: policy.mode,
            externalConnected: snapshot.externalConnected,
            percent: snapshot.percent,
            upperLimit: policy.upperLimit,
            actionActive: false,          // 本分支进入条件即 !actionTrack.isActive
            dischargeCapable: capabilities?.contains(DaemonXPC.capabilityDischarge) == true,
            now: now,
            lastAutoCompletion: lastAutoDischargeCompletedAt,
            adapterCycleSinceCompletion: adapterCycleSinceAutoCompletion
        ) else { return }
        do {
            if try dischargeToLimitLocked(now: now, initiator: .auto, events: &events) == .started {
                let actionName = maintainDischargeLocked(
                    now: now, snapshot: snapshot, client: client, events: &events
                )
                lastStatus?.lastAction = actionTrack.effectiveLastAction(actionName)
            }
        } catch {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "自动放电触发失败：\(error)"
            ))
        }
    }
}