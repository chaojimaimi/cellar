// CellarCoreCheck —— 0.21.0 §2 CHIE 迟滞备用后端场景域（方案 §2.1/§2.2/§2.3/§2.4）
//
// 按域拆独立文件（评审 P2-9 先例）。覆盖清单（M1b 工单验收门禁钉死项）：
// ①迟滞路由三分支（convergenceRoute 扩展 hysteresisEnabled/active：on → desired=nil
//   编排静默 / off → 降级钳 80 现状 / CHIE 不可写（enabled ∧ !active）→ 钳 80）
// ②迟滞判定带宽（0x8/0x00 边界逐字：percent > target+滞回 → 0x8；percent ≤ target →
//   0x00；地板 ≤60 恢复；带内无动作；幂等；ext 门）
// ③互斥矩阵四角（actionActive / healProbe / chargingDisabled / 合盖 + 热第五角）
// ④热终止与恢复（40°C 单点终止 → 落 80 钳面；阈值−滞回 38°C 回降重挂——R2-P3-4）
// ⑤挂载门矩阵（mountAllowed 逐项）
// ⑤'外部写者簿记失效与自愈链（code-review P1-1：动作终态恢复 0x00 → noteExternal-
//   AdapterWrite 失效 → 下拍按实况重写；P3-2：target 滑升 ≥80 退出臂）/ ⑧26 回归锚
// ⑥wire：sub80Hysteresis / chHysteresisEnabled 双字段 round-trip + 旧 JSON 缺席
// ⑦policy F-1 透传（保真/旧 JSON/三构造点形态）+ XPC 通道（makeMessage/
//   validateRequest/值域/命令字面量无冲突——旧 daemon stale 走 App
//   detectStaleBeforeReject 既有闭环，daemon 侧「未知命令」拒绝臂为 XPCServer
//   default 分支，CellarCoreCheck 不可 import daemon——注记登记）
// ⑧26 回归（缺省参数零 diff——既有 TopoffDomain 路由-1..6 全绿即证 + 本域显式锚）
//
// 全部纯函数面（PolicyStore 临时目录/Data 注入），不触碰真实 SMC/plist、不起 daemon。

import CellarCore
import Foundation
import XPC

/// 迟滞场景域入口（Main.main 调用）。
func runCHHysteresisDomainScenarios() {
    runCHHysteresisRouteScenarios()
    runCHHysteresisBandScenarios()
    runCHHysteresisMutexScenarios()
    runCHHysteresisThermalScenarios()
    runCHHysteresisMountScenarios()
    runCHHysteresisExternalWriteScenarios()
    runCHHysteresisWireScenarios()
    runCHHysteresisPolicyXPCScenarios()
    runCHHysteresisLegacyRegressionScenarios()
}

// MARK: - ① 迟滞路由三分支（§2.1 R1-P1-4 定版）

private func runCHHysteresisRouteScenarios() {
    // 迟滞-1：三分支——迟滞 on（enabled ∧ active）→ desired=nil（编排静默——消
    // 编排钳 80 与迟滞压 75 互搏）；off（开关关 / 未挂载）→ 降级钳 80 现状；
    // CHIE 不可写（enabled ∧ !active）→ 钳 80 现状。
    do {
        let on = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: true, hysteresisActive: true)
        check(on == (convergenceTarget: 75, orchestrationDesired: Int?.none, topoffOwned: true),
              "迟滞-1", "迟滞 on（degraded ∧ opt-in ∧ active）→ desired=nil（编排静默——互搏消解）")
        let off = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: false, hysteresisActive: false)
        check(off.orchestrationDesired == Topoff.degradedLimit,
              "迟滞-1", "开关关（off）→ 降级钳 80 现状（0.20 M1b 既有链零变化）")
        let unwritable = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: true, hysteresisActive: false)
        check(unwritable.orchestrationDesired == Topoff.degradedLimit,
              "迟滞-1", "CHIE 不可写（opt-in 但未挂载）→ 钳 80 现状（降级链不可用臂）")
    }

    // 迟滞-2：边界角——active 但 enabled 缺席（契约违例防御：路由要求双真）→ 钳 80
    // 不静默；编排开关关 ∧ 迟滞 active → desired=nil（门 1 先于迟滞分支——语义等价）；
    // chargingDisabled 窗 → topoffOwned=false → 迟滞分支不可达 → desired=100（窗内
    // 完全放开——迟滞静默由 tick 互斥门承接）。
    do {
        let enabledMissing = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: false, hysteresisActive: true)
        check(enabledMissing.orchestrationDesired == Topoff.degradedLimit,
              "迟滞-2", "active 但开关缺席（契约违例防御）→ 钳 80（路由要求 enabled ∧ active 双真）")
        let orchOff = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: true, hysteresisActive: true)
        check(orchOff.orchestrationDesired == nil && orchOff.topoffOwned,
              "迟滞-2", "编排关 ∧ 迟滞 active → desired=nil（topoff 不受编排开关门——既有门序）")
        let window = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: true,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: true, hysteresisActive: true)
        check(window == (convergenceTarget: 100, orchestrationDesired: 100, topoffOwned: false),
              "迟滞-2", "chargingDisabled 窗 → 汇聚/断言 100（完全放开——迟滞 tick 互斥门静默，路由不变）")
        let action = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: true,
            degraded: true, healProbeActive: false,
            hysteresisEnabled: true, hysteresisActive: true)
        check(!action.topoffOwned && action.orchestrationDesired == 80,
              "迟滞-2", "动作活跃 → topoff 不承载 → 迟滞分支不可达 → desired=80（断言由 assertionRequest 规则 2 压制——0.19.20 语义零变化）")
    }
}

