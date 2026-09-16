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
    /// ② desired 推导（编排关/mode 门 → chargingDisabled 在窗强制 100（R2 P1：
    ///    等价「完全放开」，退出边沿恢复 base）→ nativeTarget 钳制映射）；
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

        // ② desired 推导。chargingDisabled 在窗判定 = state 锚点条目仍是配置成员
        // 且 chargingDisabled == true（配置被删/校验丢弃 → 条目查不到 → desired 回
        // 常规映射，恢复路径由日程臂 restoreBase 兜底）。
        let chargingDisabledWindowActive = scheduleState.lastAppliedEntryId != nil
            && policy.schedule?.entries.first(where: { $0.id == scheduleState.lastAppliedEntryId })?
                .chargingDisabled == true
        let desired: Int?
        if policy.mode != "active" || policy.orchestrationEnabled != true {
            desired = nil
        } else if chargingDisabledWindowActive {
            desired = 100
        } else {
            desired = NativeOrchestration.nativeTarget(effectiveLimit: policy.upperLimit).target
        }

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
    /// + 即时 performTickLocked（开关生效 ≤1 tick；27 终态下 tick 走观测段编排链））。
    func setOrchestrationEnabled(_ enabled: Bool) -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        policy.orchestrationEnabled = enabled
        persistPolicyLocked(events: &events)
        events.append(LogEvent(
            category: .lifecycle, level: .info,
            message: "充电编排已\(enabled ? "开启" : "关闭")（即时 tick——27 终态下断言 ≤1 tick 发布）"
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
