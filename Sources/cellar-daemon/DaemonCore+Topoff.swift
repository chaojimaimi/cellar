import Foundation
import CellarCore

// MARK: - WP2 topoffprotection <80% 限充通道（daemon 侧；方案 §3 全部）
//
// 扩展文件拆分（DaemonCore.swift 800 行纪律；可见性/属主惯例同 DaemonCore+Discharge：
// cellar-daemon 为 executable target，internal 符号模块外不可达）。语义决策全部经
// CellarCore.Topoff（convergenceRoute/channelTick/healTick——CellarCoreCheck 场景域
// 钉死），本扩展只做副作用（域写/通知/簿记/日志）与路由消费。
//
// 平台门控：全部消费点以 capabilities 含 "sub80" 为门（仅 27 终态上报——M1a 矩阵）；
// 26 及更早零触及（26 行为零变化红线）。topoff 同受 mode/actionActive 门（执法总开关），
// 不受编排开关门（§3.1 门语义）。
extension DaemonCore {
    /// chargingDisabled 在窗判定（§3.1 汇聚目标派生输入——等价「完全放开」窗口）。
    /// ⚠️ 锁内只读谓词（调用方持主锁）；0.21.1 §1.1 门 b 起观测段自动放电共享
    /// 同一判定（单一真相——原 topoffConvergenceRouteLocked 内联计算原位收编）。
    var chargingDisabledWindowActiveLocked: Bool {
        scheduleState.lastAppliedEntryId != nil
            && policy.schedule?.entries.first(where: { $0.id == scheduleState.lastAppliedEntryId })?
                .chargingDisabled == true
    }