// MARK: - ② 迟滞判定带宽（§2.2 判据逐字）

private func runCHHysteresisBandScenarios() {
    let base = CHHysteresis.State(mounted: true)
    func tick(
        _ state: CHHysteresis.State, percent: Int?, target: Int = 75, hysteresis: Int = 2,
        ext: Bool? = true, charging: Bool? = true, clamshell: Bool? = false,
        temperature: Double? = 30.0
    ) -> CHHysteresis.TickPlan {
        CHHysteresis.tick(
            state: state, degraded: true, optIn: true, chieWritable: true, modeActive: true,
            actionActive: false, healProbeActive: false, chargingDisabledWindow: false,
            percent: percent, target: target, hysteresis: hysteresis,
            externalConnected: ext, isCharging: charging, clamshellClosed: clamshell,
            temperatureC: temperature)
    }

    // 迟滞-3：越带/回带边界（target=75 滞回=2）——>77 → 0x8；==77 带内；≤75 → 0x00。
    do {
        check(tick(base, percent: 78).adapterWrite == false,
              "迟滞-3", "percent 78 > 75+2 → 0x8（适配器禁用——越带执法）")
        check(tick(base, percent: 77).adapterWrite == nil,
              "迟滞-3", "percent 77 == target+滞回 → 带内无动作（> 严格判定）")
        check(tick(base, percent: 76).adapterWrite == nil,
              "迟滞-3", "percent 76（带内）→ 无动作（滞回防抖——带宽即循环成本阀门 §2.3）")
        check(tick(base, percent: 75).adapterWrite == true,
              "迟滞-3", "percent 75 == target → 0x00（恢复使能——回带）")
        check(tick(base, percent: 74).adapterWrite == true,
              "迟滞-3", "percent 74 < target → 0x00")
    }

    // 迟滞-4：地板 ≤60 恢复防滞留 + target=60 紧贴地板边界。
    do {
        check(tick(base, percent: 60).adapterWrite == true,
              "迟滞-4", "percent 60（地板）→ 0x00（地板恢复臂——禁用态不滞留地板下）")
        check(tick(base, percent: 59).adapterWrite == true,
              "迟滞-4", "percent 59 < 地板 → 0x00（防御——LimitPolicy 地板下理论不可达）")
        check(tick(base, percent: 62, target: 60, hysteresis: 1).adapterWrite == false,
              "迟滞-4", "target=60 滞回=1：percent 62 > 61 → 0x8（60 地板紧贴形态）")
        check(tick(base, percent: 61, target: 60, hysteresis: 1).adapterWrite == nil,
              "迟滞-4", "target=60：percent 61 == target+1 → 带内无动作")
    }

    // 迟滞-5：幂等（lastWritten 同值零写——30s 心跳不重复执法写）+ 执法写才计。
    do {
        let disabled = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: false, flipCount: 3)
        let hold = tick(disabled, percent: 80)
        check(hold.adapterWrite == nil && hold.state.flipCount == 3,
              "迟滞-5", "已驻 0x8（lastWritten=false）∧ 仍越带 → 零写（幂等；flipCount 不动）")
        let restore = tick(disabled, percent: 70)
        check(restore.adapterWrite == true,
              "迟滞-5", "已驻 0x8 ∧ 回带 → 0x00 写意图（执法写）")
        let enabled = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: true, flipCount: 4)
        let holdEnabled = tick(enabled, percent: 70)
        check(holdEnabled.adapterWrite == nil,
              "迟滞-5", "已驻 0x00 ∧ 带内回带侧 → 零写（幂等）")
        let disableAgain = tick(enabled, percent: 80)
        check(disableAgain.adapterWrite == false,
              "迟滞-5", "已驻 0x00 ∧ 越带 → 0x8 写意图（再越带再 0x8——自闭环 §2.2）")
    }

    // 迟滞-6：ext 门（禁用臂要求外接在场——电池供电拍写禁用无意义）+ 采样缺席静默。
    do {
        check(tick(base, percent: 80, ext: false).adapterWrite == nil,
              "迟滞-6", "越带 ∧ 未外接 → 无动作（适配器执法前提不成立——ext 门）")
        check(tick(base, percent: 70, ext: false).adapterWrite == true,
              "迟滞-6", "回带 ∧ 未外接 → 0x00 照写（恢复使能恒安全方向）")
        check(tick(base, percent: 80, ext: nil).adapterWrite == nil,
              "迟滞-6", "ext 未知 → 静默（采样缺席——证据不足）")
        check(tick(base, percent: nil).adapterWrite == nil,
              "迟滞-6", "percent 缺席 → 静默（照 channelTick 缺席纪律）")
        check(tick(base, percent: 80, charging: nil).adapterWrite == nil,
              "迟滞-6", "isCharging 未知 → 静默（采样缺席三件套）")
    }
}

