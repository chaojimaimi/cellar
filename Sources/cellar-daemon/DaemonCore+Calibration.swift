import Foundation
import CellarCore

// MARK: - WP3 校准动作（方案 §2.2；全部锁内）

/// 校准动作的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 触及 800 行硬上限；
/// 可见性/属主不变量与 DaemonCore+OneShot.swift 同款：cellar-daemon 为 executable
/// target，internal 符号模块外不可达）。语义决策全部经 CellarCore.Calibration /
/// OneShotTrack 转移（CellarCoreCheck 矩阵穷举钉死），本扩展只做副作用（落盘/
/// 写 CHTE/写 CHIE、删文件、终态字面量落状态）与日志。
extension DaemonCore {
    /// startCalibration 锁内启动结果（照 DischargeStartOutcome 先例：仅 .started 才接管）。
    enum CalibrationStartOutcome {
        case started, alreadyActive
    }

    /// startCalibration XPC 臂（v1.4 拆分定版 UD-6）：取锁 → Locked 核（.manual，
    /// snapshot 传 nil → 核内走现序列自带新鲜快照+回落）→ **仅 .started 才即时
    /// tick**（首拍保活使能——现状语义零变化）→ buildStatusLocked。⚠️ NSLock 不可
    /// 重入：本臂取锁后调 Locked 版；tick 调度臂（已持锁）直调 Locked 版——两入口
    /// 共用同一副作用序列。
    func startCalibration() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        let outcome = try startCalibrationLocked(initiator: .manual, snapshot: nil, events: &events)
        if outcome == .started {
            // 即时 tick：首 tick 保活使能 + 首样本（lastStatus 不冻结，P1-2 同判例）。
            performTickLocked(events: &events)
        }
        return buildStatusLocked()
    }

    /// startCalibration 锁内核心（v1.4 UD-6 提取，现有锁内序列原样搬移；**绝不自取
    /// lock**——调用方必须已持锁，工单提示 1）：幂等拆分（在轨且 kind==calibration →
    /// .alreadyActive；在轨且 kind≠calibration → **上抛 .actionOccupied**——防 App
    /// 误弹「校准已启动」假成功）→ **fullOnce 临时放开窗互斥**（0.23.2 §1.5——置于
    /// 幂等拆分后、native guard 前；仅 27 可达，26 无窗位零变化）→ 能力守卫（XPC
    /// 纵深防御）→ 前置快照 + calibrationStartPrecondition → **原生限充守卫**
    /// （v1.7 M2，方案 §3.1：态机进入之前拒绝——无锚点写入；检测明确阻断 fail-closed，
    /// detectorError fail-open + warn；**0.23.2 §1.3：27 平台判别绕过——M1 同论证，
    /// 26 守卫逐值不变红线**）→ startIfIdle + setCalibrationPhase(.chargeFull)
    /// → actionStore.save（失败 → cancel + 上抛 persistenceFailed，锚点不写）→
    /// **记锚点 state.lastStartedAt**（UD-4：启动即记——手动+自动统一刷新；前置
    /// 不满足不写锚点——当日窗口内顺延重试）→ **27 启动序列**（0.23.2 §4.2——
    /// 进相域直写 100 一次，经 topoffExecuteWriteLocked 簿记包装）。单一 now 纪律
    ///（工单提示 2）：一次 `Date()` 贯穿 startIfIdle/setCalibrationPhase/锚点——
    /// 保证 `action.startedAt == state.lastStartedAt`（①② 记录与 ③ 去重键跨路径
    /// 不得有微秒级偏移，否则去重失效）。
    @discardableResult
    func startCalibrationLocked(
        initiator: Initiator, snapshot: BatterySnapshot?, events: inout [LogEvent]
    ) throws -> CalibrationStartOutcome {
        if actionTrack.isActive {
            if actionTrack.action?.kind == Calibration.kind {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "startCalibration 重复请求：校准已在进行中，回当前状态（幂等）"
                ))
                return .alreadyActive
            }
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "startCalibration 拒绝：其他动作进行中（actionOccupied——先完成或取消）"
            ))
            throw CalibrationStartRejection.actionOccupied
        }
        if fullOnceWindowActive {
            // 0.23.2 §1.5 互斥（fullOnce 侧对称拒因 = fullOnce 的 .actionOccupiedOn27
            // ——双向互斥）：窗内域写 100 充满与校准冲突，先恢复限充再校准。
            events.append(LogEvent(
                category: .control, level: .info,
                message: "startCalibration 拒绝：fullOnce 临时放开窗活跃（fullOnceActive——先恢复限充）"
            ))
            throw CalibrationStartRejection.fullOnceActive
        }
        guard capabilities?.contains(DaemonXPC.capabilityCalibration) == true else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "startCalibration 拒绝：能力缺失（capabilityUnavailable——App 已按能力隐藏）"
            ))
            throw CalibrationStartRejection.capabilityUnavailable
        }
        // 前置外接判定（R2 P3 snapshot 注入）：调度臂传本拍快照（免重复拍电池）；
        // XPC 臂传 nil → 现序列新鲜快照；失败回落上次已知值；均未知 → 拒绝（不无据启动）。
        let external: Bool?
        if let snapshot {
            external = snapshot.externalConnected
        } else {
            do {
                external = try monitor.snapshot().externalConnected
            } catch {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "startCalibration 前置：电池快照失败（\(error)），使用上次已知外接状态"
                ))
                external = lastStatus?.lastExternalConnected
            }
        }
        if let rejection = calibrationStartPrecondition(
            mode: policy.mode,
            externalConnected: external,
            actionActive: false,       // 本点已在幂等拆分放行（动作轨空闲）
            capabilityPresent: true    // 已由能力守卫拦截（XPC 纵深防御）
        ) {
            throw rejection
        }
        // Phase 5 v1.7 M2 原生限充守卫（方案 §3.1，precondition 之后 startIfIdle 之前
        // ——态机进入之前拒绝，无 startedAt/无锚点写入）：任何未终止且 <100 的原生
        // 策略都会卡死充满相（blockingPolicies 不限 reason，物理执法事实）。
        // 检测明确阻断 → 拒绝（fail-closed）；检测器自身故障（detectorError）→
        // 放行 + warn（fail-open 唯一边界——降级后果 = 充满相按既有 timeout 终态
        // 收敛，非新增机制）。两入口（手动 XPC 臂/调度臂）共用本锁内核心 → 单点
        // 守卫自动全覆盖；调度臂拒绝落 DaemonCore.swift 既有静默顺延 catch（零新增
        // 终态语义、零锚点写入）。
        // **0.23.2 §1.3 平台判别绕过（红 R3——与 fullOnce 27 绕过自相矛盾的修复）**：
        // 27 上 plist = 「任务注册残留」非现行上限（doctor 检查 15 口径——S4 实证
        // batteryui 镜像与 powerd plist 都不反映 shortcut 设定值），残留阻断会让校准
        // 在 27 永久不可用；绕过论证与 fullOnce 27 臂 M1 同型——域写 100 覆写 MCL，
        // 残留非物理执法。**26 守卫逐值不变（红线）**。判别式 = modernBackendTerminal
        // Locked（daemon 平台终态判别——与 fullOnceStartPrecondition 的 capabilities
        // 判别同语义：27 上 capabilityCalibration 仅经终态处置臂上报）。
        let nativeReading = NativeChargeLimit.load(
            rooted: try Data(contentsOf: NativeChargeLimit.powerdPoliciesURL)
        )
        if modernBackendTerminalLocked {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "startCalibration 前置：27 平台判别——原生守卫绕过（plist 注册残留非现行上限，域写 100 覆写 MCL；照 fullOnce 27 臂先例）"
            ))
        } else if nativeReading.detectorError {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "startCalibration 前置：原生限充检测失败（detectorError）——fail-open 放行（若确有原生限充，充满相将按超时收敛）"
            ))
        } else if !nativeReading.blockingPolicies.isEmpty {
            throw CalibrationStartRejection.nativeChargeLimit(socLimit: nativeReading.manualSocLimit)
        }
        let now = Date()
        _ = actionTrack.startIfIdle(now: now, kind: Calibration.kind, timeout: Calibration.totalDeadline)
        // 相位字段注入（startIfIdle 经 OneShot.onshotStart 构造，无相位概念；
        // deadline = now+24h 整体兜底——hold 相 24h 兜底判据，相位决策不用）。
        actionTrack.setCalibrationPhase(.chargeFull, startedAt: now)
        // 0.23.3 §4：chargeFull 域读回保活节流计数置零（每轮校准独立计拍——
        // 内存态，照 fullOnceFullTicks 复位纪律）。
        calibrationChargeFullReadbackTicks = 0
        // idle→active 原子持久化：写失败 → 动作不启动（上抛，App 原文上屏）。
        do {
            try actionStore.save(actionTrack.action!)
        } catch {
            _ = actionTrack.cancel()
            events.append(LogEvent(
                category: .control, level: .error,
                message: "startCalibration 启动失败：action.json 写入失败（\(error)）"
            ))
            throw CalibrationStartRejection.persistenceFailed
        }
        // 启动锚点（与 startIfIdle 同一 now——单一 now 纪律；UD-4）。
        calibrationState.lastStartedAt = Int(now.timeIntervalSince1970)
        persistCalibrationStateLocked(events: &events)
        // 0.23.2 §4.2 27 启动序列：进相域直写 100 一次（**经 topoffExecuteWriteLocked
        // 簿记包装**——成功回填 lastWrittenLimit/lastWriteAt，消「域 100 已生效但
        // lastWritten 缺席」的 10min 盲窗〔常规复核 P3〕）。写失败 → error 日志 +
        // chargeFull 相 6h 相位超时兜底（「静默充电」如实登记——不重试，下拍维护
        // 分支 chargeFull stay 无域写，超时收敛为唯一止损）。26 无此臂（窗内域写
        // 是 27 topoff 通道专属；26 chargeFull 相由 CHTE 保活执法——红线零触及）。
        // Topoff.shutdownLimit = 100（照 convergenceRoute fullOnceWindow 臂「完全
        // 放开」同常量先例）。
        if modernBackendTerminalLocked {
            if topoffExecuteWriteLocked(limit: Topoff.shutdownLimit, now: now, events: &events) {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "校准启动（27）：进相域直写 \(Topoff.shutdownLimit)（充满相完全放开——agent 分钟级跟随；hold 相零写浮充、恢复/中止臂域写回 target）"
                ))
            } else {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "校准启动（27）：进相域写 \(Topoff.shutdownLimit) 失败——chargeFull 相按 6h 相位超时兜底（静默充电窗口登记，方案 §4.2）"
                ))
            }
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "校准已启动（\(initiator == .manual ? "手动" : "自动调度")）：phase=chargeFull（充满 ≤6h → 静置 2h → 放电至 10%）"
        ))
        return .started
    }

    /// cancelCalibration XPC：用户取消（独立命令臂走鉴权门；实际副作用经
    /// cancelActionLocked 校准第三分支——kind 泛化统一取消路径全覆盖）。
    func cancelCalibration() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        if !actionTrack.isActive {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "取消校准：无活跃动作（幂等成功）"
            ))
            return buildStatusLocked()
        }
        // code-review P1-2：在轨动作非校准（fullOnce/放电）→ 幂等回状态，不取消
        // 他人动作——与 startCalibration 的 .actionOccupied 拆分对称（CLI 路径
        // `cellar calibrate cancel` 真实可达；App 取消按钮仅校准活跃时渲染）。
        if actionTrack.action?.kind != Calibration.kind {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "取消校准：在轨动作非校准（\(actionTrack.action?.kind ?? "?")），不取消（幂等成功）"
            ))
            return buildStatusLocked()
        }
        cancelActionLocked(events: &events)
        return buildStatusLocked()
    }

    /// 校准维护分支（performTickLocked 第 5 步校准分支 + 0.23.2 观测段校准维护
    /// 子分支共用；方案 §2.2 + 0.23.2 §4.3）：CHIE 保活读改写（放电相）→ 转移纯
    /// 函数 → 依输出执行副作用。返回本 tick 的 lastAction 字面量（相位字面量不
    /// 锁存——持续态字面量每 tick 返回当前相位；相位转移通知经 App 端
    /// notificationEvents 转移检测）。
    ///
    /// **0.23.2 双参数化**：`backend: (any ChargingBackend)?` + `client: SMCClient?`
    /// ——**26 分支逐行原样**（backend 非 nil 路径零语义变化——红线：CHTE 保活/
    /// hold 停充/TahoeBackend CHIE 读写全部原行）；27 分支（backend == nil，client
    /// 经 dischargeControlClientLocked/观测段路由保证在位）：
    /// - chargeFull：无 CH0B/CHTE 保活（进相域写 100 在启动序列一次性完成，stay
    ///   拍零写——完成判定走 calibrationTick 既有 fullyCharged 判据 + 6h 相位超时）；
    /// - hold：**零写**（域 100 浮充——语义差异 FAQ 登记；2h 时间转移既有）；
    /// - discharge：CHIE 保活读改写/回读/失败计数经 DischargeAdapterControl（
    ///   maintainDischargeLocked 27 同款——client 直挂、失败 noteControlFailureLocked
    ///   自愈计数）；≤10% 完成判定既有；
    /// - restoreAndComplete/abort：CHIE 恢复（restoreCalibrationCHIELocked 已
    ///   client 参数化）+ **域直写 target**（topoffExecuteWriteLocked 簿记包装——
    ///   26 走 enforceLimitChargingLocked 原行）+ 字面量既有。
    func maintainCalibrationLocked(
        now: Date,
        snapshot: BatterySnapshot,
        backend: (any ChargingBackend)?,
        client: SMCClient?,
        events: inout [LogEvent]
    ) -> String {
        guard let action = actionTrack.action else { return "enforce:noop" }
        let phase = action.phase.flatMap(Calibration.Phase.init(rawValue:))

        // CHIE 保活读改写（仅 discharge 相；语义 = maintainDischargeLocked 同款）：
        // 回读 == 0x08 → held；≠0x8（含 0x00 重置/未知值）→ 重写 0x8 后回读；
        // 任何失败 → failed（连续 3 次由转移函数 abort）。
        // 0.23.2 双参数化：26 走 backend（逐行原样）；27 走 DischargeAdapterControl
        // client 直挂（maintainDischargeLocked 27 同款——含失败自愈计数）。
        let chieStatus: DischargeKeepAliveStatus?
        if phase == .discharge {
            if let backend {
                do {
                    let enabled = try backend.adapterEnabled()
                    switch enabled {
                    case false:
                        chieStatus = .held
                    case true, nil:
                        do {
                            try backend.setAdapterEnabled(false)
                            let rechecked = try backend.adapterEnabled()
                            chieStatus = rechecked == false ? .rewritten : .failed
                        } catch {
                            noteControlFailureLocked(error, events: &events, context: "校准 CHIE 保活重写")
                            chieStatus = .failed
                        }
                    }
                } catch {
                    noteControlFailureLocked(error, events: &events, context: "校准 CHIE 保活回读")
                    chieStatus = .failed
                }
            } else if let client {
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
                            noteControlFailureLocked(error, events: &events, context: "校准 CHIE 保活重写")
                            chieStatus = .failed
                        }
                    }
                } catch {
                    noteControlFailureLocked(error, events: &events, context: "校准 CHIE 保活回读")
                    chieStatus = .failed
                }
            } else {
                // 防御：27 且控制面 client 缺席（启动守卫已保证可写——仅传输故障
                // 重建窗可达）→ failed 计数推进，连续 3 次由转移函数 abort 收口。
                chieStatus = .failed
            }
        } else {
            chieStatus = nil
        }

        let result = calibrationTick(CalibrationTickInput(
            percent: snapshot.percent,
            temperatureC: snapshot.temperatureC,
            externalConnected: snapshot.externalConnected,
            isCharging: snapshot.isCharging,
            fullyCharged: snapshot.fullyCharged,
            now: now,
            phase: phase,
            phaseStartedAt: action.phaseStartedAt,
            deadline: action.deadline,
            debounceTicks: actionTrack.debounceTicks,
            keepAliveFailures: actionTrack.keepAliveFailures,
            chieStatus: chieStatus
        ))
        // 计数器回写（转移纯函数不持有状态；结果经轨道方法落回——单一属主不变量）。
        actionTrack.applyCalibrationCounters(
            debounceTicks: result.debounceTicks, keepAliveFailures: result.keepAliveFailures
        )

        switch result.output {
        case .stay(let phase):
            // 保活副作用按相位：chargeFull → CHTE 保活使能（26）；hold → 写停充
            // （回读非停充才写——满电停充维持，26）；discharge → CHIE 保活写 0x8
            // （已由上方读改写完成，此处避免双重写）。
            // 0.23.2 27 分支：chargeFull/hold 均零写（域 100 浮充——进相域写在启动
            // 序列一次性完成；无 CHTE/CH0B 键族，保活面不存在，方案 §4.3）。
            switch phase {
            case .chargeFull:
                // v1.5 UD-5：chargeFull 相保活同入热守卫（盲区收编——本拍快照
                // 温度穿透，三分支判定与 fullOnce 保活同源）。
                if let backend {
                    keepAliveChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
                } else {
                    // 0.23.3 §4 27 chargeFull stay 拍域读回保活（回读门）——
                    // 节流读域 + 失配重写，见 calibrationChargeFullReadbackKeepAliveLocked。
                    calibrationChargeFullReadbackKeepAliveLocked(now: now, events: &events)
                }
            case .hold:
                if let backend {
                    holdLimitChargingLocked(backend: backend, events: &events)
                }
            case .discharge:
                break
            }
            return CalibrationLiteral.phase(phase)

        case .advance(let to):
            // 相位推进（四步副作用次序见 advanceCalibrationLocked；失败臂内存
            // 相位不推进 → 本 tick 返回当前相位字面量，下 tick 幂等重试全序列）。
            _ = advanceCalibrationLocked(to: to, now: now, backend: backend, client: client, events: &events)
            let current = actionTrack.action?.phase.flatMap(Calibration.Phase.init(rawValue:))
                ?? phase ?? .chargeFull
            return CalibrationLiteral.phase(current)

        case .restoreAndComplete:
            // RESTORE：CHIE 恢复（重试阶梯）→ 恢复限充语义（26 enforce CHTE；
            // 0.23.2 27 域直写 target——簿记包装，通知说恢复即现状收敛）→ done
            // 字面量锁存 + 删文件。
            restoreCalibrationCHIELocked(terminal: "完成", events: &events)
            if let backend {
                enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            } else {
                // 0.23.2 §4.3 27 恢复臂：域直写 target（校准期域被推至 100——恢复
                // 即写回，消「等下拍观测 tick 卫生臂」的盲窗；lastWrittenLimit 回填
                // 后汇聚点幂等）。写失败不阻断终态（下拍卫生臂幂等重写兜底）。
                _ = topoffExecuteWriteLocked(limit: policy.upperLimit, now: now, events: &events)
            }
            let literal = actionTrack.terminateCalibration(CalibrationLiteral.done())
            deleteActionFileLocked(events: &events)
            return literal

        case .abort(let reason, let safety):
            // 中止：曾入 discharge 相（CHIE=0x8 在场）→ CHIE 恢复（重试阶梯）；
            // 恢复限充语义（26 enforce CHTE / 0.23.2 27 域直写 target）→ safety ?
            // calibration:safety 锁存 : 按原因落 timeout/cancel 字面量 + 删文件。
            if phase == .discharge {
                restoreCalibrationCHIELocked(terminal: "中止(\(reason))", events: &events)
            }
            if let backend {
                enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)
            } else {
                // 0.23.2 §4.3 27 中止臂：域直写 target（同恢复臂——chargeFull/hold
                // 中止时域在 100，discharge 中止时域亦需回落）。
                _ = topoffExecuteWriteLocked(limit: policy.upperLimit, now: now, events: &events)
            }
            let literal: String
            if safety {
                literal = CalibrationLiteral.safety()
            } else if reason == CalibrationLiteral.AbortReason.timeout {
                literal = CalibrationLiteral.timeout()
            } else {
                literal = CalibrationLiteral.cancel()
            }
            let latched = actionTrack.terminateCalibration(literal)
            deleteActionFileLocked(events: &events)
            return latched
        }
    }

    /// 0.23.3 §4 27 校准 chargeFull stay 拍域读回保活（**回读门，非簿记门**——
    /// 终判 P1 修正，方案 §4 钉死）。
    ///
    /// **为何簿记门不行（坏序论证，照方案 §4 入注释）**：簿记门比对
    /// `topoffState.lastWrittenLimit`（daemon 自己的写入簿记）——坏序 = 启动序列
    /// 写 100（簿记置 100）→ W3 对账臂在途写 80 派发先于校准启动、落地晚于启动
    /// 写（App 直写 MCL 域，**不动 daemon 簿记**）→ 实际 MCL=80 ∧ 簿记=100 →
    /// 簿记比对恒等、门永不触发 → MCL 钉 80 无重写臂，chargeFull 相 6h 超时
    /// 止损前校准全程失效。回读门读**域实际态**（TopoffWriter.read），两序皆
    /// 闭合：无论在途写先落还是后落，只要域被外部改写，下一节流拍读回即失配
    /// 即重写；顺带覆盖 chargeFull 期间一切外部覆写（含机制关闭态的自愈重开）。
    ///
    /// 节流：每 `Calibration.chargeFullReadbackStride`（N=10）拍读一次域
    /// （tick 30s → 读回节奏 5 min，chargeFull ≤6h → ≤72 次，子进程开销有界；
    /// 失配才重写 {100,1}——`topoffExecuteWriteLocked` 簿记包装，回填
    /// lastWrittenLimit）。读失败（外层 nil）fail-open 不重写（照 topoff 读回
    /// 纪律——防持久读故障下的重写风暴）；hold 相维持零写（浮充语义不变）。
    /// 26 零触及（本 helper 仅 backend == nil 的 27 分支可达——26 走 CHTE 保活）。
    func calibrationChargeFullReadbackKeepAliveLocked(now: Date, events: inout [LogEvent]) {
        calibrationChargeFullReadbackTicks += 1
        guard calibrationChargeFullReadbackTicks % Calibration.chargeFullReadbackStride == 0 else {
            return
        }
        guard let readback = TopoffWriter.read(run: Self.runProcessCapture) else {
            Self.persistLog("校准 chargeFull 域读回失败（fail-open——不重写，下个节流拍再试）")
            return
        }
        guard Calibration.chargeFullReadbackMismatch(
            limit: readback.limit, featureState: readback.featureState
        ) else {
            Self.persistLog("校准 chargeFull 域读回（节流拍 #\(calibrationChargeFullReadbackTicks)）：签名一致（域 100 在位）→ 零写")
            return
        }
        Self.persistLog("校准 chargeFull 域读回：失配（limit=\(readback.limit.map(String.init) ?? "缺席") featureState=\(readback.featureState.map(String.init) ?? "缺席") ≠ (100, 1)）→ 重写 {100,1}（回读门闭合——在途 W3 写晚落/外部覆写两序皆覆盖）")
        _ = topoffExecuteWriteLocked(limit: Topoff.shutdownLimit, now: now, events: &events)
    }

    /// 相位推进副作用（方案 §2.2 次序钉死，失败臂按臂注记）：
    /// ① `actionStore.save`（phase/phaseStartedAt 落盘——崩溃恢复按相位恢复 CHIE
    ///    的精确性前提；失败记 error **继续**，内存态推进，残留交启动崩溃恢复兜底）；
    /// ② 仅 hold→discharge：先 `controller.perform(.enableCharging)` 撤停充——失败臂
    ///    **钉死（R2 P2-1）**：本 tick **不写 CHIE、内存相位不推进**（维持 hold 语义）、
    ///    记 error + `noteControlFailureLocked` 自愈；推进条件持续成立 → 下 tick 幂等
    ///    重试全序列（save 覆盖写）；「盘上 discharge / 内存 hold」窗口由重试或崩溃
    ///    恢复收口（恢复按 discharge 多余恢复一次 CHIE，fail-closed 无害）。**严禁
    ///    ② 失败继续 ③**——「CHTE=停充 × CHIE=0x8」未测胞照样进入即挫败本序目的；
    ///    **0.23.2 27 分支：② 撤停充跳过**（backend nil——CHTE 键族 27 缺席，放电前
    ///    无需 CHTE，照 dischargeToLimitLocked 27 跳过先例，仅落 info 日志）；
    /// ③ 仅 hold→discharge：写 CHIE=0x8 + 回读（对齐 dischargeToLimitLocked 启动
    ///    序列；失败 → 记 error，相位同样不推进——CHIE 写入态未知，下 tick 重试全
    ///    序列）。**0.23.2 双参数化**：26 经 backend（逐行原样）；27 经
    ///    DischargeAdapterControl（client 直挂——maintainDischarge 27 同款）；
    ///    client 缺席 → 失败不推进（防御——启动守卫已保证可写）；
    /// ④ 更新轨道 action 字段（内存相位推进）。
    /// 返回是否推进成功（调用方据此输出当前相位字面量）。
    @discardableResult
    private func advanceCalibrationLocked(
        to: Calibration.Phase, now: Date,
        backend: (any ChargingBackend)?, client: SMCClient?,
        events: inout [LogEvent]
    ) -> Bool {
        // ① 落盘（先更新内存字段再 save——save 的内容 = 推进后的相位/相位起始）。
        var pending = actionTrack.action
        pending?.phase = to.rawValue
        pending?.phaseStartedAt = now
        do {
            if let pending { try actionStore.save(pending) }
        } catch {
            events.append(LogEvent(
                category: .lifecycle, level: .error,
                message: "校准相位推进：action.json 写入失败（\(error)）——内存态继续推进（崩溃恢复兜底）"
            ))
        }
        if to == .discharge {
            // ② 撤停充（hold→discharge 前置——CHTE=0 放行充电与 CHIE=0x8 之间无
            // 未测胞窗口：撤停充成功才写 CHIE）。0.23.2：27 跳过（CHTE 键族缺席
            // ——放电前无需 CHTE，dischargeToLimitLocked 27 跳过先例）。
            if let backend {
                do {
                    _ = try controller.perform(.enableCharging, backend: backend)
                } catch {
                    noteControlFailureLocked(error, events: &events, context: "校准推进撤停充")
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "校准相位推进：撤停充失败——本 tick 不写 CHIE、相位不推进（维持 hold，下 tick 幂等重试全序列）"
                    ))
                    return false
                }
            } else {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "校准相位推进（27）：跳过 CHTE 撤停充（控制键不在位，放电前无需 CHTE）"
                ))
            }
            // ③ CHIE=0x8 写 + 回读校验。0.23.2 双参数化：26 经 backend（逐行原样）；
            // 27 经 DischargeAdapterControl client 直挂（失败同样相位不推进——下
            // tick 幂等重试全序列，残留交 §2.4 巡检）。
            if let backend {
                do {
                    try backend.setAdapterEnabled(false)
                    let state = try backend.adapterEnabled()
                    guard state == false else {
                        throw BackendError.verifyFailed(key: "CHIE", desired: false, actual: state ?? true)
                    }
                } catch {
                    noteControlFailureLocked(error, events: &events, context: "校准推进 CHIE 写")
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "校准相位推进：CHIE=0x08 写入/回读校验失败（\(error)）——相位不推进（下 tick 重试，残留交 §2.4 巡检）"
                    ))
                    return false
                }
            } else if let client {
                do {
                    try DischargeAdapterControl.setAdapterEnabled(false, client: client)
                    let state = try DischargeAdapterControl.adapterState(client: client)
                    guard state == false else {
                        throw BackendError.verifyFailed(key: "CHIE", desired: false, actual: state ?? true)
                    }
                } catch {
                    noteControlFailureLocked(error, events: &events, context: "校准推进 CHIE 写")
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "校准相位推进（27）：CHIE=0x08 写入/回读校验失败（\(error)）——相位不推进（下 tick 幂等重试全序列，残留交 §2.4 巡检）"
                    ))
                    return false
                }
            } else {
                // 防御：27 且控制面 client 缺席（启动守卫已保证可写——仅传输故障
                // 重建窗可达）→ 相位不推进，下 tick 幂等重试。
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "校准相位推进（27）：控制面 client 缺席——不写 CHIE、相位不推进（下 tick 幂等重试全序列）"
                ))
                return false
            }
        }
        // ④ 内存相位推进。
        actionTrack.setCalibrationPhase(to, startedAt: now)
        events.append(LogEvent(
            category: .control, level: .info,
            message: "校准相位推进：→ \(to.rawValue)（\(now.description)）"
        ))
        return true
    }

    /// hold 相保活停充（写 CHTE 停充——回读非停充才写；失败走自愈计数，下 tick 重试）。
    private func holdLimitChargingLocked(backend: any ChargingBackend, events: inout [LogEvent]) {
        let enabled: Bool
        do {
            enabled = try backend.chargingEnabled()
        } catch {
            noteControlFailureLocked(error, events: &events, context: "校准 hold 保活回读")
            return
        }
        guard enabled else { return }
        do {
            _ = try controller.perform(.disableCharging, backend: backend)
            events.append(LogEvent(
                category: .control, level: .info,
                message: "校准 hold 相：满电停充维持（写 CHTE 停充 + 回读校验通过）"
            ))
        } catch {
            noteControlFailureLocked(error, events: &events, context: "校准 hold 保活停充")
        }
    }

    /// 校准终态/取消恢复 CHIE=0x0（写 + 回读校验重试阶梯——写失败 ≠ 恢复完成，
    /// 红线 5：失败告警后终态照常落盘，残留交 §2.4 CHIE 残留不变量兜底）。
    /// 0.20 M1a：DischargeAdapterControl client 参数化随迁——控制面 client 经
    /// dischargeControlClientLocked（26 tahoe 路径同一 client 同字节，行为不变；
    /// 校准能力门控保证 27 不会出现在轨校准，client 缺席臂为防御）。
    /// internal：cancelActionLocked（DaemonCore+OneShot.swift）跨文件调用。
    /// 0.21.0 §2 code-review P1-1：本函数是校准侧 CHIE 恢复**集中点**——迟滞簿记在
    /// 此失效（CHHysteresis.noteExternalAdapterWrite；失效先于恢复写——写失败残留
    /// 0x8 同样自愈。0.21 校准能力门控下 27 无在轨校准，本路径为防御纵深——放电侧
    /// noteDischargeTerminatedLocked 同款纪律）。
    func restoreCalibrationCHIELocked(
        terminal: String, events: inout [LogEvent]
    ) {
        if hysteresisState.lastWrittenAdapterEnabled != nil {
            hysteresisState = CHHysteresis.noteExternalAdapterWrite(state: hysteresisState)
            Self.persistLog("校准终态（\(terminal)）：CHIE 迟滞簿记已失效（动作轨恢复 0x00 为外部写——下拍按实况重估）")
        }
        guard let client = dischargeControlClientLocked else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "校准 \(terminal)：无控制后端，CHIE 恢复不可执行（残留交 §2.4 残留不变量巡检）"
            ))
            return
        }
        let restoreError = DischargeAdapterControl.restoreEnabled(
            client: client, attempts: Discharge.terminalRestoreAttempts
        )
        if let restoreError {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "校准 \(terminal)：CHIE 恢复写失败（\(restoreError)——重试阶梯耗尽），残留交 §2.4 残留不变量巡检"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "校准 \(terminal)：已恢复适配器使能（CHIE=0x00，回读校验通过）"
            ))
        }
    }

    /// 崩溃恢复专用（DaemonCore.startup）：校准动作残留按相位恢复 CHIE——discharge
    /// 相（CHIE=0x8 可能在场）必须恢复；相位缺失/未知串 → **无条件恢复（fail-closed，
    /// 一次多余 SMC 写无害，R1 P2-3）**；chargeFull/hold 相无需恢复。通知经
    /// adoptForCrashRecovery 的 cancel(crash-recovery) 锁存字面量由 App 轮询转移补发。
    /// 0.20 M1a：DischargeAdapterControl client 参数化随迁（控制面可写判据——26
    /// tahoe 同一 client 同字节行为不变；27 终态机上残留经 CHIE 探测连接真实还原）。
    func restoreCalibrationAfterCrashLocked(_ pending: OneShotAction, events: inout [LogEvent]) {
        let phase = pending.phase.flatMap(Calibration.Phase.init(rawValue:))
        guard (phase == .discharge || phase == nil), let client = dischargeControlClientLocked else {
            return
        }
        let restoreError = DischargeAdapterControl.restoreEnabled(
            client: client, attempts: Discharge.terminalRestoreAttempts
        )
        if let restoreError {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "崩溃恢复：校准动作残留，CHIE 恢复失败（\(restoreError)）——残留交 §2.4 不变量"
            ))
        } else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "崩溃恢复：校准动作残留（phase=\(pending.phase ?? "未知")），已恢复 CHIE=0x00"
            ))
        }
    }
}