    /// 汇聚点双通道路由消费（orchestrationTickLocked 内、applyScheduleTransitionLocked
    /// 之后调用——§3.1 路由挂点）。返回编排断言目标 desired（nil = 编排静默）；
    /// topoff 副作用（域写/验证/重申/降级/自愈/卫生/关断清理）在本方法内完成。
    ///
    /// 次序契约：路由判定（纯函数）→ topoff 副作用 → 返回 desired 给断言链——
    /// 副作用先行不改变断言输入（desired 在纯函数内已定）。
    func topoffConvergenceRouteLocked(
        now: Date, snapshot: BatterySnapshot, events: inout [LogEvent]
    ) -> Int? {
        let sub80Capable = capabilities?.contains(DaemonXPC.capabilitySub80) == true
        // chargingDisabled 在窗判定（§3.1 汇聚目标派生输入——等价「完全放开」窗口）。
        let chargingDisabledWindowActive = chargingDisabledWindowActiveLocked
        // 0.21.0 §3.1 校准窗口识别（模式指纹；决策纯函数 CalibrationCoexistence.tick
        // ——CellarCoreCheck 场景域钉死）。本函数调用点在 orchestrationTickLocked
        //（27 终态门控）——26 执法段/瞬态窗口零触及（红线：26 平台正常路径零变化）。
        // 完全放开窗（fullOnce 临时放开窗 ∨ chargingDisabled 日程窗）惰性拍——窗内
        // 充到 100 是显式意图，指纹不推进不进出（防误报「target=100 永不满足」的窗
        // 形态推广）。边沿副作用：识别命中拍同步清零 violationTicks（R1-P2-4：识别
        // 10 tick < strike 验证窗 20 tick——校准证据优先于违规证据；非持久化字段，
        // 零落盘面）+ 进出 persistLog（§3.2 可观测——daemon.log 持久轨迹 + LogEvent 环）。
        let fullOpenWindowActive = orchestrationState.fullOnceWindowActive
            || chargingDisabledWindowActive
        let calibrationTick = CalibrationCoexistence.tick(
            state: calibrationCoexistenceState,
            percent: snapshot.percent,
            externalConnected: snapshot.externalConnected,
            isCharging: snapshot.isCharging,
            target: policy.upperLimit,
            fullOpenWindow: fullOpenWindowActive
        )
        calibrationCoexistenceState = calibrationTick.state
        if calibrationTick.risingEdge {
            topoffState.violationTicks = 0
            let message = "校准抑制进入：模式指纹命中（≥\(CalibrationCoexistence.percentGate)% ∧ 外接 ∧ 充电 ∧ target ≤ \(CalibrationCoexistence.targetGate) 持续 \(CalibrationCoexistence.detectionTicks) tick）——strike/轻量重申/域随写/编排断言暂停，校准结束自动恢复（识别误报可能：模式识别非公开信号，方案 §3.2 诚实边界）"
            Self.persistLog("校准共存：\(message)")
            events.append(LogEvent(category: .control, level: .info, message: message))
        } else if calibrationTick.fallingEdge {
            let message = "校准抑制退出：指纹失效（percent < \(CalibrationCoexistence.percentGate) ∨ target > \(CalibrationCoexistence.targetGate)）——既有链恢复（下拍幂等重写/断言对账）"
            Self.persistLog("校准共存：\(message)")
            events.append(LogEvent(category: .control, level: .info, message: message))
        }
        // 0.21.0 §2.2：迟滞 tick 消费（**sub80 门内——26 零触及**；置于路由计算之前，
        // convergenceRoute 以本拍挂载结论为输入——挂载/退出同拍反映到 desired，
        // 消编排钳 80 与迟滞压 75 的跨拍互搏窗）。fullOnce 临时放开窗并入退出臂
        // （语义同 chargingDisabled 窗——「完全放开」期充到 100 是预期，迟滞执法
        // 75 会对抗放开，§1.3）。
        // ⚠️ 登记局限（code-review P3-3，接受不修）：本调用先于 healTick——探针
        // **启动拍**（healTick 内 healProbeActive 翻 true）本拍迟滞照常执法，迟滞
        // 翻转可能污染探针**首拍**观察（后续 19 拍静默互斥不受影响；最坏探针首拍
        // 弱信号 → 20 tick 无差别超时臂良性收口）。缝隙 = 1 拍 30s，自愈必经路径
        // 语境下代价可接受；消除需 tick 内二次求序，复杂度不值。
        if sub80Capable {
            hysteresisTickLocked(
                snapshot: snapshot,
                chargingDisabledWindow: chargingDisabledWindowActive,
                fullOnceWindow: orchestrationState.fullOnceWindowActive, events: &events
            )
        }
        let route = Topoff.convergenceRoute(
            modeActive: policy.mode == "active",
            orchestrationEnabled: policy.orchestrationEnabled == true,
            chargingDisabledWindow: chargingDisabledWindowActive,
            upperLimit: policy.upperLimit,
            sub80Capable: sub80Capable,
            actionActive: actionTrack.isActive,
            degraded: topoffState.degraded,
            healProbeActive: topoffState.healProbeActive,
            // 0.21.0 §1.3：fullOnce 临时放开窗——汇聚目标/断言目标强制 100（等价
            // 「完全放开」：域随写 100 防 agent 层对抗 App set；断言防 valueChange
            // 回拉 policy 值）。
            fullOnceWindow: orchestrationState.fullOnceWindowActive,
            // 0.21.0 §2.1 迟滞路由（R1-P1-4）：迟滞 active → desired=nil（编排静默）。
            hysteresisEnabled: policy.chHysteresisEnabled == true,
            hysteresisActive: hysteresisState.mounted,
            // 0.21.0 §3.1 校准抑制路由（R1-P1-5 臂②）：抑制态 → desired=nil
            //（App set 断言静默——降级钳 80 与 80-90 主力区间 enforcement 一并静默）。
            calibrationSuspected: calibrationCoexistenceState.suspected
        )
        guard sub80Capable else { return route.orchestrationDesired }   // 非 sub80 机：零行为（26 回归锚）
        // 0.20.2 §2 诚实性状态持久化：**写入点钉在 sub80 门内**（26 平台不生成
        // 状态文件——红线）。defer 收口本方法全部变更路径；触发源判定
        // （strike / 降级跳变 / off 关断）在 helper 内经 Topoff 纯函数承担，域写
        // 不触发（R2-P3）。主锁内 tmp+rename 直写（本方法调用方均持主锁）。
        let honestyBefore = topoffState
        defer { persistTopoffHonestyStateLocked(previous: honestyBefore) }
        // 0.20.1 观测性：每 tick 一行持久轨迹（wedge 事件教训——LogEvent 内存环随进程
        // 消失致事后不可溯源；本行落 daemon.log，卡死时最后一行即 wedge 现场）。
        Self.persistLog("topoff tick：target=\(route.convergenceTarget.map(String.init) ?? "nil") owned=\(route.topoffOwned) desired=\(route.orchestrationDesired.map(String.init) ?? "nil") percent=\(snapshot.percent) charging=\(snapshot.isCharging) ext=\(snapshot.externalConnected) degraded=\(topoffState.degraded) off=\(topoffState.off) lastWritten=\(topoffState.lastWrittenLimit.map(String.init) ?? "nil")")
        // §3.7 关断清理状态不变量（0.21.1 §2.2 重定版——**仅 mode 非 active 臂**）：
        // mode 非 active → 域随写 100 + off（幂等，守卫允许带 off 重试直至写成功）。
        // 覆盖：disable/SIGHUP/退出恢复事件路径、**重启 fresh 角点**（mode 非 active
        // ∧ topoffState fresh → 首拍清理）、事件钩子写失败后的逐拍重试——「残留域值
        // 不滞留执法」不变量。
        // 0.21.1 §2.2：**编排关 ∧ target ≥80 清理臂删除**（原第二条件）——域随写
        // 语义一致化：target 落入下方 §3.6 域随写卫生分支随写 target，编排关不断域
        // （消除域 100 顶掉用户系统 MCL + 乒乓循环的第①层根因，方案 §0.2/§2.1）。
        // 26 定谳（方案 §4.5）：本函数 `guard sub80Capable` 先行于本守卫——删除为
        // 27-only 变更，26 红线无虞。
        guard let convergenceTarget = route.convergenceTarget else {
            topoffShutdownCleanupLocked(now: now, events: &events)
            return route.orchestrationDesired
        }
        // 0.21.0 §3.1 三臂抑制消费（R1-P1-5——计划纯函数 CalibrationCoexistence.
        // suppressionPlan 钉面，CellarCoreCheck 场景域钉死）：校准态 topoff 臂全部
        // 静默——① strike 验证窗不推进（channelTick/healTick 不调用——自愈探针观察
        // 同冻结：校准期 percent ≥95 充电本身构成违规证据形态，推进必致误 strike/
        // 误降级/误 heal-fail 写 80 对抗校准）∧ 超带轻量重申不发（notifyOnly 随之
        // 静默）；③ 域随写卫生暂停（校准需要充满 100——域值随写会钉住 agent 停充；
        // 退出拍后既有链恢复，首拍幂等重写/断言对账停摆期漂移）。stale pending 撤销
        // 保留（单通道互斥簿记——防抑制窗内 App 消费陈旧断言对抗校准）。mode
        // 关断清理（上方不变量——0.21.1 起仅 mode 臂，编排开关关断不再清理）优先级更高——硬关断不受校准抑制影响；**完全放开窗
        // 豁免**（窗内各臂天然指向 100——抑制会冻结域随写 100 的对账写，纯函数钉面）。
        let suppression = CalibrationCoexistence.suppressionPlan(
            suspected: calibrationCoexistenceState.suspected,
            fullOpenWindow: fullOpenWindowActive
        )
        if suppression.suspendTopoffArms {
            if route.topoffOwned { discardStaleOrchestrationPendingLocked(events: &events) }
            return route.orchestrationDesired
        }
        if route.topoffOwned {
            // 通道承载（<80）：off 清除（重新承载）→ 单通道互斥簿记 → 状态机推进。
            if topoffState.off { topoffState.off = false }
            discardStaleOrchestrationPendingLocked(events: &events)
            let plan = topoffState.degraded
                ? Topoff.healTick(
                    state: topoffState, target: convergenceTarget, now: now,
                    percent: snapshot.percent,
                    externalConnected: snapshot.externalConnected,
                    isCharging: snapshot.isCharging)
                : Topoff.channelTick(
                    state: topoffState, target: convergenceTarget, now: now,
                    percent: snapshot.percent,
                    externalConnected: snapshot.externalConnected,
                    isCharging: snapshot.isCharging)
            topoffState = plan.state
            if let limit = plan.writeLimit {
                _ = topoffExecuteWriteLocked(limit: limit, now: now, events: &events)
            }
            // 0.20.2 §3 超带轻量重申消费：仅 notifyutil **独立轻调用** + persistLog
            // 一行——不走 topoffExecuteWriteLocked 的域写路径、**不动 strikes/
            // violationTicks/20 tick 验证窗与 strike×3 降级**（三套机制并行独立，
            // 验证窗满仍走 strike 原路径；语义边界方案 §3 钉死）。
            if plan.notifyOnly {
                let notified = Self.runProcessCapture(
                    "/usr/bin/notifyutil", ["-p", Topoff.notifyName]
                ).exitCode == 0
                Self.persistLog(notified
                    ? "topoff 轻量重申：通知已发（域值未变）"
                    : "topoff 轻量重申：通知发送失败（域值未变——strike 管道 10 min 兜底）")
            }
            return route.orchestrationDesired
        }
        // 动作活跃（放电/校准）→ 域写一并静默（维护分支掌权——域值由终态后同拍
        // 汇聚恢复，防动作期无谓写抖动）。
        guard !actionTrack.isActive else { return route.orchestrationDesired }
        // ≥80（含 chargingDisabled 窗 100）：§3.6 域随写卫生——域值同步随写至汇聚
        // 目标（先值后态 + 通知；消除稳态互搏 + ≥80 双保险，含 fresh 首 tick 的
        // 0.19.20 实验期域残留同步）。**0.21.1 §2.2 起可达性 = mode active ∧ 无动作**
        // ——域随写覆盖全区间、**不受编排开关门**（本修法把被守卫分支违反的架构
        // 自述不变量——文件头「topoff 不受编排开关门」——修回对齐；编排关 ∧ ≥80
        // 不再走关断清理，域随写 target 即「域恢复滞回」根治面，target 100 场景
        // 域随写 100 与旧清理写 100 同值但语义=随写非退出）。26 平台无此卫生（sub80 门）。
        if topoffState.off { topoffState.off = false }
        if topoffState.lastWrittenLimit != convergenceTarget {
            _ = topoffExecuteWriteLocked(limit: convergenceTarget, now: now, events: &events)
        }
        return route.orchestrationDesired
    }

