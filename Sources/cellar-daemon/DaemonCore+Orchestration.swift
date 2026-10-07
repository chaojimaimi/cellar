import Foundation
import CellarCore

// MARK: - 观测 tick + 冻结偏好 XPC（0.23.1「编排退役批」重定版；全部锁内）
//
// **0.23.1 编排退役**：本文件原「编排 daemon 侧实现」（观测段编排链 + 断言签发 +
// pending 发布 + 回报簿记）随编排链退役重写——剩余幸存者按函数级拆解清单保留：
// - `observationTickLocked`（原 orchestrationTickLocked ①② 臂迁移改写——27 执法
//   引擎新家：前置日程转移 + 汇聚点路由消费；③断言签发臂删除）；
// - `orchestrationStatusLocked`（buildStatusLocked 恒填数据源——硬编码 false，
//   冻结偏好镜像零决策消费）；
// - `setOrchestrationEnabled`（冻结偏好写入保活——旧 App 混装窗 XPC 命令兼容，
//   收敛为 policy 照写 + persist + 回读；原 toggle 清窗臂与即时 tick 删除——命令
//   触发的行为臂随断言链退役，防旧 App 混装窗内切开关无声取消在途 fullOnce 窗）；
// - `reportOrchestration`（token 幂等日志 no-op 保活——旧 App 回报兼容，pending
//   状态已不存在）；
// - `setChHysteresisEnabled`（在用，原样迁）；
// - `restoreChargeLimit`（R5 重写形态：清窗 + 清锁存 + 即时 tick 域写 target；
//   pending 产出与开关前置拒收删除）。
extension DaemonCore {
    // MARK: - 编排状态数据源（硬编码 false）

    /// 编排状态组装（buildStatusLocked **恒填**的数据源）。**0.23.1 退役改版**：
    /// 原「policy + 内存态」读回改**硬编码 false**（冻结偏好镜像——常规 P3-4），
    /// pending 四键恒 nil（断言链退役）；wire schema 零变化。
    func orchestrationStatusLocked() -> OrchestrationStatus {
        OrchestrationStatus(enabled: false)
    }

    // MARK: - 观测段 tick（27 执法引擎——编排退役后幸存者）