// MARK: - ③ 互斥矩阵四角（§2.2 完备化；挂载态静默 vs 退出）

private func runCHHysteresisMutexScenarios() {
    let mounted8 = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: false)
    func tick(
        _ state: CHHysteresis.State, actionActive: Bool = false, healProbe: Bool = false,
        window: Bool = false, clamshell: Bool? = false, fullOnce: Bool = false
    ) -> CHHysteresis.TickPlan {
        CHHysteresis.tick(
            state: state, degraded: true, optIn: true, chieWritable: true, modeActive: true,
            actionActive: actionActive, healProbeActive: healProbe,
            chargingDisabledWindow: window, percent: 80, target: 75, hysteresis: 2,
            externalConnected: true, isCharging: true, clamshellClosed: clamshell,
            temperatureC: 30.0, fullOnceWindow: fullOnce)
    }

    // 迟滞-7：静默三角（挂载保持 + 本拍零写——0x8 驻留合法）。
    do {
        let action = tick(mounted8, actionActive: true)
        check(action.adapterWrite == nil && action.state.mounted,
              "迟滞-7", "actionActive（放电/校准在轨）→ 静默（挂载保持——动作期 CHIE 归动作轨掌权）")
        let probe = tick(mounted8, healProbe: true)
        check(probe.adapterWrite == nil && probe.state.mounted,
              "迟滞-7", "healProbe 观察窗 → 静默（互斥——迟滞翻转污染探针判定 R1-P1-4；≈10 min 空窗注记登记）")
        let window = tick(mounted8, window: true)
        check(window.adapterWrite == nil && window.state.mounted,
              "迟滞-7", "chargingDisabled 窗（完全放开）→ 静默（挂载保持——窗毕恢复执法）")
        let fullOnce = tick(mounted8, fullOnce: true)
        check(fullOnce.adapterWrite == true && !fullOnce.state.mounted,
              "迟滞-7", "fullOnce 临时放开窗 → 退出臂（unmount + 0x00——驻留 0x8 会物理阻断充电，静默不足以让路；窗毕评估门重走重挂，§1.3）")
    }

    // 迟滞-8：合盖角——拒绝/中止（强检查：closed == true；nil 诚实缺席不中止）。
    do {
        let closed = tick(mounted8, clamshell: true)
        check(closed.adapterWrite == true && !closed.state.mounted,
              "迟滞-8", "合盖（closed == true）→ 中止：unmount + 0x00 恢复（持续合盖 → 落 80 编排钳）")
        let unknown = tick(mounted8, clamshell: nil)
        check(unknown.state.mounted,
              "迟滞-8", "合盖读取失败（nil）→ 不中止（照 ClamshellGate.shouldAbort 强检查语义——防误伤息屏）")
        let closedFresh = CHHysteresis.State()
        let rejected = tick(closedFresh, clamshell: true)
        check(!rejected.state.mounted && rejected.adapterWrite == nil,
              "迟滞-8", "未挂载 ∧ 合盖 → 拒绝挂载（零写——本就无驻留）")
    }

    // 迟滞-9：退出臂全集（mode 关 / 开关关 / 自愈恢复 / CHIE 不可写）——unmount +
    // 0x00 恢复；幂等重试（恢复失败 lastWritten 保留 → 下拍再试）。
    do {
        func tickVariant(
            modeActive: Bool = true, degraded: Bool = true, optIn: Bool = true,
            chieWritable: Bool = true, state: CHHysteresis.State = mounted8
        ) -> CHHysteresis.TickPlan {
            CHHysteresis.tick(
                state: state, degraded: degraded, optIn: optIn, chieWritable: chieWritable,
                modeActive: modeActive, actionActive: false, healProbeActive: false,
                chargingDisabledWindow: false, percent: 80, target: 75, hysteresis: 2,
                externalConnected: true, isCharging: true, clamshellClosed: false,
                temperatureC: 30.0)
        }
        check(tickVariant(modeActive: false).adapterWrite == true
                  && tickVariant(modeActive: false).state.mounted == false,
              "迟滞-9", "mode 关 → unmount + 0x00（关断清理面全链含迟滞退出——off 语义不变）")
        check(tickVariant(optIn: false).adapterWrite == true
                  && tickVariant(optIn: false).state.mounted == false,
              "迟滞-9", "开关关 → unmount + 0x00（opt-in 撤回即退出）")
        check(tickVariant(degraded: false).adapterWrite == true
                  && tickVariant(degraded: false).state.mounted == false,
              "迟滞-9", "自愈恢复（!degraded）→ unmount + 0x00（CHIE 归还 resting 态——通道回归 topoff 承载）")
        check(tickVariant(chieWritable: false).adapterWrite == true
                  && tickVariant(chieWritable: false).state.mounted == false,
              "迟滞-9", "CHIE 不可写 → unmount + 0x00（写探针失败臂——无法执法即退出）")
        // 幂等：已归位（lastWritten=nil/true）退出拍零写。
        let restored = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: true)
        check(tickVariant(optIn: false, state: restored).adapterWrite == nil,
              "迟滞-9", "退出拍已驻 0x00 → 零写（幂等——仅 unmount）")
        // 恢复失败重试：未挂载但 lastWritten=false（0x8 残留）→ 退出臂逐拍重试。
        let failedRestore = CHHysteresis.State(mounted: false, lastWrittenAdapterEnabled: false)
        check(tickVariant(optIn: false, state: failedRestore).adapterWrite == true,
              "迟滞-9", "恢复失败残留（!mounted ∧ lastWritten=false）→ 退出臂逐拍重试 0x00")
    }
}