    /// 单通道互斥簿记：topoff 承载时撤销在轨编排断言（pending）——防 App 消费陈旧
    /// 断言与 topoff 域值短暂互搏（迟到回报 token 不匹配自然丢弃）。
    private func discardStaleOrchestrationPendingLocked(events: inout [LogEvent]) {
        guard orchestrationState.hasOutstanding else { return }
        orchestrationState.pendingToken = nil
        orchestrationState.pendingTarget = nil
        events.append(LogEvent(
            category: .control, level: .info,
            message: "topoff 通道承载：已撤销在轨编排断言（单通道互斥——陈旧 pending 与域值互搏防护）"
        ))
    }

    /// 域写入执行（TopoffWriter 接线：defaults/notifyutil 子进程；daemon root 上下文）。
    /// 成功 → lastWritten/lastWriteAt 簿记（幂等重写判定输入）+ 失败连计清零（P3-1
    /// 恢复日志）；失败 → 不簿记（下 tick needsWrite 幂等重写）+ **降频日志**（P3-1：
    /// 首条 error、后续合并计数 warn）。返回写入是否成功（P3-2 清理 off 置位条件）。
    @discardableResult
    private func topoffExecuteWriteLocked(
        limit: Int, now: Date, events: inout [LogEvent]
    ) -> Bool {
        let outcome = TopoffWriter.write(limit: limit, run: Self.runProcessCapture) { name in
            Self.runProcessCapture("/usr/bin/notifyutil", ["-p", name]).exitCode == 0
        }
        switch outcome {
        case .written(let notified):
            let recoveryNote = topoffWriteFailureStreak > 0
                ? "（写入恢复——此前连续失败 \(topoffWriteFailureStreak) 次）" : ""
            topoffWriteFailureStreak = 0
            topoffState.lastWrittenLimit = limit
            topoffState.lastWriteAt = now
            let notifyText = notified ? "已发" : "发送失败"
            Self.persistLog("topoff 域已写：mclLimitValue=\(limit)（通知\(notifyText)）\(recoveryNote)")
            events.append(LogEvent(
                category: .control, level: .info,
                message: "topoff 域已写：mclLimitValue=\(limit)（MCLFeatureState=1，先值后态；通知\(notifyText)——agent 分钟级跟随兜底）\(recoveryNote)"
            ))
            return true
        case .failed(let detail):
            topoffWriteFailureStreak += 1
            let firstFailure = topoffWriteFailureStreak == 1
            Self.persistLog("topoff 域写入失败第 \(topoffWriteFailureStreak) 次：\(detail)")
            events.append(LogEvent(
                category: .control, level: firstFailure ? .error : .warn,
                message: firstFailure
                    ? "topoff 域写入失败：\(detail)——下 tick 幂等重写（两笔未全成功不通知，§3.3 原子序）"
                    : "topoff 域写入连续失败第 \(topoffWriteFailureStreak) 次（\(detail)）——幂等重写中（日志降频）"
            ))
            return false
        }
    }

