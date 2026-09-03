// CellarCoreCheck —— WP1 充电侧温度暂停场景域（方案 §4.1 九项穷举）
//
// 覆盖清单（方案 §4.1 ①–⑨）：
// ① 矩阵 6 case 逐条正例：case 2 以 base==noop 为主形态（充电中升温主场景 +
//   放电终态恢复形态）；case 2 电池供电变体；base/context 不一致哨兵
// ② 边界值：39.99（带内）/ 40.0（停）/ 37.0（带内保持）/ 36.99（恢复）；
//   case 1 优先格（percent==upperLimit ∧ 热 → disable + active==false）
// ③ case 3/4 免写断言（action==noop）；case 5 恢复写（action==enable）
// ④ 完备性哨兵：base==enable 蕴含 chargingEnabled==false 的测试前置自检
// ⑤ 常量不变式：resumeC < pauseC
// ⑥ notificationEvents 两臂矩阵：enforce:tempPause 首样本 → 空；转移 → 空；
//   enforce:error/verifyFailed 既有钉不回归（用例 94 对照）
// ⑦ isTempPauseAction 助手：正/反/lastAction=nil/近似串不误命中
// ⑧ 守卫幂等性：同输入重复调用输出恒等（无记忆断言）
// ⑨ §2.3 旁路语义：temperatureC==nil → 动作与 base 一致 + 不抛错（旁路即透传；
//   nil 分支在 daemon 侧 enforceLimitChargingLocked——本域以常规决策 == base 的
//   CellarCore 可测面对照，防旁路与热停写语义混淆）

import CellarCore
import Foundation