// MARK: - ④ 热终止与恢复（R2-P3-4）

private func runCHHysteresisThermalScenarios() {
    let mounted8 = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: false)
    func tick(_ state: CHHysteresis.State, temperature: Double?, percent: Int = 80) -> CHHysteresis.TickPlan {
        CHHysteresis.tick(
            state: state, degraded: true, optIn: true, chieWritable: true, modeActive: true,
            actionActive: false, healProbeActive: false, chargingDisabledWindow: false,
            percent: percent, target: 75, hysteresis: 2, externalConnected: true,
            isCharging: true, clamshellClosed: false, temperatureC: temperature)
    }

    // 迟滞-10：热终止（40°C 单点即触发——方向安全）→ unmount + 0x00 + thermalTerminated。
    do {
        let hot = tick(mounted8, temperature: 40.0)
        check(hot.adapterWrite == true && !hot.state.mounted && hot.state.thermalTerminated,
              "迟滞-10", "40.0°C（≥ 阈值单点）→ 终止迟滞：unmount + 0x00 + thermalTerminated（落 80 钳由路由承接）")
        let hotter = tick(mounted8, temperature: 41.5)
        check(hotter.state.thermalTerminated && !hotter.state.mounted,
              "迟滞-10", "41.5°C → 同终止（> 阈值任意温度）")
    }

    // 迟滞-11：热恢复滞回带——38 < 温度 < 40 滞留终止态；≤38 解除并同拍重挂。
    do {
        let terminated = CHHysteresis.State(mounted: false, thermalTerminated: true)
        let lingering = tick(terminated, temperature: 39.0, percent: 70)
        check(!lingering.state.mounted && lingering.state.thermalTerminated,
              "迟滞-11", "39.0°C（38–40 滞回带）→ 滞留终止态不重挂（R2-P3-4 阈值附近防抖）")
        let unknown = tick(terminated, temperature: nil, percent: 70)
        check(!unknown.state.mounted && unknown.state.thermalTerminated,
              "迟滞-11", "温度未知 → 滞留终止态（无回降证据不解除——保守）")
        let resumed = tick(terminated, temperature: 38.0, percent: 70)
        check(resumed.state.mounted && !resumed.state.thermalTerminated,
              "迟滞-11", "38.0°C（== 阈值−滞回）→ 解除热终止 + 同拍重挂（评估门重走——R2-P3-4）")
        let resumeBand = tick(terminated, temperature: 37.9, percent: 80)
        check(resumeBand.state.mounted && resumeBand.adapterWrite == false,
              "迟滞-11", "37.9°C 解除 ∧ 仍越带 → 重挂同拍 0x8（挂载拍即执法）")
    }

    // 迟滞-12：热终止幂等（已归位后持续过热 → 零写；unmount 态不重复恢复写）。
    do {
        let restored = CHHysteresis.State(mounted: false, thermalTerminated: true, lastWrittenAdapterEnabled: nil)
        let stillHot = tick(restored, temperature: 40.0)
        check(stillHot.adapterWrite == nil && stillHot.state.thermalTerminated,
              "迟滞-12", "已恢复 0x00 ∧ 持续过热 → 零写（幂等——wasMounted=false ∧ 无驻留）")
    }
}