    /// 0.20.2 §2 诚实性状态持久化（主锁内直写——tmp+rename 原子替换，单写者 =
    /// tick 持锁线程；写入点钉在 sub80 门内，26 不生成状态文件）。触发源判定经
    /// Topoff.shouldPersistHonestyChange 纯函数（strike / 降级跳变 / off 关断任一
    /// 跳变即写，lastViolationAt/lastHealProbeAt 随同拍五字段快照落盘；域写与观察
    /// 窗簿记不触发——R2-P3，低频）。写失败仅 persistLog 可见化（fail-open——
    /// 重启后 fresh 重探/幂等重写兜底，不阻断通道）。
    private func persistTopoffHonestyStateLocked(previous: TopoffChannelState) {
        guard Topoff.shouldPersistHonestyChange(previous: previous, current: topoffState) else { return }
        do {
            try topoffStateStore.save(topoffState.honestySnapshot)
        } catch {
            Self.persistLog("topoff 诚实性状态持久化失败：\(error)（fail-open——重启后 fresh 兜底）")
        }
    }

    // MARK: - 0.21.0 §2 CHIE 迟滞备用通道（决策全在 CellarCore.CHHysteresis 纯函数）

    /// 迟滞每拍消费（degraded 降级稳态的第二生命线；§2.2）。纯函数出意图（挂载/
    /// 退出/带宽执法），本方法只做副作用：CHIE 写经 DischargeAdapterControl 面 +
    /// persistLog 执法写纪律 + 簿记回填（lastWritten/flipCount——照 topoffState.
    /// lastWrittenLimit 先例）。挂载门与互斥矩阵全在纯函数（degraded/opt-in/可写/
    /// mode/actionActive/healProbe 互斥/chargingDisabled 窗/合盖/热 + 目标 <80）；
    /// healProbe 观察窗执法空窗 ≈10 min 注记登记（仅域值兜底——探针是自愈必经路径，
    /// 方案 §2.4 接受）。
    private func hysteresisTickLocked(
        snapshot: BatterySnapshot, chargingDisabledWindow: Bool,
        fullOnceWindow: Bool, events: inout [LogEvent]
    ) {
        let plan = CHHysteresis.tick(
            state: hysteresisState,
            degraded: topoffState.degraded,
            optIn: policy.chHysteresisEnabled == true,
            chieWritable: dischargeControlWritableLocked,
            modeActive: policy.mode == "active",
            actionActive: actionTrack.isActive,
            healProbeActive: topoffState.healProbeActive,
            chargingDisabledWindow: chargingDisabledWindow,
            percent: snapshot.percent,
            target: policy.upperLimit,
            hysteresis: policy.hysteresis,
            externalConnected: snapshot.externalConnected,
            isCharging: snapshot.isCharging,
            clamshellClosed: lastClamshellClosed,
            temperatureC: snapshot.temperatureC,
            fullOnceWindow: fullOnceWindow
        )
        let mountedBefore = hysteresisState.mounted
        hysteresisState = plan.state
        // 挂载/退出跳变 persistLog（§2.2 状态与可观测——每次翻转落盘 daemon.log）。
        if plan.state.mounted != mountedBefore {
            Self.persistLog(plan.state.mounted
                ? "CHIE 迟滞挂载：备用通道执法中（实验性；编排静默——降级稳态第二生命线，约 1 循环/天）"
                : "CHIE 迟滞退出：挂载解除（落 80 编排钳——现状；thermalTerminated=\(plan.state.thermalTerminated)）")
        }
        guard let write = plan.adapterWrite else { return }
        hysteresisExecuteWriteLocked(
            enabled: write, exitRestoring: !plan.state.mounted, events: &events
        )
    }