/// 热守卫场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
/// throws：LimitPolicy 构造上抛即场景失败（与 DischargeDomain 同款分层——
/// 构造失败是测试栈错误，不吞）。
func runThermalGuardDomainScenarios() throws {
    // 热守卫-1：case 1 透传——限充停充（decide ⟺ percent ≥ 上限）优先且不标热暂停。
    do {
        let upper80 = try LimitPolicy(upperLimit: 80, hysteresis: 2)
        let controller = LimitController(policy: upper80)
        let ctx = ChargingContext(percent: 80, externalConnected: true, chargingEnabled: true)
        let base = controller.decide(context: ctx)
        let guarded = ThermalGuard.guarded(base: base, context: ctx, temperatureC: 45)
        check(guarded.action == .disableCharging && guarded.tempPauseActive == false,
              "热守卫-1", "percent==上限 ∧ 热 → case 1 透传 disable 且不标热暂停（限充滞留不误标）")
    }

    // 热守卫-2：case 2 主形态——base==noop（充电中升温主场景 + 放电终态恢复形态：
    // 恢复路径 CHTE 恒使能，decide 产出 noop）→ 热停写 + 标暂停。
    do {
        let ctx = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let guarded = ThermalGuard.guarded(base: .noop, context: ctx, temperatureC: 40.5)
        check(guarded.action == .disableCharging && guarded.tempPauseActive == true,
              "热守卫-2", "base==noop ∧ 充电中 ∧ t=40.5 → case 2 热停写 + 暂停态（不依赖 base 的主场景）")
    }

    // 热守卫-3：case 2 电池供电变体——external==false ∧ chargingEnabled ∧ 热 → 写停充
    //（门预置写，物理无害；回插热态即被挡）。
    do {
        let ctx = ChargingContext(percent: 55, externalConnected: false, chargingEnabled: true)
        let guarded = ThermalGuard.guarded(base: .noop, context: ctx, temperatureC: 41)
        check(guarded.action == .disableCharging && guarded.tempPauseActive == true,
              "热守卫-3", "电池供电 ∧ 热 → case 2 仍命中（写 CHTE=1 为门预置，方向 fail-safe）")
    }

    // 热守卫-4：base/context 不一致哨兵——base==enable ∧ chargingEnabled==true 人为
    // 构造输入（decide 下不可达）∧ 热 → 断言仍按 case 2 优先（防矩阵顺序回归
    // 到 v1.0「只看 base」的错误）。
    do {
        let ctx = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let guarded = ThermalGuard.guarded(base: .enableCharging, context: ctx, temperatureC: 40.2)
        check(guarded.action == .disableCharging && guarded.tempPauseActive == true,
              "热守卫-4", "base==enable ∧ 充电现态 true（不一致哨兵）∧ 热 → case 2 优先（case 3 需 ¬charging，顺序回归防护）")
    }

    // 热守卫-5：边界 t=39.99（带内充电中 → 继续充）/ t=40.0（停）——暂停阈值含入
    // 侧：40.0 停、39.99 不停。
    do {
        let charging = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let below = ThermalGuard.guarded(base: .noop, context: charging, temperatureC: 39.99)
        check(below.action == .noop && below.tempPauseActive == false,
              "热守卫-5", "t=39.99 ∧ 充电中 → case 6 透传继续充（不标暂停）")
        let at = ThermalGuard.guarded(base: .noop, context: charging, temperatureC: 40.0)
        check(at.action == .disableCharging && at.tempPauseActive == true,
              "热守卫-5", "t=40.0 ∧ 充电中 → case 2 停（>= 含入侧）")
    }

    // 热守卫-6：边界 t=37.0（带内保持）/ t=36.99（恢复）——恢复阈值严格小于：
    // 37.0 保持暂停、36.99 恢复。
    do {
        let stopped = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: false)
        let hold = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 37.0)
        check(hold.action == .noop && hold.tempPauseActive == true,
              "热守卫-6", "t=37.0 ∧ base==enable → case 4 带内保持（>= 含入侧，滞回）")
        let resume = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 36.99)
        check(resume.action == .enableCharging && resume.tempPauseActive == false,
              "热守卫-6", "t=36.99 ∧ base==enable → case 5 恢复写（严格小于）")
    }

    // 热守卫-7：case 1 优先格——percent==upperLimit ∧ 热（充电侧）→ 经 decide 后
    // base==disable → 透传且 active==false（热暂停不覆盖限充语义）。
    do {
        let upper80 = try LimitPolicy(upperLimit: 80, hysteresis: 2)
        let controller = LimitController(policy: upper80)
        let ctx = ChargingContext(percent: 80, externalConnected: true, chargingEnabled: true)
        let base = controller.decide(context: ctx)
        let guarded = ThermalGuard.guarded(base: base, context: ctx, temperatureC: 42)
        check(base == .disableCharging && guarded.action == .disableCharging && guarded.tempPauseActive == false,
              "热守卫-7", "percent==上限 ∧ t=42 → decide 产出 disable → case 1 透传 + active==false")
    }

    // 热守卫-8：case 3 免写——t ≥ 40 ∧ 已停充（base==enable）→ noop（已在暂停态，
    // 免重复写，SMC 无抖写）。
    do {
        let stopped = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: false)
        let guarded = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 40.5)
        check(guarded.action == .noop && guarded.tempPauseActive == true,
              "热守卫-8", "t=40.5 ∧ 已停充 → case 3 驻留 noop（免重复写）+ 暂停态")
    }

    // 热守卫-9：case 4 免写——37 ≤ t < 40 ∧ base==enable → noop（滞回带驻留）。
    do {
        let stopped = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: false)
        let guarded = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 38.5)
        check(guarded.action == .noop && guarded.tempPauseActive == true,
              "热守卫-9", "t=38.5 ∧ base==enable → case 4 带内保持 noop + 暂停态（滞回）")
    }

    // 热守卫-10：case 5 恢复写——t < 37 ∧ base==enable → enable（恢复充电）。
    do {
        let stopped = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: false)
        let guarded = ThermalGuard.guarded(base: .enableCharging, context: stopped, temperatureC: 35.0)
        check(guarded.action == .enableCharging && guarded.tempPauseActive == false,
              "热守卫-10", "t=35.0 ∧ base==enable → case 5 恢复写 + 退出暂停态")
    }

    // 热守卫-11：case 6 透传面——限充滞回保持（base==noop ∧ ¬charging）与电池供电
    // 停充态：透传 base、不标热暂停（这些态下停充才是现行原因，方案 §2.1 完备性）。
    do {
        let holdCtx = ChargingContext(percent: 79, externalConnected: true, chargingEnabled: false)
        let hold = ThermalGuard.guarded(base: .noop, context: holdCtx, temperatureC: 45)
        check(hold.action == .noop && hold.tempPauseActive == false,
              "热守卫-11", "限充滞回保持（base==noop ∧ ¬charging）∧ 热 → case 6 透传不标暂停")
        let batteryCtx = ChargingContext(percent: 60, externalConnected: false, chargingEnabled: false)
        let battery = ThermalGuard.guarded(base: .noop, context: batteryCtx, temperatureC: 45)
        check(battery.action == .noop && battery.tempPauseActive == false,
              "热守卫-11", "电池供电停充态 ∧ 热 → case 6 透传（无外接时停充与热无关，不误标）")
    }

    // 热守卫-12：完备性哨兵——decide 产出 base==enable 的上下文，充电现态必为
    // false（decide 只在停充态返回 enable，base==enable ⟺ 停充 ∧ percent < 恢复
    // 阈值；防矩阵回归到 v1.0「case 2 恢复变体」的错误假设）。
    do {
        let upper80 = try LimitPolicy(upperLimit: 80, hysteresis: 2)
        let controller = LimitController(policy: upper80)
        var checkedCount = 0
        for percent in [0, 50, 77] {
            let ctx = ChargingContext(percent: percent, externalConnected: true, chargingEnabled: false)
            let base = controller.decide(context: ctx)
            if base == .enableCharging {
                check(ctx.chargingEnabled == false, "热守卫-12", "base==enable ⇒ chargingEnabled==false（蕴含前置自检）")
                checkedCount += 1
            }
        }
        check(checkedCount == 3, "热守卫-12", "三个停充低电量上下文全部产出 enable（哨兵前置自检非空跑）")
    }

    // 热守卫-13：常量不变式——resumeC 严格小于 pauseC（3°C 滞回成立）。
    do {
        check(ThermalGuard.resumeC < ThermalGuard.pauseC, "热守卫-13", "resumeC(\(ThermalGuard.resumeC)) < pauseC(\(ThermalGuard.pauseC)) 不变式")
    }

    // 热守卫-14：notificationEvents 两臂钉空（方案 §4.1 项 6）——enforce:tempPause
    // 是正常保护动作，通知=噪音：首样本臂抑制 + 转移臂豁免；error/verifyFailed
    // 破例不回归（用例 94 对照）。
    do {
        func status(_ lastAction: String?, upper: Int = 90) -> DaemonStatus {
            DaemonStatus(
                version: "0.4.0-alpha", mode: "active", upperLimit: upper,
                hysteresis: 2, lastAction: lastAction, lastPercent: 90,
                lastExternalConnected: true, lastChargingEnabled: false
            )
        }
        check(notificationEvents(previous: nil, current: status("enforce:tempPause")) == [],
              "热守卫-14", "首样本 enforce:tempPause → 空（与常规字面量同款抑制，陈旧 lastAction 不通知）")
        check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:tempPause")) == [],
              "热守卫-14", "转移 noop → tempPause → 空（保护动作不进通知通道）")
        check(notificationEvents(previous: status("enforce:tempPause"), current: status("enforce:enableCharging")) == [],
              "热守卫-14", "转移 tempPause → enable → 空（恢复亦不通知）")
        check(notificationEvents(previous: status("enforce:tempPause"), current: status("enforce:noop")) == [],
              "热守卫-14", "转移 tempPause → noop → 空（离开暂停无事件）")
        check(notificationEvents(previous: nil, current: status("enforce:error")) == [.writeFailed],
              "热守卫-14", "首样本 enforce:error 破例不回归（用例 94 对照）")
        check(notificationEvents(previous: status("enforce:noop"), current: status("enforce:verifyFailed")) == [.conflictSuspected],
              "热守卫-14", "转移 verifyFailed 破例不回归（用例 94 对照）")
    }

    // 热守卫-15：isTempPauseAction 助手（方案 §4.1 项 7）正/反/nil/近似串。
    do {
        func status(_ lastAction: String?) -> DaemonStatus {
            DaemonStatus(
                version: "0.4.0-alpha", mode: "active", upperLimit: 90,
                hysteresis: 2, lastAction: lastAction
            )
        }
        check(status("enforce:tempPause").isTempPauseAction == true,
              "热守卫-15", "字面量 enforce:tempPause → true")
        check(status("enforce:noop").isTempPauseAction == false,
              "热守卫-15", "常规字面量 → false")
        check(status(nil).isTempPauseAction == false,
              "热守卫-15", "lastAction==nil → false")
        check(status("enforce:tempPaused").isTempPauseAction == false,
              "热守卫-15", "近似串 enforce:tempPaused 不误命中（精确比较）")
    }

    // 热守卫-16：幂等性（方案 §4.1 项 8）——同输入重复调用输出恒等（无记忆断言）。
    do {
        let ctx = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let first = ThermalGuard.guarded(base: .noop, context: ctx, temperatureC: 41)
        let second = ThermalGuard.guarded(base: .noop, context: ctx, temperatureC: 41)
        check(first.action == second.action && first.tempPauseActive == second.tempPauseActive,
              "热守卫-16", "同输入两次调用输出恒等（纯函数无记忆）")
    }

    // 热守卫-17：§2.3 旁路语义（方案 §4.1 项 9）——temperatureC==nil 时守卫不进
    // 判定链，动作与 base 一致且不抛错。nil 分支在 daemon 侧
    // enforceLimitChargingLocked（本工具不可 import daemon 目标），其可测面前置为
    // 「常规决策 == base」：热态充电上下文旁路产出 = decide 结果（noop），与套守卫
    // 的热停写形成语义分离——旁路不会误带出热停写。
    do {
        let upper80 = try LimitPolicy(upperLimit: 80, hysteresis: 2)
        let controller = LimitController(policy: upper80)
        let hotCharging = ChargingContext(percent: 60, externalConnected: true, chargingEnabled: true)
        let base = controller.decide(context: hotCharging)
        check(base == .noop, "热守卫-17", "热态充电上下文常规决策 == noop（= nil 旁路的动作，透传即 base）")
        let guarded = ThermalGuard.guarded(base: base, context: hotCharging, temperatureC: 41)
        check(guarded.action == .disableCharging && guarded.tempPauseActive == true,
              "热守卫-17", "同上下文套守卫 → 热停写——旁路（enforce 常规决策）与守卫的差异即 nil 旁路语义")
    }
}