// MARK: - ⑤ 挂载门矩阵（mountAllowed 逐项）

private func runCHHysteresisMountScenarios() {
    // 迟滞-13：门全过 → true；逐项负臂 → false（判定次序无关——AND 全集）。
    do {
        func allowed(
            degraded: Bool = true, optIn: Bool = true, writable: Bool = true,
            modeActive: Bool = true, actionActive: Bool = false, healProbe: Bool = false,
            window: Bool = false, clamshell: Bool? = false, thermal: Bool = false,
            target: Int = 75, percent: Int? = 80
        ) -> Bool {
            CHHysteresis.mountAllowed(
                degraded: degraded, optIn: optIn, chieWritable: writable, modeActive: modeActive,
                actionActive: actionActive, healProbeActive: healProbe,
                chargingDisabledWindow: window, clamshellClosed: clamshell,
                thermalTerminated: thermal, target: target, percent: percent)
        }
        check(allowed(), "迟滞-13", "门全过 → 允许挂载（degraded 稳态第二生命线）")
        check(!allowed(degraded: false), "迟滞-13", "非降级（active 承载期）→ 不挂载（§2.1 链序）")
        check(!allowed(optIn: false), "迟滞-13", "开关关 → 不挂载")
        check(!allowed(writable: false), "迟滞-13", "CHIE 不可写 → 不挂载")
        check(!allowed(modeActive: false), "迟滞-13", "mode 关 → 不挂载")
        check(!allowed(actionActive: true), "迟滞-13", "动作在轨 → 不挂载")
        check(!allowed(healProbe: true), "迟滞-13", "healProbe 观察窗 → 不挂载（互斥）")
        check(!allowed(window: true), "迟滞-13", "chargingDisabled 窗 → 不挂载")
        check(!allowed(clamshell: true), "迟滞-13", "合盖 → 不挂载（拒绝）")
        check(allowed(clamshell: nil), "迟滞-13", "合盖读取失败（nil）→ 放行（强检查诚实缺席）")
        check(!allowed(thermal: true), "迟滞-13", "热终止滞留 → 不挂载（温度回降前）")
        check(!allowed(target: 80), "迟滞-13", "target == 80 → 不挂载（≥80 编排钳/App set 执法——迟滞越权互搏防）")
        check(!allowed(target: 85), "迟滞-13", "target ≥80 → 不挂载")
        check(!allowed(percent: nil), "迟滞-13", "采样缺席 → 不挂载")
    }

    // 迟滞-14：挂载拍同拍执法（降级稳态已越带——挂载不空转一拍）。
    do {
        let plan = CHHysteresis.tick(
            state: CHHysteresis.State(), degraded: true, optIn: true, chieWritable: true,
            modeActive: true, actionActive: false, healProbeActive: false,
            chargingDisabledWindow: false, percent: 80, target: 75, hysteresis: 2,
            externalConnected: true, isCharging: true, clamshellClosed: false,
            temperatureC: 30.0)
        check(plan.state.mounted && plan.adapterWrite == false,
              "迟滞-14", "挂载拍 percent 已越带 → mounted=true ∧ 同拍 0x8（不空转）")
        let calm = CHHysteresis.tick(
            state: CHHysteresis.State(), degraded: true, optIn: true, chieWritable: true,
            modeActive: true, actionActive: false, healProbeActive: false,
            chargingDisabledWindow: false, percent: 70, target: 75, hysteresis: 2,
            externalConnected: true, isCharging: true, clamshellClosed: false,
            temperatureC: 30.0)
        check(calm.state.mounted && calm.adapterWrite == true,
              "迟滞-14", "挂载拍 percent ≤ target → mounted=true ∧ 0x00（已知 resting 态幂等安全——S1 E1 同值写探针实证）")
    }
}

// MARK: - ⑤' 外部写者簿记失效与自愈链（code-review P1-1/P3-2）