    /// CHIE 写执行（写 + 回读校验；每次 tick 一拍尝试——失败 lastWritten 不回填，
    /// 下拍幂等重试：exit 臂逐拍重试 / 未挂载态由 §2.4 残留巡检兜底，与 topoff 域写
    /// 失败纪律同构）。exitRestoring = 退出恢复臂（成功簿记 lastWritten=nil resting
    /// 归位）；带宽执法臂（成功簿记 lastWritten=写入值 + flipCount +1 + persistLog
    /// 执法写计数——§2.3 成本告知；0.21.0 M1b 终审注记 b 措辞口径「翻转」→
    /// 「执法写」）。返回写入是否成功。
    @discardableResult
    private func hysteresisExecuteWriteLocked(
        enabled: Bool, exitRestoring: Bool, events: inout [LogEvent]
    ) -> Bool {
        guard let client = dischargeControlClientLocked else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "CHIE 迟滞写不可执行：控制面 client 缺席（可写判据与 client 判据失配——防御分支）"
            ))
            return false
        }
        do {
            try DischargeAdapterControl.setAdapterEnabled(enabled, client: client)
            let state = try DischargeAdapterControl.adapterState(client: client)
            guard state == enabled else {
                throw BackendError.verifyFailed(key: "CHIE", desired: enabled, actual: state ?? false)
            }
        } catch {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "CHIE 迟滞写失败（期望 \(enabled ? "0x00 使能" : "0x8 禁用")）：\(error)——下拍幂等重试（未挂载态交 §2.4 巡检兜底）"
            ))
            return false
        }
        if exitRestoring {
            hysteresisState.lastWrittenAdapterEnabled = nil   // resting 归位——退出静默
        } else {
            hysteresisState.lastWrittenAdapterEnabled = enabled
            hysteresisState.flipCount += 1
            // §2.3 执法写计数 persistLog（约 1 循环/天成本口径的观测面；措辞口径
            // 「翻转」→「执法写」——M1b 终审注记 b）。
            Self.persistLog("CHIE 迟滞执法写 #\(hysteresisState.flipCount)：\(enabled ? "0x00 恢复使能（percent ≤ target——回带）" : "0x8 适配器禁用（percent > target+滞回——越带）")")
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "CHIE 迟滞执法：\(enabled ? "恢复 0x00（适配器使能）" : "禁用 0x8（适配器停充）")——实验性备用通道（域随写 target 保持双保险）"
        ))
        return true
    }

    /// §3.7 关断清理（第四处卫生）：域随写 100（先值后态 + 通知）+ off——杜绝
    /// 「UI 已停用、实际钉 75」（agent 每分钟跟随域值）。幂等：已 100 且 off → 零写
    ///（幂等守卫经 Topoff.shutdownCleanupNeeded 纯函数钉面——0.20.2 §2 off 持久化
    /// 跨重启兼容：重启 fresh lastWrittenLimit → 非 (100, off) → 一次幂等重写后
    /// 归位零写稳态）；**P3-2 评审修法：off 置位以写成功为条件**——失败不置位，
    /// 守卫允许带 off 缺席逐拍重试（「残留域值不滞留执法」不变量）。消费点（0.21.1
    /// §2.2 收缩为「真停用」）：汇聚点状态不变量（**仅 mode 非 active**——编排关
    /// ∧ 目标 ≥80 臂已删除）+ disable/restoreAndExit 事件路径。0.20.2 §2：off
    /// 关断为持久化触发源（命中拍诚实性快照落盘）。
    func topoffShutdownCleanupLocked(now: Date, events: inout [LogEvent]) {
        // 0.21.0 §2.1：全链清理含迟滞退出（off/关断语义不变；幂等——无挂载无 0x8
        // 驻留即零动作零日志）。事件路径（disable/restoreAndExit）无下拍 tick 兜底，
        // 同步恢复在此收口；恢复失败 → lastWritten 保留 → 下一拍清理/巡检重试。
        hysteresisExitLocked(events: &events)
        let honestyBefore = topoffState
        defer { persistTopoffHonestyStateLocked(previous: honestyBefore) }
        guard Topoff.shutdownCleanupNeeded(
            lastWrittenLimit: topoffState.lastWrittenLimit, off: topoffState.off
        ) else { return }
        let written = topoffExecuteWriteLocked(limit: Topoff.shutdownLimit, now: now, events: &events)
        guard written else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "topoff 关断清理写失败——off 不置位，下拍重试（残留域值不滞留执法不变量）"
            ))
            return
        }
        topoffState.off = true
        topoffState.healProbeActive = false
        events.append(LogEvent(
            category: .control, level: .info,
            message: "topoff 关断清理：域随写 100 + 通道 off（sub80State=off——防 UI 已停用、域值残留钉 75）"
        ))
    }

    /// 0.21.0 §2.1 迟滞退出（关断清理全链挂点；幂等）：挂载解除 + 0x8 驻留恢复。
    /// 无挂载且无 0x8 驻留 → 零动作（关断清理逐拍调用路径的静默守卫）。恢复失败 →
    /// lastWritten 保留 → 下一拍清理重试 / §2.4 残留巡检兜底（mounted=false 即恢复
    /// 巡检执法）。成功 → lastWritten=nil（resting 归位——后续清理拍零动作零日志）。
    func hysteresisExitLocked(events: inout [LogEvent]) {
        guard hysteresisState.mounted || hysteresisState.lastWrittenAdapterEnabled == false else {
            return
        }
        let hadResidual = hysteresisState.lastWrittenAdapterEnabled == false
        hysteresisState.mounted = false
        if hadResidual {
            if hysteresisExecuteWriteLocked(enabled: true, exitRestoring: true, events: &events) {
                Self.persistLog("CHIE 迟滞关断清理：0x00 恢复已归位（残留禁用不滞留）")
            }
        } else {
            Self.persistLog("CHIE 迟滞关断清理：挂载解除（无 0x8 驻留——零写归位）")
        }
    }

    /// 持久可观测（0.20.1 P0——wedge 事件教训）：关键执法动作直写 stderr（plist 重定向
    /// → /Library/Logs/Cellar/daemon.log）。LogEvent 内存环随进程消失（wedge 后事件
    /// 不可溯源的直接成因），关键动作必须落持久文件。调用方持锁串行（写入原子性足够）。
    static func persistLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// 子进程捕获（stdout+stderr 合并 + 退出码；DoctorCommand 同款实现——daemon root
    /// 上下文运行 defaults/notifyutil）。
    /// 0.20.1 P0 健壮性（真机 wedge 事件——走查②）：
    /// ①**先 read-to-EOF 后收尸**（原实现先 wait 后读——子进程输出塞满 64KB 管道
    ///   缓冲时子进程阻塞写、父进程阻塞等退出，互等死锁形态；read-to-EOF
    ///   在子进程退出/关闭 stdout 时自然返回，顺序不可倒置）；
    /// ②**10s 看门狗 terminate**（子进程挂起不永久持锁楔死 daemon）。
    /// 0.20.1 P0 死锁根治（真机 wedge 事件二——放电收尾拍，sample 线程栈实证）：
    /// ③**禁用 waitUntilExit——它在调用线程内嵌 RunLoop 等待**，等待期间主线程
    ///   心跳 timer 回调重入 performTickLocked，对同一线程已持有的状态锁
    ///   psynch 死锁（XPC handlePeerEvent 等锁全灭=daemon 整体失联）。改用
    ///   terminationHandler 信号 DispatchSemaphore——Foundation 在内部 GCD 线程
    ///   回调，不触碰调用方 RunLoop，重入路径不存在；wait 带 5s 兜底（EOF 后
    ///   信号通常已先行到达；超时再补 terminate 并短等，保证 terminationStatus
    ///   只在退出后读取）。
    static func runProcessCapture(
        _ executablePath: String, _ arguments: [String]
    ) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // R3-P3 纪律：terminationHandler 前置于 run()——run 与赋值间隙退出的窄窗
        // 不再依赖 Foundation 追溯回调行为。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ("", -1)
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Topoff.subprocessTimeoutSeconds), execute: watchdog)
        // 先读至 EOF（子进程退出或被看门狗 terminate 时返回），再等退出信号收尸
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + .seconds(5)) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = exited.wait(timeout: .now() + .seconds(5))
        }
        watchdog.cancel()
        let exitCode = process.terminationStatus
        return (String(data: data, encoding: .utf8) ?? "", exitCode)
    }
}
