// CellarCoreCheck —— 0.21.1 放电振荡根治与域语义一致化场景域（方案 §1/§2/§4）
//
// 覆盖清单（工单门禁钉死项）：
// ① 门 b 窗互斥派生（autoDischargeEffectiveTarget：fullOnce/日程窗静默 + mode 门）
// ② 三门矩阵：门 a !isCharging（26 一拍延迟边界钉面）/ 门 b nil 静默 / 门 c 熔断抑制
//    / 三门叠加（各自独立生效 + AND 组合）
// ③ 振荡熔断状态机（2h 滑窗：首完成不触发 / 2h 内第 2 完成触发 / 边沿仅一次 /
//    恰 2h 出窗边界 / 抑制态持续静默；解除路径①重启重置 = fresh 初值锚）
// ④ 乒乓循环回归断链（方案 §0.4/§4.1——真机事件三层根因第①③层的 CellarCore
//    可测面；修前形态（域 100 + off + 自动放电全链）已在方案评审定谳入档，本域
//    钉修后断链输出：域随写 target + App 对账不再 set 100 + 门 a 挡 + 熔断封顶）
// ⑤ 行为矩阵六行 × 边界 79/80/81（方案 §2.3 全形态）
// ⑥ wire：sub80WrittenLimit / autoDischargeSuspended（旧 JSON 缺席 + round-trip）
// ⑦ 26 回归钉面：AutoDischargeDomain 自动-1..25 以新默认参（charging=false/无窗/
//    未抑制）逐值复跑即 26 真值表零回归（本域补门 a 一拍延迟边界，见 ②）。
//
// 全部纯函数面（无 IO、不起 daemon）；daemon 侧接线（两挂点传参/完成计数/opt-in
// 清抑制/横幅 wire 组装）为 executable internal——照 AutoDischargeDomain ⑦ 盲区
// 声明先例以代码走查 + 真机验收兜底。

import CellarCore
import Foundation