private func runCHHysteresisExternalWriteScenarios() {
    let mounted8 = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: false)
    let mounted0 = CHHysteresis.State(mounted: true, lastWrittenAdapterEnabled: true)
    func tick(_ state: CHHysteresis.State, percent: Int, target: Int = 75) -> CHHysteresis.TickPlan {
        CHHysteresis.tick(
            state: state, degraded: true, optIn: true, chieWritable: true, modeActive: true,
            actionActive: false, healProbeActive: false, chargingDisabledWindow: false,
            percent: percent, target: target, hysteresis: 2, externalConnected: true,
            isCharging: true, clamshellClosed: false, temperatureC: 30.0)
    }

    // 迟滞-24（P1-1 自愈链钉面）：动作轨终态恢复 0x00（外部写者）→ 簿记失效 →
    // 下拍禁用臂按实况重写 0x8——修死「幂等吞掉禁用臂 → 执法静默卡死」失败链。
    do {
        // 失效前提：终态恢复前簿记记 0x8（lastWritten=false），外部已写 0x00。
        let invalidated = CHHysteresis.noteExternalAdapterWrite(state: mounted8)
        check(invalidated.lastWrittenAdapterEnabled == nil && invalidated.mounted,
              "迟滞-24", "外部写失效：lastWritten 置 nil ∧ mounted 保持（nil ≠ 任何带宽意图——下拍重估）")
        // 失效后下拍：percent 仍越带 → 禁用臂意图 false ≠ nil → 重写 0x8（自愈闭环）。
        let heal = tick(invalidated, percent: 80)
        check(heal.adapterWrite == false && heal.state.mounted,
              "迟滞-24", "失效后下拍越带 → 重写 0x8（自愈——幂等不再吞掉禁用臂）")
        check(tick(mounted8, percent: 80).adapterWrite == nil,
              "迟滞-24", "对照：失效前同拍 → 幂等零写（即 P1-1 失败链的静默形态）")
        // 反向：簿记记 0x00（true）→ 动作期实际写过 0x8 的漂移同样被失效修复。
        let invalidated0 = CHHysteresis.noteExternalAdapterWrite(state: mounted0)
        check(tick(invalidated0, percent: 70).adapterWrite == true,
              "迟滞-24", "反向漂移（簿记 true）失效后回带拍重写 0x00（恢复臂同款自愈）")
        // 未挂载时失效无害（exit 臂 nil 无恢复意图——不产生多余写）。
        let unmounted = CHHysteresis.noteExternalAdapterWrite(
            state: CHHysteresis.State(mounted: false, lastWrittenAdapterEnabled: false))
        let exitTick = CHHysteresis.tick(
            state: unmounted, degraded: true, optIn: false, chieWritable: true,
            modeActive: true, actionActive: false, healProbeActive: false,
            chargingDisabledWindow: false, percent: 80, target: 75, hysteresis: 2,
            externalConnected: true, isCharging: true, clamshellClosed: false,
            temperatureC: 30.0)
        check(exitTick.adapterWrite == nil && !exitTick.state.mounted,
              "迟滞-24", "未挂载失效后退出拍 → 零写（nil 无恢复意图——不空转）")
    }

    // 迟滞-25（P3-2）：目标滑升 ≥ 80（75→90）→ 退出臂 unmount + 0x00 恢复
    //（修 mounted 空挂滞留——横幅假「执法中」+ 巡检豁免空悬）；80 边界同臂。
    do {
        let raised = tick(mounted8, percent: 80, target: 90)
        check(raised.adapterWrite == true && !raised.state.mounted,
              "迟滞-25", "target 90（≥ degradedLimit）→ 退出臂：unmount + 0x00（挂载门恒假的空挂滞留修死）")
        let boundary = tick(mounted0, percent: 80, target: 80)
        check(boundary.adapterWrite == nil && !boundary.state.mounted,
              "迟滞-25", "target 80（== degradedLimit 边界）→ unmount（已驻 0x00 零写——幂等退出）")
        // 滑回落（90→75）：退出后评估门重走重挂（执法域回归 topoff）。
        let remount = CHHysteresis.tick(
            state: CHHysteresis.State(mounted: false, lastWrittenAdapterEnabled: nil),
            degraded: true, optIn: true, chieWritable: true, modeActive: true,
            actionActive: false, healProbeActive: false, chargingDisabledWindow: false,
            percent: 80, target: 75, hysteresis: 2, externalConnected: true,
            isCharging: true, clamshellClosed: false, temperatureC: 30.0)
        check(remount.state.mounted && remount.adapterWrite == false,
              "迟滞-25", "滑回 75 → 评估门重走重挂 ∧ 同拍 0x8（退出→重挂往返闭环）")
    }
}

// MARK: - ⑥ wire：sub80Hysteresis / chHysteresisEnabled（§2.2/§2.4）

private func runCHHysteresisWireScenarios() {
    // 迟滞-15：双字段 round-trip（true/false 双态都编解码保真）。
    do {
        var status = DaemonStatus(version: "t", mode: "active", upperLimit: 75, hysteresis: 2)
        status.sub80State = .degraded
        status.sub80Hysteresis = true
        status.chHysteresisEnabled = true
        let round = DaemonXPC.encodeStatus(status).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(round == status && round?.sub80Hysteresis == true && round?.chHysteresisEnabled == true,
              "迟滞-15", "sub80Hysteresis/chHysteresisEnabled true round-trip 全字段保留")
        var off = DaemonStatus(version: "t", mode: "active", upperLimit: 75, hysteresis: 2)
        off.sub80Hysteresis = false
        off.chHysteresisEnabled = false
        let roundOff = DaemonXPC.encodeStatus(off).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(roundOff?.sub80Hysteresis == false && roundOff?.chHysteresisEnabled == false,
              "迟滞-15", "false 显式编码解码保真（false ≠ 缺席——Bool? 语义）")
    }
    // 迟滞-16：旧 daemon JSON 无两键 → 解码 nil（decodeIfPresent——旧 App 整包解码
    // 防线；不改 Sub80State Codable 枚举的红线由 sub80Hysteresis 独立字段承载）。
    do {
        let legacyJSON = #"{"version":"0.20.2-alpha","mode":"active","upperLimit":75,"hysteresis":2,"sub80State":"degraded","timestamp":123.0}"#
        let legacy = try? JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        check(legacy?.sub80State == .degraded && legacy?.sub80Hysteresis == nil
                  && legacy?.chHysteresisEnabled == nil,
              "迟滞-16", "旧 daemon JSON（无迟滞两键）→ 双键 nil 且 sub80State 照常（Sub80State 枚举未动）")
    }
}

