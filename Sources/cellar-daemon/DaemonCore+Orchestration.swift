import Foundation
import CellarCore

// MARK: - v0.19.20 Shortcuts 编排（daemon 侧：观测段编排链 + setOrchestration/
// reportOrchestration XPC；全部锁内）

/// 编排 daemon 侧实现（扩展文件拆分——照 DaemonCore+Schedule.swift 惯例：
/// 存储属性在主体声明，决策在 CellarCore.NativeOrchestration 纯函数（CellarCoreCheck
/// 场景域钉死真值表），本扩展只做副作用（日程转移前置、pending 发布、回报簿记、
/// 日志）。编排是 27 唯一执法路径（S2 实证 root 恒失败 → daemon 直连 NO-GO）；
/// 退出 Cellar = 停止编排（App 不在场 → pending 悬挂 + TTL 过期重发，§7.3）。
extension DaemonCore {
    // MARK: - 观测段编排链

    /// 编排状态组装（buildStatusLocked **恒填**的数据源——policy + 内存态，零读盘）。
    func orchestrationStatusLocked() -> OrchestrationStatus {
        OrchestrationStatus(
            enabled: policy.orchestrationEnabled == true,
            pendingToken: orchestrationState.pendingToken,
            pendingTarget: orchestrationState.pendingTarget,
            lastApplied: orchestrationState.lastAppliedTarget,
            lastError: orchestrationState.lastError
        )
    }

    /// 观测段编排链（performTickLocked 后端缺席分支、27 终态门控内调用——R2 P2）：
    /// ① 前置日程转移（R1 P0-1/R2：applyScheduleTransitionLocked 是「desiredState
    ///    纯时间判定 + policy/state 写 + applied 门控」的自洽状态机，锚点幂等、
    ///    不依赖 snapshot、调用点无关——27 终态下执法段不可达，本处是唯一驱动点；
    ///    额外收益 = setChargeSchedule 即时 tick 语义在 27 保留）；
    /// ② 汇聚点双通道路由（0.20 M1b §3.1——desired 推导链整体迁入
    ///    Topoff.convergenceRoute 纯函数（CellarCoreCheck 场景域钉死），topoff 分流
    ///    独立于编排开关门派生（R1-P3 位置约束）；topoff 副作用（域写/验证/重申/
    ///    降级/自愈/§3.6 卫生/§3.7 关断清理）在 DaemonCore+Topoff.swift 消费）；
    /// ③ assertionRequest 真值表 → 命中即签发 pendingToken（发布走 buildStatusLocked
    ///    恒填——App 轮询消费）。
    func orchestrationTickLocked(
        now: Date, snapshot: BatterySnapshot, events: inout [LogEvent]
    ) {
        // ① 前置日程转移。handled 语义（转移后 mode 非 active → 跳过 enforce）在
        // 观测段无从生效（本分支本就无执法段），恒忽略；转移字面量照
        // cancelActionLocked 的 lastStatus?.lastAction 直写先例落观测段（R2 P3，
        // 仅可见性面——App 日程通知走 scheduleActiveId 边沿不受影响）。
        var actionName = lastStatus?.lastAction ?? ""
        var handled = false
        applyScheduleTransitionLocked(
            now: now, actionName: &actionName, handled: &handled, events: &events
        )
        lastStatus?.lastAction = actionName

        // ② 汇聚点双通道路由（0.20 M1b §3.1）。chargingDisabled 在窗判定 = state
        // 锚点条目仍是配置成员且 chargingDisabled == true（配置被删/校验丢弃 →
        // 条目查不到 → 汇聚目标回常规映射，恢复路径由日程臂 restoreBase 兜底）。
        let desired = topoffConvergenceRouteLocked(
            now: now, snapshot: snapshot, events: &events
        )

        // ③ 断言决策（真值表全在 CellarCore 纯函数——本处只消费）。
        let decision = NativeOrchestration.assertionRequest(
            desired: desired,
            lastApplied: orchestrationState.lastAppliedTarget,
            lastRequestAt: orchestrationState.lastRequestAt,
            now: now,
            external: snapshot.externalConnected,
            isCharging: snapshot.isCharging,
            percent: snapshot.percent,
            actionActive: actionTrack.isActive,
            modeActive: policy.mode == "active",
            hasOutstanding: orchestrationState.hasOutstanding
        )
        guard case .assert(let reason) = decision, let target = desired else { return }
        let token = UUID().uuidString
        orchestrationState.pendingToken = token
        orchestrationState.pendingTarget = target
        orchestrationState.lastRequestAt = now
        events.append(LogEvent(
            category: .control, level: .info,
            message: "编排断言：target=\(target)%（\(reason == .valueChange ? "目标变化" : "行为验证")，pending 待 App 执行回报，TTL \(Int(NativeOrchestration.defaultCooldown))s）"
        ))
    }

    // MARK: - setOrchestration XPC