/// 0.21.1 放电振荡场景域入口（Main.main 调用）。
func runDischargeOscillationDomainScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    // ---- ① 门 b 窗覆盖派生（窗互斥——统一形态：汇聚目标 ≠ policy 上限时静默）----

    // 振荡-1：fullOnce 临时放开窗 ∨ chargingDisabled 日程窗 → nil（静默）；无窗 =
    // policy.upperLimit；mode 非 active → nil（mode 门兜底同型）。
    check(Discharge.autoDischargeEffectiveTarget(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false, upperLimit: 80) == 80,
          "振荡-1", "无窗 → effectiveTarget = policy 上限（80——margin 比较基准）")
    check(Discharge.autoDischargeEffectiveTarget(
        modeActive: true, fullOnceWindow: true, chargingDisabledWindow: false, upperLimit: 80) == nil,
          "振荡-1", "fullOnce 临时放开窗 → nil（显式放开期充 100 是窗意图——放电静默）")
    check(Discharge.autoDischargeEffectiveTarget(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: true, upperLimit: 80) == nil,
          "振荡-1", "chargingDisabled 日程窗 → nil（同型——两窗同权静默）")
    check(Discharge.autoDischargeEffectiveTarget(
        modeActive: true, fullOnceWindow: true, chargingDisabledWindow: true, upperLimit: 80) == nil,
          "振荡-1", "两窗叠加 → nil（任一窗即静默）")
    check(Discharge.autoDischargeEffectiveTarget(
        modeActive: false, fullOnceWindow: false, chargingDisabledWindow: false, upperLimit: 80) == nil,
          "振荡-1", "mode 非 active → nil（mode 门兜底同型——与 autoTriggerReady mode 门双保险）")

    // ---- ② 三门矩阵（三门独立生效 + 叠加）----

    func ready(
        isCharging: Bool = false, percent: Int = 82,
        effectiveTarget: Int? = 80, oscillationSuspended: Bool = false,
        now: Date = t0, lastAutoCompletion: Date? = nil,
        adapterCycleSinceCompletion: Bool = true
    ) -> Bool {
        Discharge.autoTriggerReady(
            enabled: true, mode: "active", externalConnected: true,
            isCharging: isCharging, percent: percent,
            effectiveTarget: effectiveTarget, actionActive: false, dischargeCapable: true,
            oscillationSuspended: oscillationSuspended, now: now,
            lastAutoCompletion: lastAutoCompletion,
            adapterCycleSinceCompletion: adapterCycleSinceCompletion
        )
    }

    // 振荡-2：门 a !isCharging（26 影响分析钉边界——方案 §1.1：26 停充 SMC 直控
    // 即时生效、过冲拍 charging 通常已 false；门仅使「充电未停的瞬间」延迟一拍
    // 30s = 设计意图。真机乒乓事件签名形态：82% charging=true 过冲拍）。
    check(!ready(isCharging: true), "振荡-2",
          "门 a：agent 尚在充电（82% charging=true）→ 不触发（不与充电对抗、不抢跑于 agent 收敛之前）")
    check(ready(isCharging: false), "振荡-2",
          "门 a：停充后（charging=false）→ 其余门全开即触发（!charging 快速回落价值保留——方案 §1.2 margin 登记不动）")

    // 振荡-3：门 b 窗覆盖静默（effectiveTarget=nil 直通沉默——margin 判定无从谈起）。
    check(!ready(percent: 100, effectiveTarget: nil), "振荡-3",
          "门 b：窗覆盖（effectiveTarget=nil）→ 不触发（percent 100 亦静默——显式放开被放电对抗的统一阻断形态）")
    check(ready(percent: 82, effectiveTarget: 80), "振荡-3",
          "门 b：无窗（effectiveTarget=80）→ margin 正常判定（82 ≥ 80+2 → 触发）")

    // 振荡-4：门 c 熔断抑制静默。
    check(!ready(oscillationSuspended: true), "振荡-4",
          "门 c：振荡熔断抑制态 → 不触发（循环成本硬上界——抑制后 0）")
    check(ready(oscillationSuspended: false), "振荡-4",
          "门 c：未抑制 → 不拦截（抑制仅熔断触发后）")

    // 振荡-5：三门叠加（各自独立 + AND 组合——任一门关即静默，全开才触发）。
    check(!ready(isCharging: true, effectiveTarget: nil, oscillationSuspended: true), "振荡-5",
          "三门全关 → 不触发")
    check(!ready(isCharging: true, effectiveTarget: 80, oscillationSuspended: false)
              && !ready(isCharging: false, effectiveTarget: nil, oscillationSuspended: false)
              && !ready(isCharging: false, effectiveTarget: 80, oscillationSuspended: true),
          "振荡-5", "任一门关（门 a ∨ 门 b ∨ 门 c）→ 不触发（AND 组合——单门独立阻断）")
    check(ready(isCharging: false, effectiveTarget: 80, oscillationSuspended: false),
          "振荡-5", "三门全开 → 触发（用户价值保留：停充后超带快速回落）")

    // ---- ③ 振荡熔断状态机（2h 滑窗）----

    // 常量钉死（方案 §1.1 门 c：2h 滑窗 ≥2 次 autostart 完成 → 抑制）。
    check(Discharge.oscillationWindow == 2 * 3600 && Discharge.oscillationCompletionLimit == 2,
          "振荡-6", "熔断常量钉死（2h 滑窗 / 阈值 2——宽松阈值，合法快速回落不误伤）")
    check(Discharge.OscillationState() == Discharge.OscillationState()
              && !Discharge.OscillationState().suspended
              && Discharge.OscillationState().autoCompletions.isEmpty,
          "振荡-6", "fresh 初值：未抑制、零样本（重启重置 = 解除路径①的值语义锚）")

    // 振荡-7：首完成不触发；2h 内第 2 完成触发（边沿 true 仅触发拍）。
    do {
        var state = Discharge.OscillationState()
        let first = Discharge.noteOscillationCompletion(state: state, at: t0)
        state = first.state
        check(!first.triggered && !state.suspended && state.autoCompletions.count == 1,
              "振荡-7", "滑窗第 1 次完成 → 不触发（阈值 2 未达）")
        let second = Discharge.noteOscillationCompletion(
            state: state, at: t0.addingTimeInterval(21 * 60))   // 真机事件：每轮 21 min
        state = second.state
        check(second.triggered && state.suspended, "振荡-7",
              "2h 内第 2 次完成 → 触发抑制（真机乒乓形态：两轮完整循环 42 min < 2h）")
        // 边沿仅一次：抑制态下后续完成仍滑窗推进但不重发。
        let third = Discharge.noteOscillationCompletion(state: state, at: t0.addingTimeInterval(42 * 60))
        check(!third.triggered && third.state.suspended, "振荡-7",
              "抑制态下第 3 次完成 → 不重发边沿（告警一次；锁存持续）")
    }

    // 振荡-8：滑窗出窗边界（恰 2h 旧样本出窗；2h−1s 在窗触发）。
    check(!Discharge.noteOscillationCompletion(
        state: Discharge.noteOscillationCompletion(
            state: Discharge.OscillationState(), at: t0).state,
        at: t0.addingTimeInterval(2 * 3600)).triggered,
          "振荡-8", "两次完成恰隔 2h → 不触发（旧样本严格 < 2h 出窗——边界钉死）")
    check(Discharge.noteOscillationCompletion(
        state: Discharge.noteOscillationCompletion(
            state: Discharge.OscillationState(), at: t0).state,
        at: t0.addingTimeInterval(2 * 3600 - 1)).triggered,
          "振荡-8", "两次完成隔 2h−1s → 触发（在窗判定边界另一侧）")

    // 振荡-9：解除路径②（用户重新 opt-in）= daemon 侧重置 OscillationState（照
    // autoDischarge flag 翻转清两门先例）——重置后滑窗从零起算。
    do {
        var state = Discharge.OscillationState()
        state = Discharge.noteOscillationCompletion(state: state, at: t0).state
        state = Discharge.noteOscillationCompletion(
            state: state, at: t0.addingTimeInterval(60)).state
        check(state.suspended, "振荡-9", "前置：两次完成 → 抑制")
        state = Discharge.OscillationState()   // setLimits opt-in 翻转清抑制（daemon 接线）
        let after = Discharge.noteOscillationCompletion(state: state, at: t0.addingTimeInterval(120))
        check(!after.triggered && after.state.autoCompletions.count == 1,
              "振荡-9", "重新 opt-in 重置 → 旧窗样本清零，新完成从 1 起算（新意图语义——不立即再触发）")
    }

    // ---- ④ 乒乓循环回归断链（真机事件 target=80 编排关两轮循环——方案 §0.1/§0.4）----
    // 修前形态（已入档定谳）：编排关 ∧ target 80 → 汇聚点守卫清理域 100 + off →
    // agent 跟域 100 持续充电 → 过冲 82 → 自动放电（margin 82≥100+2 不成立——
    // 修前触发链为停充惰性 +2 与 margin 恰合的 82≥80+2）→ 放电完成 = 适配器翻转 =
    // 重插门自解锁 → 循环自持。修后断链三环逐值钉死：

    // 乒乓-1：断链第一环——域随写 target（编排关 ∧ target 80 → 汇聚目标 80 非 100、
    // 非清理、topoff 不承载、编排静默）。
    let incident = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
        upperLimit: 80, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(incident.convergenceTarget == 80, "乒乓-1",
          "编排关 ∧ target 80 → 汇聚目标 80（域随写 80——域恢复滞回根治面；修前清理域 100 已废除）")
    check(incident.orchestrationDesired == nil, "乒乓-1",
          "编排关 → 编排静默（开关仅门控 App set 执行通道——域通道不受门，架构自述不变量对齐）")
    check(!incident.topoffOwned, "乒乓-1",
          "target 80 不 <80 → topoff 不承载（§3.6 域随写卫生分支承接——汇聚点 mode nil 守卫不触发）")

    // 乒乓-2：断链第二环——App 对账不再 set 100（§0.3 域 100 顶掉用户系统 MCL
    // 的 App 侧同根因）。
    check(NativeLimitSet.shutdownExpectation(
        modeActive: true, orchestrationEnabled: false, upperLimit: 80) == nil,
          "乒乓-2", "编排关 ∧ target 80 → 关断期望 nil（App 停止补偿 set 100；系统设置覆盖由域随写 target + 读回失配提示承载）")

    // 乒乓-3：断链第三环——门 a 挡过冲拍 + 熔断封顶降级形态（方案 §2.4 如实登记）。
    check(!Discharge.autoTriggerReady(
        enabled: true, mode: "active", externalConnected: true,
        isCharging: true, percent: 82, effectiveTarget: 80,
        actionActive: false, dischargeCapable: true, oscillationSuspended: false,
        now: t0, lastAutoCompletion: nil, adapterCycleSinceCompletion: true
    ), "乒乓-3", "事件签名形态（82% charging=true 过冲）→ 门 a 挡——无放电（修前此拍即触发放电臂）")
    check(Discharge.autoTriggerReady(
        enabled: true, mode: "active", externalConnected: true,
        isCharging: false, percent: 82, effectiveTarget: 80,
        actionActive: false, dischargeCapable: true, oscillationSuspended: false,
        now: t0, lastAutoCompletion: nil, adapterCycleSinceCompletion: true
    ), "乒乓-3", "停充后（charging=false）超带 → 可放（§2.3 矩阵行 3 用户价值；滞回成立则驻留带内不触——§2.4 待真机验证假设）")
    do {
        // 降级形态封顶：滞回不成立时循环仍在，成本由门 c 封顶（2h ≤2 次后 0）。
        var state = Discharge.noteOscillationCompletion(
            state: Discharge.OscillationState(), at: t0).state
        state = Discharge.noteOscillationCompletion(
            state: state, at: t0.addingTimeInterval(21 * 60)).state
        check(state.suspended && !Discharge.autoTriggerReady(
            enabled: true, mode: "active", externalConnected: true,
            isCharging: false, percent: 82, effectiveTarget: 80,
            actionActive: false, dischargeCapable: true, oscillationSuspended: state.suspended,
            now: t0.addingTimeInterval(42 * 60),
            lastAutoCompletion: t0.addingTimeInterval(12 * 60),
            adapterCycleSinceCompletion: true
        ), "乒乓-3", "熔断封顶：2h 内 2 次完成后 → 第三轮触发被门 c 拦截（循环成本硬上界——满足「确保不会再出现」验收线）")
    }

    // ---- ⑤ 行为矩阵六行 × 边界 79/80/81（方案 §2.3）----

    func route(_ orchestrationEnabled: Bool, _ upperLimit: Int)
        -> (convergenceTarget: Int?, orchestrationDesired: Int?, topoffOwned: Bool) {
        Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: orchestrationEnabled,
            chargingDisabledWindow: false, upperLimit: upperLimit,
            sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false
        )
    }

    // 矩阵-1：行 1/2（target <80 ∧ 编排开/关）——topoff 承载、编排静默（开关独立性）；
    // 边界 79 承载 / 80 不承载（<80 判据边界）。
    check(route(true, 79).topoffOwned && route(true, 79).convergenceTarget == 79
              && route(true, 79).orchestrationDesired == nil,
          "矩阵-1", "target 79 ∧ 编排开 → topoff 承载 79、编排静默（<80 域执法——App set 拒 <80 不参与）")
    check(route(false, 79).topoffOwned && route(false, 79).convergenceTarget == 79
              && route(false, 79).orchestrationDesired == nil,
          "矩阵-1", "target 79 ∧ 编排关 → 同行 1（topoff 不受编排开关门——域随写语义一致化对称面）")
    check(NativeLimitSet.setTarget(for: 79) == 80, "矩阵-1",
          "target 79 恢复臂钳 set 80（<80 set 拒验收口径——执行体永不向原生 MCL 写 <80 值）")

    // 矩阵-2：行 3/4（target ≥80 ∧ 编排开/关）——域随写 target、编排开断言 target、
    // 编排关静默；边界 80/81 双侧。
    check(route(true, 80).convergenceTarget == 80 && !route(true, 80).topoffOwned
              && route(true, 80).orchestrationDesired == 80,
          "矩阵-2", "target 80（边界）∧ 编排开 → 域随写 80 + 断言 80（0.21.1 改后域=target）")
    check(route(true, 81).convergenceTarget == 81 && route(true, 81).orchestrationDesired == 81,
          "矩阵-2", "target 81 ∧ 编排开 → 域随写 81 + 断言 81（≥80 全区间随写）")
    check(route(false, 80).convergenceTarget == 80 && route(false, 80).orchestrationDesired == nil,
          "矩阵-2", "target 80 ∧ 编排关 → 域随写 80 + 编排静默（乒乓断链第一环——矩阵行 4）")
    check(route(false, 81).convergenceTarget == 81 && route(false, 81).orchestrationDesired == nil,
          "矩阵-2", "target 81 ∧ 编排关 → 域随写 81（域故障时 MCL 80 兜底 + 熔断封顶——行 2 同构）")

    // 矩阵-3：行 5（fullOnce/日程窗）——域 100、断言 100、topoff 失效、放电静默（门 b）。
    let windowRow = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: true,
        upperLimit: 80, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(windowRow.convergenceTarget == 100 && windowRow.orchestrationDesired == 100
              && !windowRow.topoffOwned,
          "矩阵-3", "chargingDisabled 日程窗 → 域 100 + 断言 100 + topoff 失效（完全放开）")
    check(Discharge.autoDischargeEffectiveTarget(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: true, upperLimit: 80) == nil,
          "矩阵-3", "窗内自动放电静默（门 b——窗互斥钉面）")

    // 矩阵-4：行 6（mode 关真停用）——汇聚 nil、断言 nil、期望 100。
    let offRow = Topoff.convergenceRoute(
        modeActive: false, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 80, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(offRow.convergenceTarget == nil && offRow.orchestrationDesired == nil
              && !offRow.topoffOwned,
          "矩阵-4", "mode 关 → 汇聚 nil + 断言 nil + topoff 失效（真停用——off 语义收紧后唯一 off 源）")
    check(NativeLimitSet.shutdownExpectation(
        modeActive: false, orchestrationEnabled: true, upperLimit: 80) == 100,
          "矩阵-4", "mode 关 → 关断期望恒 100（真停用=放开——保留臂）")

    // ---- ⑥ wire（sub80WrittenLimit / autoDischargeSuspended）----

    // 线-1：旧 JSON（无新键）→ 双 nil（decodeIfPresent 兼容——旧 daemon 回包天然解码）。
    do {
        let oldJSON = """
        {"version":"0.21.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":2000000}
        """
        let old = try JSONDecoder().decode(DaemonStatus.self, from: Data(oldJSON.utf8))
        check(old.sub80WrittenLimit == nil && old.autoDischargeSuspended == nil, "线-1",
              "旧 daemon 回包（无 sub80WrittenLimit/autoDischargeSuspended 键）→ 双 nil（向后兼容）")
    }

    // 线-2：round-trip 保留 + init 缺省 nil（既有夹具形态不破坏）。
    do {
        var status = DaemonStatus(version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2)
        check(status.sub80WrittenLimit == nil && status.autoDischargeSuspended == nil, "线-2",
              "init 缺省双 nil（既有构造点零 diff）")
        status.sub80WrittenLimit = 80
        status.autoDischargeSuspended = true
        let revived = try JSONDecoder().decode(
            DaemonStatus.self, from: JSONEncoder().encode(status)
        )
        check(revived.sub80WrittenLimit == 80 && revived.autoDischargeSuspended == true, "线-2",
              "round-trip 保留域生效值与抑制态（App 读回失配提示 + 横幅数据源）")
    }
}