// MARK: - ⑦ policy F-1 透传 + XPC 通道（§2.4 R2-P2-3）

private func runCHHysteresisPolicyXPCScenarios() {
    // 迟滞-17：policy 保真——带迟滞开关的策略落盘再读回逐字段一致（照编排-11 先例）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-hys-f1-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        try? store.save(DaemonPolicy(
            mode: "active", upperLimit: 75, hysteresis: 2,
            orchestrationEnabled: true, chHysteresisEnabled: true))
        let loaded = store.load()
        check(loaded?.chHysteresisEnabled == true && loaded?.orchestrationEnabled == true,
              "迟滞-17", "load() 保真：chHysteresisEnabled 与编排开关并存不覆盖")
    }
    // 迟滞-18：旧 policy.json 无键 → nil（decodeIfPresent 兼容——开关默认关 §2.3）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-hys-f1-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy.json")
        try? #"{"mode":"active","upperLimit":75,"hysteresis":2}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let loaded = PolicyStore(url: url).load()
        check(loaded?.chHysteresisEnabled == nil && loaded?.upperLimit == 75,
              "迟滞-18", "旧 JSON 无键 → nil（0.20.x 形态零回归；nil = 关默认）")
    }
    // 迟滞-19：三构造点重建形态透传钉（F-1——漏带 = persistPolicyLocked 覆写丢开关；
    // 照编排-13 先例以 PolicyStore + 临时目录模拟重建/回流形态）。
    do {
        func roundTrip(_ build: (DaemonPolicy) -> DaemonPolicy) -> Bool {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cellar-hys-f1-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
            let base = DaemonPolicy(mode: "active", upperLimit: 75, hysteresis: 2, chHysteresisEnabled: true)
            try? store.save(build(base))
            return store.load()?.chHysteresisEnabled == true
        }
        // setLimits 形态（mode 固定 active + 显式字段拷贝）。
        check(roundTrip { base in
            DaemonPolicy(mode: "active", upperLimit: 90, hysteresis: 3,
                         autoDischargeEnabled: base.autoDischargeEnabled, fan: base.fan,
                         calibrationSchedule: base.calibrationSchedule, thermal: base.thermal,
                         schedule: base.schedule, magSafeLedMode: base.magSafeLedMode,
                         orchestrationEnabled: base.orchestrationEnabled,
                         chHysteresisEnabled: base.chHysteresisEnabled)
        }, "迟滞-19", "setLimits 重建形态（active + 迟滞开关透传）往返保真")
        // disable 形态（mode=disabled + 其余字段拷贝）。
        check(roundTrip { base in
            DaemonPolicy(mode: "disabled", upperLimit: base.upperLimit, hysteresis: base.hysteresis,
                         autoDischargeEnabled: base.autoDischargeEnabled, fan: base.fan,
                         calibrationSchedule: base.calibrationSchedule, thermal: base.thermal,
                         schedule: base.schedule, magSafeLedMode: base.magSafeLedMode,
                         orchestrationEnabled: base.orchestrationEnabled,
                         chHysteresisEnabled: base.chHysteresisEnabled)
        }, "迟滞-19", "disable 重建形态（disabled + 迟滞开关透传）往返保真")
        // validated 形态（日程转移落地段——daemon 第四构造点）。
        check(DaemonPolicy.validated(
            mode: "active", upperLimit: 70, hysteresis: 2,
            orchestrationEnabled: true, chHysteresisEnabled: true)?.chHysteresisEnabled == true,
              "迟滞-19", "日程转移落地段形态（validated 透传）保真——漏带 = 转移清空用户开关")
    }
    // 迟滞-20：XPC 通道——makeMessage/validateRequest 提取 + 值域 + 类型白名单。
    do {
        let onMsg = DaemonXPC.makeMessage(
            cmd: CHHysteresisWireKeys.command, upper: 0, hysteresis: 0, chHysteresisEnabled: 1)
        let onParsed = DaemonXPC.validateRequest(onMsg)
        check(onParsed?.chHysteresisEnabled == 1,
              "迟滞-20", "setChHysteresisEnabled(on) 消息 → chHysteresisEnabled=1 提取")
        let offMsg = DaemonXPC.makeMessage(
            cmd: CHHysteresisWireKeys.command, upper: 0, hysteresis: 0, chHysteresisEnabled: 0)
        check(DaemonXPC.validateRequest(offMsg)?.chHysteresisEnabled == 0,
              "迟滞-20", "off 消息 → 0 提取（0/1 双态显式）")
        check(CHHysteresisWireKeys.validEnabled(0) && CHHysteresisWireKeys.validEnabled(1)
                  && !CHHysteresisWireKeys.validEnabled(2),
              "迟滞-20", "开关值域 0/1（XPCServer 臂 / validateRequest 同源）")
        let plain = DaemonXPC.makeMessage(cmd: "setLimits", upper: 80, hysteresis: 2)
        check(DaemonXPC.validateRequest(plain)?.chHysteresisEnabled == nil,
              "迟滞-20", "既有命令无迟滞键 → nil（天然兼容）")
    }
    // 迟滞-21：类型混淆整包拒绝（STRING 混入 UINT64 键——照编排开关同纪律）+
    // 命令字面量与既有命令集无冲突（旧 daemon「未知命令」拒绝臂的前提）。
    do {
        let mixed = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(mixed, DaemonXPC.cmdKey, CHHysteresisWireKeys.command)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.upperKey, 0)
        xpc_dictionary_set_uint64(mixed, DaemonXPC.hysteresisKey, 0)
        xpc_dictionary_set_string(mixed, CHHysteresisWireKeys.enabled, "1")
        check(DaemonXPC.validateRequest(mixed) == nil,
              "迟滞-21", "开关键以 STRING 混入 → 整包拒绝（不崩溃）")
        let existing = [
            "getStatus", "setLimits", "disable", "enable", "fullOnce", "cancelAction",
            "dischargeToLimit", "startCalibration", "cancelCalibration", "setOrchestration",
            "reportOrchestration", NativeLimitSet.restoreCommand, MagSafeLED.commandName,
            FanWireKeys.command, CalibrationScheduleWireKeys.command, ThermalWireKeys.command,
            ChargeScheduleWireKeys.command,
        ]
        check(!existing.contains(CHHysteresisWireKeys.command)
                  && CHHysteresisWireKeys.command == "setChHysteresisEnabled",
              "迟滞-21", "命令字面量钉死且不与既有命令冲突（旧 daemon → 「未知命令」daemonError——App detectStaleBeforeReject 升级提示既有闭环，stale 面登记）")
    }
}