    /// 观测段 tick（performTickLocked 后端缺席分支、27 平台判别门控内调用——原
    /// orchestrationTickLocked 挂点保留，门换 modernBackendTerminalLocked）：
    /// ① 前置日程转移（R1 P0-1/R2：applyScheduleTransitionLocked 是「desiredState
    ///    纯时间判定 + policy/state 写 + applied 门控」的自洽状态机，锚点幂等、
    ///    不依赖 snapshot、调用点无关——27 终态下执法段不可达，本处是唯一驱动点；
    ///    额外收益 = setChargeSchedule 即时 tick 语义在 27 保留）；
    /// ② fullOnce 窗自动恢复（0.23.2 §3——挂点钉死：日程转移后、topoff 路由前）；
    /// ③ 校准 27 调度臂（0.23.2 §1.1 全量方案 (a)——26 执法段调度臂的观测段镜像：
    ///    27 执法段不可达，本处是自动校准唯一驱动点；拒因处置照 26 调度臂）；
    /// ④ 汇聚点路由消费（0.20 M1b §3.1——desired 推导链随编排退役删除后，本消费
    ///    = topoff 域承载副作用（域写/验证/重申/降级/自愈/§3.6 卫生/§3.7 关断清理）
    ///    在 DaemonCore+Topoff.swift 的 topoffConvergenceRouteLocked 完成）。
    /// **0.23.1 删除臂**：③断言签发真值表 → 断言 token 签发（断言链随编排退役
    /// 整批删除——原编排运行时五字段删除形成编译强制）。
    func observationTickLocked(
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

        // ② fullOnce 窗自动恢复（0.23.2 ②——挂点钉死：topoff 路由消费之前）。
        // 窗口活跃拍跑 FullChargeDetection.tick（充满 3 拍去抖）与 4h 超时判定
        // ——命中即走共用清窗 helper（**零 tick 零域写**，红 R2），窗清后同拍汇聚
        // 路由自然落写 target（防双写先例——enforceLimitChargingLocked 27 臂同型）。
        if fullOnceWindowActive {
            let satisfied = FullChargeDetection.tick(
                isCharging: snapshot.isCharging, fullyCharged: snapshot.fullyCharged,
                percent: snapshot.percent, externalConnected: snapshot.externalConnected,
                consecutive: fullOnceFullTicks
            )
            let timedOut = now.timeIntervalSince(fullOnceWindowStartedAt ?? now)
                >= FullChargeDetection.fullOnceWindowTimeout
            if satisfied {
                clearFullOnceWindowStateLocked(reason: .full, events: &events)
            } else if timedOut {
                clearFullOnceWindowStateLocked(reason: .timeout, events: &events)
            } else {
                // 未命中且未超时：计数推进/清零（与 tick 共用单一谓词源——
                // FullChargeDetection.predicate → OneShot.isFullOnceComplete 单一
                // 真相，勿复制判定逻辑）。
                fullOnceFullTicks = FullChargeDetection.predicate(
                    isCharging: snapshot.isCharging, fullyCharged: snapshot.fullyCharged,
                    percent: snapshot.percent, externalConnected: snapshot.externalConnected
                ) ? fullOnceFullTicks + 1 : 0
            }
        } else if fullOnceFullTicks != 0 {
            // 窗口非活跃拍清计数器（红 R6 单一谓词点——五处清窗点免疫跨窗泄漏）。
            fullOnceFullTicks = 0
        }

        // ③ 校准 27 调度臂（0.23.2 §1.1）。动作活跃 → 静默（26 调度臂在空闲臂内
        // 的同形态）；mode 门照 26 执法段调度臂；拒因处置照 26：persistenceFailed
        // warn / 其余 info 静默顺延。
        if actionTrack.isActive {
            // 在轨动作期调度臂静默（校准/放电维护分支掌权——空轨判定前置）。
        } else if policy.mode == "active",
                  let schedule = policy.calibrationSchedule, schedule.enabled,
                  calibrationAutoStartReady(
                      now: now,
                      lastStartedAt: calibrationAnchorDateLocked(),
                      schedule: schedule
                  ) {
            do {
                if try startCalibrationLocked(
                    initiator: .auto, snapshot: snapshot, events: &events
                ) == .started {
                    // 同拍 maintainCalibrationLocked 接管（26 调度臂同判例——
                    // R2 P1；27 传 backend: nil + client: smcClient 直挂）。
                    let calActionName = maintainCalibrationLocked(
                        now: now, snapshot: snapshot, backend: nil, client: smcClient, events: &events
                    )
                    lastStatus?.lastAction = actionTrack.effectiveLastAction(calActionName)
                }
            } catch let rejection as CalibrationStartRejection
                where rejection == .persistenceFailed {
                // persistenceFailed 提级 warn（P3-1）：action.json 写失败 = 动作未
                // 落盘的异常态，非静默顺延；下 tick 幂等重试（照 26 调度臂措辞）。
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "自动校准启动失败：\(rejection)（持久化是动作存活的前提）"
                ))
            } catch {
                // 前置拒绝静默顺延（info 级，防窗口内每 30s 刷 error）：不写锚点
                // ——当日窗口内顺延重试，窗口过后自然跨日（UD-4；照 26 调度臂）。
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "自动校准未启动：\(error)（静默顺延，窗口内下 tick 重判）"
                ))
            }
        }

        // ④ 汇聚点路由消费（0.20 M1b §3.1）。chargingDisabled 在窗判定 = state
        // 锚点条目仍是配置成员且 chargingDisabled == true（配置被删/校验丢弃 →
        // 条目查不到 → 汇聚目标回常规映射，恢复路径由日程臂 restoreBase 兜底）。
        // topoff 副作用（域写/验证/重申/降级/自愈/卫生/关断清理）全在此完成。
        // **0.23.2**：窗自动恢复臂清窗后本拍路由即收敛 target（fullOnceWindow 已
        // false——同拍回落，零嵌套 tick）。
        topoffConvergenceRouteLocked(now: now, snapshot: snapshot, events: &events)
    }

    // MARK: - setOrchestration XPC（冻结偏好写入保活——wire 兼容面）

    /// setOrchestration（旧 App 混装窗兼容命令；**0.23.1 退役收敛**）：编排开关已
    /// 无决策消费面（零消费断言钉死），本命令降级为**冻结偏好照写**——policy 单
    /// 字段直写（F-1 禁令仅 upperLimit，schedule 直写先例）+ persist + 回读单一
    /// 真相。原 :100-107 toggle 清窗臂与即时 performTickLocked **删除**（命令触发
    /// 的行为臂随断言链退役——防旧 App 混装窗内切开关无声取消在途 fullOnce 窗；
    /// grep 零消费断言抓不到行为臂，此处为显式钉面）。新 App 无发送端（编排节
    /// 已删）——本命令仅旧 App 可达。
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
            message: "充电编排开关已照写 \(enabled ? "开启" : "关闭")（0.23.1 编排退役——开关已无决策消费面，仅冻结偏好镜像持久化）"
        ))
        return buildStatusLocked()
    }

    // MARK: - setChHysteresisEnabled XPC（0.21.0 §2.4 R2-P2-3，原样迁）

    /// CHIE 迟滞备用通道开关（照 setOrchestration 完整先例——policy 单字段直写 +
    /// persist + 即时 performTickLocked + 回读单一真相；**不改 mode**）。开关默认关
    ///（§2.3）；**迟滞运行态不入 TopoffPersistedState**（重启后 tick 首拍按开关 +
    /// CHIE 可写性重估）。关 → 即时 tick 内迟滞退出臂承接（unmount + CHIE 0x00 恢复
    /// ——off/关断语义不变，全链清理含迟滞退出）；事件路径（disable/restoreAndExit）
    /// 由 topoffShutdownCleanupLocked 的迟滞退出幂等兜底（编排开关关断不再清理——
    /// 迟滞退出由上方开关 tick 臂独立承接）。
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

    // MARK: - restoreChargeLimit XPC（0.21.0 §1.3 恢复臂——R5 重写形态）

    /// 恢复臂（27 fullOnce 配套，**0.23.1 重写**）：清临时放开窗 + 清终态锁存 +
    /// 即时 tick（observationTick → 汇聚点域写 target：<80 channelTick 幂等重写，
    /// ≥80 §3.6 域随写卫生收敛；M1 模型 v2——域写值直接流入 MCL 执法，无需任何
    /// set）。原「置 pending(policy.upperLimit) 交 App set」与「编排开关关前置
    /// 拒收」随断言链退役删除。幂等：无窗时点击同样
    /// 即时 tick（域重申 target，同值重写无痕）。App 侧按钮判定源 = wire
    /// fullOnceWindowActive（R4 判定源改挂）。
    func restoreChargeLimit() -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        actionTrack.clearUserActionLatch()   // 用户动作清除终态锁存（P0-2 对齐）
        if fullOnceWindowActive {
            // 0.23.2：清面走共用 helper（窗三件 + 共存 suspected 清零——红 R4 兼修；
            // 手动 XPC 不落字面量）——外层 performTickLocked 维持（XPC 语境非嵌套）。
            clearFullOnceWindowStateLocked(
                reason: .manual, detail: "fullOnce 临时放开窗已随恢复臂关闭",
                events: &events
            )
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "恢复限充：即时 tick 域写 target（\(policy.upperLimit)%）——M1 模型 v2 域写值直接执法"
        ))
        performTickLocked(events: &events)
        return buildStatusLocked()
    }

    // MARK: - reportOrchestration XPC（token 幂等日志 no-op——wire 兼容面）

    /// 回报确认链（旧 App 混装窗兼容命令；**0.23.1 退役收敛**）：pending 状态已
    /// 不存在（OrchestrationState 随批删除）——本命令降级为 token 幂等日志 no-op
    /// 保活（旧 App 迟到回报零副作用，仅 info 留痕防日志静默；回读单一真相）。
    func reportOrchestration(token: String, ok: Bool, detail: String?) -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        events.append(LogEvent(
            category: .control, level: .info,
            message: "编排回报（0.23.1 退役 no-op）：token \(token.prefix(8))… ok=\(ok)\(detail.map { "，detail=\($0)" } ?? "")——断言链已退役，回报零副作用（幂等日志）"
        ))
        return buildStatusLocked()
    }
}