    /// setOrchestration（R1 P0-2：编排开关唯一写入通道；照 setChargeScheduleConfig
    /// 形态——policy 单字段直写（F-1 禁令仅 upperLimit，schedule 直写先例）+ persist
    /// + 即时 performTickLocked（开关生效 ≤1 tick；27 终态下 tick 走观测段编排链）。
    /// 0.21.1 §2.2：**编排开关关断清理臂删除**（原 sub80 机 target ≥80 → 域随写
    /// 100 + off）——编排关不断域：域随写 target 覆盖全区间，汇聚点卫生分支在即时
    /// tick **同拍写回 target**（删臂防域 100 闪写 + off 持久化抖动 + wire 闪变）。
    /// off 置位仅剩 mode 关两路（disable/restoreAndExit）——off 语义收紧「真停用」。
    func setOrchestrationEnabled(_ enabled: Bool) -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        policy.orchestrationEnabled = enabled
        // 0.21.0 §1.3：开关 toggle 重基线——fullOnce 临时放开窗随之清除（窗内
        // 关 → §1.5 关断补偿按表接管；重开 → valueChange 按新 target 重断言）。
        if orchestrationState.fullOnceWindowActive {
            orchestrationState.fullOnceWindowActive = false
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce 临时放开窗已随编排开关 toggle 清除"
            ))
        }
        persistPolicyLocked(events: &events)
        events.append(LogEvent(
            category: .lifecycle, level: .info,
            message: "充电编排已\(enabled ? "开启" : "关闭")（即时 tick——27 终态下断言 ≤1 tick 发布）"
        ))
        performTickLocked(events: &events)
        return buildStatusLocked()
    }

    // MARK: - setChHysteresisEnabled XPC（0.21.0 §2.4 R2-P2-3）

    /// CHIE 迟滞备用通道开关（照 setOrchestration 完整先例——policy 单字段直写 +
    /// persist + 即时 performTickLocked + 回读单一真相；**不改 mode**）。开关默认关
    ///（§2.3）；**迟滞运行态不入 TopoffPersistedState**（重启后 tick 首拍按开关 +
    /// CHIE 可写性重估）。关 → 即时 tick 内迟滞退出臂承接（unmount + CHIE 0x00 恢复
    /// ——off/关断语义不变，全链清理含迟滞退出）；事件路径（disable/restoreAndExit）
    /// 由 topoffShutdownCleanupLocked 的迟滞退出幂等兜底（0.21.1 起编排开关关断
    /// 不再清理——迟滞退出由上方开关 tick 臂独立承接）。
    func setChHysteresisEnabled(_ enabled: Bool) -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        policy.chHysteresisEnabled = enabled
        persistPolicyLocked(events: &events)
        events.append(LogEvent(
            category: .lifecycle, level: .info,
            message: "CHIE 迟滞备用通道已\(enabled ? "开启" : "关闭")（即时 tick——挂载/退出 ≤1 tick 评估；实验性，约 1 循环/天）"
        ))
        performTickLocked(events: &events)
        return buildStatusLocked()
    }

    // MARK: - restoreChargeLimit XPC（0.21.0 §1.3 恢复臂）

    /// 恢复臂（27 fullOnce 复活配套）：置 pending(`policy.upperLimit`) 交 App set 回
    /// + 清临时放开窗 + 即时 tick（域重申 target——topoff 承载 <80 时 channelTick
    /// 幂等重写，≥80 时 §3.6 域随写卫生收敛）。
    /// **前置拒收同适用（R3-P3-1）**：编排开关关 → `.orchestrationSwitchOff`
    /// （照 fullOnce 27 前置同文案——fail-visible；App 侧按钮隐藏 + 引导重开，
    /// 重开后 valueChange 断言自然恢复 target，亦是自愈路径）。幂等：无窗时点击
    /// 同样置 pending（回当前态语义——App 按钮判定源为读回，见位才可点）。
    func restoreChargeLimit() throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        guard policy.orchestrationEnabled == true else {
            throw OneShotStartRejection.orchestrationSwitchOff
        }
        actionTrack.clearUserActionLatch()   // 用户动作清除终态锁存（P0-2 对齐）
        let now = Date()
        let token = UUID().uuidString
        orchestrationState.pendingToken = token
        orchestrationState.pendingTarget = policy.upperLimit
        orchestrationState.lastRequestAt = now
        if orchestrationState.fullOnceWindowActive {
            orchestrationState.fullOnceWindowActive = false
            events.append(LogEvent(
                category: .control, level: .info,
                message: "fullOnce 临时放开窗已随恢复臂关闭"
            ))
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "恢复限充：pending(\(policy.upperLimit)) 待 App set（免 root）——即时 tick 重申域 target"
        ))
        performTickLocked(events: &events)
        return buildStatusLocked()
    }

    // MARK: - reportOrchestration XPC

    /// 回报确认链：pendingToken 匹配才消费（ok → 记 lastApplied/清错误；失败 → 记
    /// lastError）；不匹配静默丢弃（幂等——迟到/重复回报零副作用，仅 info 留痕）。
    /// pending 清空后：enforcement 语义下重试由真值表规则 5 冷却门约束；非管理员
    /// 回报被鉴权拒的场景 pending 未清，TTL 过期后规则 3 放行重发（R2 P1 降级链，
    /// churn 上界每 TTL 一次）。
    func reportOrchestration(token: String, ok: Bool, detail: String?) -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        guard orchestrationState.pendingToken == token else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "编排回报丢弃：token 不匹配（已消费或已过期）——幂等静默"
            ))
            return buildStatusLocked()
        }
        if ok {
            orchestrationState.lastAppliedTarget = orchestrationState.pendingTarget
            orchestrationState.lastError = nil
            events.append(LogEvent(
                category: .control, level: .info,
                message: "编排回报确认：lastApplied=\(orchestrationState.pendingTarget ?? -1)%（pending 已清）"
            ))
        } else {
            orchestrationState.lastError = detail
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "编排回报失败：\(detail ?? "（无详情）")——pending 已清（enforcement 重试交冷却门，valueChange 交下 tick 重发）"
            ))
        }
        orchestrationState.pendingToken = nil
        orchestrationState.pendingTarget = nil
        return buildStatusLocked()
    }
}