// MARK: - ⑧ 26 回归锚（缺省参数零 diff）

private func runCHHysteresisLegacyRegressionScenarios() {
    // 迟滞-22：convergenceRoute 缺省 hysteresisEnabled/active → 0.20 M1b 既有链
    // 逐值（26 / 既有调用点零 diff——缺省参数即回归锚；TopoffDomain 路由-1..6 全绿
    // 互证）。
    do {
        let degraded75 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false)
        check(degraded75.orchestrationDesired == 80 && degraded75.topoffOwned,
              "迟滞-22", "缺省参数 ∧ 降级稳态 → 钳 80（0.20 M1b 逐值——迟滞未接入形态）")
        let active75 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(active75 == (convergenceTarget: 75, orchestrationDesired: Int?.none, topoffOwned: true),
              "迟滞-22", "缺省参数 ∧ active 承载 → 编排静默（TopoffDomain 路由-1 逐值复钉）")
        let legacy26 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: false, actionActive: false,
            degraded: false, healProbeActive: false)
        check(legacy26.topoffOwned == false && legacy26.orchestrationDesired == 80,
              "迟滞-22", "26（sub80Capable=false）→ 0.19.20 链逐值（迟滞全链 26 零触及——红线锚）")
    }
    // 迟滞-23：State 初值（fresh = 未挂载/无热终止/无驻留/零计数——重启后首拍按
    // 开关 + CHIE 可写性重估的 §2.4 形态）。
    do {
        let fresh = CHHysteresis.State()
        check(!fresh.mounted && !fresh.thermalTerminated
                  && fresh.lastWrittenAdapterEnabled == nil && fresh.flipCount == 0,
              "迟滞-23", "fresh 态：全零值（迟滞运行态不持久化——重启重估 + §2.4 巡检兜底残留）")
        check(CHHysteresis.percentFloor == 60
                  && CHHysteresis.thermalTerminateC == Discharge.temperatureLimitC
                  && CHHysteresis.thermalResumeHysteresisC == 2.0,
              "迟滞-23", "常量钉死：地板 60 / 热阈值与 Discharge 同源 40°C / 热恢复滞回 2°C")
    }
}
