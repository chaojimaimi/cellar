// CellarCoreCheck —— 0.21.0 §1 set 路径场景域（方案 §1.1/§1.2/§1.3/§1.5；**0.23.1
// 编排退役翻新**）
//
// 覆盖清单（工单门禁钉死项）：
// ① set 分流与拒绝链（≥80 set / <80 → nil 不写 / Code=4 结构化拒绝 + 文案钉死 /
//    失败分类三态）
// ② fullOnce 27 前置（平台判别原生守卫绕过——0.23.1 全Once 纯 daemon 化钉面；
//    编排开关拒收面随编排退役删除）
// ③ 关断残留检测（**0.23.1 四行表**：两窗/mode 关恒 100 / degraded → max(target,80)
//    / 非 degraded → 100——域承载全区间新常态）
// ④ convergenceRoute fullOnce 窗（窗内 target 强制 100、topoffOwned 失效——0.23.1
//    两输出签名）
// ⑤ 恢复臂 XPC 命令字面量 + makeMessage/validateRequest 通道
// ⑥ doctor 检查 17 执行通道（恢复/对账用）+ 检查 20 关断残留（检查 19 随编排退役
//    删除——位号留空）
// ⑦ 补偿臂静默门（**0.23.1 宽读钉死**：sub80State == .active 即静默全区间——
//    混装 G1 防）
// ⑧ degradedWriteValue 统一钉面（channelTick/healTick 写点同值）
// 原 set-6 恢复臂判定源（fullOnceRestoreAvailable）/ set-16 拒收文案 /
// set-14 OrchestrationState 窗位面随编排退役删除（App 侧判定源改挂 wire
// fullOnceWindowActive——R4）。
//
// 全部纯函数面（Data 注入 / 临时目录），不触碰真实 plist、不起 daemon、不做真实
// ObjC set 调用（set 面 I/O 在 App 侧 MCLClient——CellarCoreCheck 只钉决策）。

import CellarCore
import Foundation
import XPC

/// 0.21.0 §1 set 路径场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runNativeLimitSetDomainScenarios() throws {
    try runSetRouteScenarios()
    try runSetFailureClassificationScenarios()
    try runFullOncePreconditionScenarios()
    try runShutdownExpectationScenarios()
    try runConvergenceRouteFullOnceWindowScenarios()
    try runRestoreWireScenarios()
    try runDoctorNativeLimitScenarios()
    try runCompensationSilencedScenarios()
    try runDegradedWriteValueScenarios()
}

// MARK: - ②' fullOnce 27 前置（0.23.1 纯 daemon 化钉面——平台判别 + 原生守卫绕过）

private func runFullOncePreconditionScenarios() throws {
    // set-5（≥4）：27 臂放行（原生守卫绕过）+ 26 守卫逐值 + 次序钉。
    do {
        // 27 平台判别 → 放行（无编排开关拒收面——置窗交 daemon）。
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: true, capabilities: ["orchestration"]) == nil,
              "set-5", "27 平台判别 → 放行（原生守卫绕过——App/域写覆写 MCL，残留非阻断）")
        // 27 ∧ 原生残留 85 在场 → 仍放行（27 臂先于 native——守卫绕过职责钉面）。
        let residual = NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false),
        ], detectorError: false)
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: true, nativeLimit: residual,
            capabilities: ["orchestration"]) == nil,
              "set-5", "27 ∧ 残留 85 在场 → 放行（27 臂先于 native——残留非阻断）")
        // 26 legacy（[]）/ 26 瞬态（nil）→ 走原生守卫（26 行为零变化）。
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: true, capabilities: []) == nil,
              "set-5", "26 legacy：capabilities=[]（CH0B 后端在场）→ 放行（勿用 [] 误判 27）")
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: true, capabilities: nil) == nil,
              "set-5", "26 瞬态：capabilities=nil（后端缺席窗口）→ 放行（勿用 backend nil 误判 27——平台判别钉面）")
        // mode/外接门仍最优先。
        check(fullOnceStartPrecondition(
            mode: "disabled", externalConnected: true, capabilities: ["orchestration"]) == .modeNotActive,
              "set-5", "mode 门先于 27 臂判定（既有前置次序不被扰动）")
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: false, capabilities: ["orchestration"]) == .noExternalPower,
              "set-5", "外接门先于 27 臂判定")
        // 26 原生守卫逐值（残留阻断）。
        check(fullOnceStartPrecondition(
            mode: "active", externalConnected: true, nativeLimit: residual,
            capabilities: ["discharge"]) == .nativeChargeLimit(socLimit: 85),
              "set-5", "26 ∧ 残留 85 → nativeChargeLimit 拒绝（26 原生守卫逐值不变——26 红线）")
    }
}

// MARK: - ① set 分流（0.22.4 模型 v2：≥80 set / <80 → nil 不写）

private func runSetRouteScenarios() throws {
    // set-1：执行目标映射（**0.22.4 模型 v2 退役版**——<80 → nil 不写：域写值
    // 直接流入 MCL 执法〔M1〕，任何 100 补写只造 M2 环境拖慢域接管；历史链
    // 0.21.0「钳 80」→ 0.21.3「<80→100」均已退役，见 NativeLimitSet.setTarget
    // 头注；≥80 → 原值直写不变）。
    check(NativeLimitSet.setTarget(for: 85) == 85, "set-1", "85 → 85（≥80 直通——S3 实证目标）")
    check(NativeLimitSet.setTarget(for: 100) == 100, "set-1", "100 → 100（充满语义）")
    check(NativeLimitSet.setTarget(for: 80) == 80, "set-1", "80 → 80（set 下限边界恒等）")
    check(NativeLimitSet.setTarget(for: 75) == nil, "set-1", "75 → nil（0.22.4 映射退役：<80 不写 MCL——域直接执法，旧「→100」为 13:32 互搏元凶链）")
    check(NativeLimitSet.setTarget(for: 60) == nil, "set-1", "60（地板值）→ nil（同上——执行体永不向原生 MCL 写 <80 值，也不再写 100）")
    // 常量钉死。
    check(NativeLimitSet.minimumSetLimit == 80 && NativeLimitSet.maximumSetLimit == 100,
          "set-1", "set 域 80-100（S3 定谳——<80 被 Code=4 拒绝）")
    check(NativeLimitSet.fullOnceTarget == 100, "set-1", "fullOnce 临时放开目标 = 100（0.23.1 语义钉面——pending 产出链随编排退役删除，域随写 100 由 Topoff.shutdownLimit 承担）")
}

// MARK: - ①' set 失败链分类（Code=4 结构化拒绝）

private func runSetFailureClassificationScenarios() throws {
    // set-2：结构化拒绝分类（domain/code → case）。
    check(MCLSetFailure.classify(
        domain: "PowerUISmartChargingErrorDomain", code: 4, message: "x") == .nativeFloorMinimum,
          "set-2", "PowerUISmartChargingErrorDomain Code=4 → .nativeFloorMinimum（S3 定谳 80 下限）")
    check(MCLSetFailure.classify(
        domain: "PowerUISmartChargingErrorDomain", code: 5, message: "x") != .nativeFloorMinimum,
          "set-2", "同域非 4 Code → 非结构化拒绝（实例级失败）")
    check(MCLSetFailure.classify(
        domain: "OtherDomain", code: 4, message: "x") != .nativeFloorMinimum,
          "set-2", "异域同 Code → 非结构化拒绝（域+码双判据）")
    // 文案钉死（§1.1 失败链——UI 如实提示，不静默）。0.23.0 §③ 实验性摘帽：
    // 去「实验性通道」措辞（<80 目标由 Cellar 限充域直接执法——模型 v2）。
    check(String(describing: MCLSetFailure.nativeFloorMinimum)
              == "系统原生限充最低 80——更低目标由 Cellar 限充通道直接执法",
          "set-2", "Code=4 结构化拒绝文案钉死（0.23.0 摘帽版——更低由 Cellar 域直接执法）")
    check(String(describing: MCLSetFailure.channelUnavailable)
              .contains("类缺席"),
          "set-2", "类缺席失败文案含「类缺席」（sticky 平台终态）")
    check(String(describing: MCLSetFailure.callFailed(domain: "D", code: 9, message: "boom"))
              == "原生限充 set 调用失败（D Code=9）：boom",
          "set-2", "实例级失败文案含域/码/详情（原文通道上屏）")
}

// MARK: - ③ MCL 对账期望值四行表（**0.23.1 编排退役定版**——原八行表随编排开关
// 决策面退役收敛）

private func runShutdownExpectationScenarios() throws {
    // set-7（四行表行 1-3）：两窗与 mode 关恒 100（优先级自上而下；行 1/2 由
    // wire 两窗字段供给——窗覆盖优先于一切）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 85,
            fullOnceWindowActive: true) == 100,
          "set-7", "fullOnce 窗 ∧ 85 → 100（行 1 窗覆盖——优先级最高）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 75,
            chargingDisabledWindowActive: true) == 100,
          "set-7", "chargingDisabled 日程窗 ∧ 75 → 100（行 2 完全放开——两窗同权）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: false, upperLimit: 75) == 100,
          "set-7", "mode 关 ∧ target 75 → 100（行 3 全开语义与域 100 对齐——set 80 会重造「UI 已停用实际限 80」残留）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: false, upperLimit: 85) == 100,
          "set-7", "mode 关 ∧ target 85 → 100（行 3 恒等）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: false, upperLimit: 75,
            degraded: true) == 100,
          "set-7", "mode 关 ∧ degraded → 仍 100（行 3 优先于 degraded 行——真停用即全开）")

    // set-8（四行表行 4，0.23.1 收敛语义）：degraded → degradedWriteValue(for:)=
    // max(target,80)（<80 目标 80 不变——域通道死亡最后防线；≥80 目标随 target——
    // 与 Topoff 降级稳态钳/四写点同源）；非 degraded → 100（**域承载全区间新常态**
    // ——MCL 让域管；原「编排开 ∧ ≥80 → target」行随编排退役删除：≥80 域承载即
    // MCL 主导替代，App 侧该区间由宽读静默门兜住不再补偿）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 75,
            degraded: true) == 80,
          "set-8", "target 75 ∧ degraded → 80（行 4——max(75,80)，域通道死亡最后防线）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 85,
            degraded: true) == 85,
          "set-8", "target 85 ∧ degraded → 85（**0.23.0 §④ 翻新保留**：max(85,80)=85——降级写值统一后期望随行不再钳 80）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 80,
            degraded: true) == 80,
          "set-8", "target 80（边界）∧ degraded → 80（行 4 边界恒等——max(80,80)）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 75) == 100,
          "set-8", "target 75（<80 非 degraded）→ 100（域承载——MCL 让域管）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 85) == 100,
          "set-8", "target 85（≥80 非 degraded）→ 100（**0.23.1 收敛**——原「编排开 → target」行删除：域承载全区间，MCL 必须 100）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 100) == 100,
          "set-8", "target 100 → 100（全开恒等）")

    // set-9b：缺省参数保源兼容（degraded/两窗缺省 false——既有构造点零 diff）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, upperLimit: 85) == 100,
          "set-9b", "缺省三参（degraded=false/两窗 false）→ 100（域承载新常态——期望表收敛后唯一非 degraded 值）")

    // set-9c（迁移钉面保留——原 DischargeOscillationDomain :177/:267 的 W4 断言）：
    check(NativeLimitSet.shutdownExpectation(
        modeActive: true, upperLimit: 80) == 100,
          "set-9c", "target 80 → 期望 100（迁移自振荡域 乒乓-2——域承载全区间 MCL 100 让域管）")
    check(NativeLimitSet.shutdownExpectation(
        modeActive: false, upperLimit: 80) == 100,
          "set-9c", "mode 关 → 关断期望恒 100（迁移自振荡域 矩阵-4——行 3 真停用=放开，优先于 degraded 行）")
}

// MARK: - ⑩ 0.23.0 §④ degradedWriteValue 统一钉面（四写点同值 + W4 行 6/7 同源）

private func runDegradedWriteValueScenarios() throws {
    // 降-1：helper 公式钉面（max(target, degradedLimit)——与 SuppressionRecovery.
    // openValue 公式互钉，红队 F7 附注）。
    check(Topoff.degradedWriteValue(for: 75) == 80, "降-1",
          "target 75 → 80（<80 目标 degraded 恒回退 80——既有语义不变）")
    check(Topoff.degradedWriteValue(for: 60) == 80, "降-1",
          "target 60（地板）→ 80（同上——native 地板以上收敛）")
    check(Topoff.degradedWriteValue(for: 85) == 85, "降-1",
          "target 85 → 85（0.23.0 §④ 语义收益：≥80 目标 degraded 停 target 不再被拉到 80）")
    check(Topoff.degradedWriteValue(for: 80) == 80, "降-1",
          "target 80（边界）→ 80（max 恒等）")
    check(Topoff.degradedWriteValue(for: 100) == 100, "降-1",
          "target 100 → 100（防御性上界——degraded 非 <80 专属）")
    // 常量边界角色钉死：degradedLimit 80 保留为 <80 判据/domainBackstop/迟滞门比较面。
    check(Topoff.degradedLimit == 80, "降-1",
          "degradedLimit == 80（边界角色保留——sub80Carried/domainBackstop/CHHysteresis 门不随写值统一漂移）")

    // 降-2（原写点 ①convergenceRoute desired）：**0.23.1 编排退役删除**——原「编排
    // 钳 degradedWriteValue」断言面随断言链退役（desired 恒 nil，写点①消失）；
    // 降级写值仅剩 channelTick/healTick 三写点（降-3/降-4 承接）。
    do {
        let route = Topoff.convergenceRoute(
            modeActive: true, chargingDisabledWindow: false,
            upperLimit: 75, sub80Capable: true, actionActive: false
        )
        check(route.topoffOwned && route.convergenceTarget == 75, "降-2",
              "路由签名收敛锚（0.23.1——degraded/healProbe 输入删除，写点①随断言链退役；降级写值由状态机写点承接）")
    }

    // 降-3（写点 ②channelTick strike 降级拍）：第 3 strike 降级写随写值统一。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 85
        s.lastWrittenLimit = 85
        s.lastWriteAt = Date(timeIntervalSince1970: 0)
        var plan: TopoffTickPlan?
        for n in 1...20 {
            plan = Topoff.channelTick(
                state: s, target: 85, now: Date(timeIntervalSince1970: Double(n) * 30),
                percent: 90, externalConnected: true, isCharging: true)
            s = plan!.state
        }
        // 连续三窗各耗 1 strike（间随 10 min 冷却）——此处直接构造 strikes=2 前态
        // 再走第 3 窗，钉降级拍写值。
        s.strikes = 2
        s.violationTicks = 19
        let degrade = Topoff.channelTick(
            state: s, target: 85, now: Date(timeIntervalSince1970: 1000),
            percent: 90, externalConnected: true, isCharging: true)
        check(degrade.writeLimit == 85 && degrade.state.degraded && degrade.strikeFired,
              "降-3", "第 3 strike 降级拍 target 85 → 域写 85（**写点②翻新**——max(85,80)；strikeFired 语义不变）")
        check(degrade.state.lastHealProbeAt != nil, "降-3", "降级拍播种 lastHealProbeAt（P2 评审修法保留）")
    }

    // 降-4（写点 ③④healTick 两回稳态臂）：自愈失败回稳态 / 无差别超时臂随写值统一。
    do {
        // ③ 自愈失败：探针观察窗 20 连续违规 → 回稳态写 degradedWriteValue。
        var s = TopoffChannelState()
        s.degraded = true
        s.healProbeActive = true
        s.healProbeTicks = 19
        s.activeTarget = 85
        s.lastWrittenLimit = 85
        let fail = Topoff.healTick(
            state: s, target: 85, now: Date(timeIntervalSince1970: 1000),
            percent: 90, externalConnected: true, isCharging: true)
        check(fail.writeLimit == 85 && !fail.state.healProbeActive, "降-4",
              "自愈失败回稳态 target 85 → 域写 85（**写点③翻新**——max(85,80)，下小时再探）")
        // ④ 无差别超时臂：窗满 20 tick 弱信号 → 补写 degradedWriteValue。
        var s2 = TopoffChannelState()
        s2.degraded = true
        s2.healProbeActive = true
        s2.healProbeTicks = 19
        s2.activeTarget = 85
        s2.lastWrittenLimit = 85
        let timeout = Topoff.healTick(
            state: s2, target: 85, now: Date(timeIntervalSince1970: 1000),
            percent: 82, externalConnected: true, isCharging: false)
        check(timeout.writeLimit == 85 && !timeout.state.healProbeActive, "降-4",
              "无差别超时臂 target 85 → 补写 85（**写点④翻新**——max(85,80) 维持稳态不变量）")
        // <80 对照：两臂写 80 不变（既有语义恒等回归锚）。
        var s3 = TopoffChannelState()
        s3.degraded = true
        s3.healProbeActive = true
        s3.healProbeTicks = 19
        s3.activeTarget = 75
        s3.lastWrittenLimit = 75
        let fail75 = Topoff.healTick(
            state: s3, target: 75, now: Date(timeIntervalSince1970: 1000),
            percent: 90, externalConnected: true, isCharging: true)
        check(fail75.writeLimit == 80, "降-4",
              "自愈失败回稳态 target 75 → 域写 80（<80 恒等——degradedWriteValue(75)=80）")
    }
}

// MARK: - ⑥ convergenceRoute fullOnce 窗（§1.3 临时放开窗；0.23.1 两输出签名翻新）

private func runConvergenceRouteFullOnceWindowScenarios() throws {
    // set-10：窗内汇聚目标强制 100（等价「完全放开」——域随写 100，M1 模型 v2
    // 域写值直接执法）。topoffOwned 失效（窗排除——R1-P1-1 保留）。
    let window75 = Topoff.convergenceRoute(
        modeActive: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false, fullOnceWindow: true
    )
    check(window75.convergenceTarget == 100, "set-10", "窗内 target 75 → 汇聚目标 100（域随写 100——M1 域写值直接执法）")
    check(!window75.topoffOwned, "set-10", "窗内 topoffOwned 失效（窗排除——channelTick 不对抗，卫生臂跟 100）")
    let window85 = Topoff.convergenceRoute(
        modeActive: true, chargingDisabledWindow: false,
        upperLimit: 85, sub80Capable: true, actionActive: false, fullOnceWindow: true
    )
    check(window85.convergenceTarget == 100 && !window85.topoffOwned,
          "set-10", "窗内 target 85 → 同形态（policy ≥80 分支同样强制 100）")
    // set-12：mode 门仍最优先——mode 关 ∧ 窗在 → 汇聚 nil（窗位随 disable 清除，
    // 纯函数层面 mode 门兜底）。
    let windowDisabled = Topoff.convergenceRoute(
        modeActive: false, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false, fullOnceWindow: true
    )
    check(windowDisabled.convergenceTarget == nil && !windowDisabled.topoffOwned,
          "set-12", "mode 关 ∧ 窗在 → 汇聚 nil ∧ 不承载（mode 门最优先——R3-P1 期望派生由调用侧承担）")
    // set-13：缺省参数零 diff（26/既有构造回归锚——不传 fullOnceWindow，真值表
    // 逐值不变；0.23.1 两输出签名）。
    let legacy75 = Topoff.convergenceRoute(
        modeActive: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false
    )
    check(legacy75.convergenceTarget == 75 && legacy75.topoffOwned,
          "set-13", "缺省（窗 false）→ target 75 汇聚（topoff 承载）——0.23.1 收敛签名逐值锚")
    let legacy85 = Topoff.convergenceRoute(
        modeActive: true, chargingDisabledWindow: false,
        upperLimit: 85, sub80Capable: true, actionActive: false
    )
    check(legacy85.convergenceTarget == 85 && legacy85.topoffOwned,
          "set-13", "缺省 target 85 → 域承载全区间（0.23.1 新常态逐值锚——窗语义不受影响）")
    // set-14：窗位宿主随编排退役翻新——原 OrchestrationState 五字段面删除，窗位
    // 落 daemon 核心态 `fullOnceWindowActive`（CellarCoreCheck 不可 import daemon，
    // 结构面由 wire round-trip 钉死——TopoffReadbackDomain 全域-3 窗排除 + 本域
    // set-10 窗语义互证）。
    check(Topoff.shutdownLimit == 100, "set-14",
          "窗域写值源钉面（daemon 置窗 → observation tick 卫生臂写 shutdownLimit=100——原 pending(100) 产出链随批删除）")
}

// MARK: - ⑦ 恢复臂 XPC 通道

private func runRestoreWireScenarios() throws {
    // set-15：命令字面量钉死 + makeMessage/validateRequest 通道（无新键型——cmd 字面量
    // 既有白名单机制天然承载；upper/hysteresis 缺省 0 同 cancelAction 形态）。
    check(NativeLimitSet.restoreCommand == "restoreChargeLimit",
          "set-15", "恢复臂命令字面量钉死（§1.3——与 fullOnce/cancelAction 同域命名）")
    do {
        let msg = DaemonXPC.makeMessage(cmd: NativeLimitSet.restoreCommand, upper: 0, hysteresis: 0)
        let parsed = DaemonXPC.validateRequest(msg)
        check(parsed?.cmd == "restoreChargeLimit" && parsed?.upper == 0 && parsed?.hysteresis == 0,
              "set-15", "恢复臂消息 → cmd 提取 + 无参形态（0.23.1 daemon 端 = 清窗 + 清锁存 + 即时 tick 域写 policy.upperLimit——原拒收面随编排退役删除）")
    }
}

// MARK: - ⑧ doctor 检查 17 执行通道（恢复/对账用）+ 检查 20 关断残留（0.23.1：
// 检查 19 临时放开残留随编排退役删除——读回 100 即域承载稳态，触发面 = 常态必误报）

private func runDoctorNativeLimitScenarios() throws {
    let snapshot = try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date())
    func doctorInputs(
        mclProbe: MCLDoctorProbe? = nil,
        mclAttempted: Bool = false,
        osMajorVersion: Int = 27,
        daemonMode: String = "active",
        daemonUpperLimit: Int = 85,
        daemonCapabilities: [String]? = ["orchestration"],
        daemonSub80State: Sub80State? = nil,
        daemonSuppressed: Bool? = nil,
        daemonHealProbe: Bool? = nil,
        daemonFullOnceWindow: Bool? = nil,
        daemonScheduleWindow: Bool? = nil
    ) -> DoctorInputs {
        DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .noneAvailable,
            chargingEnabled: nil, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(
                version: "t", mode: daemonMode, upperLimit: daemonUpperLimit, hysteresis: 2,
                capabilities: daemonCapabilities,
                orchestration: OrchestrationStatus(enabled: false),
                sub80State: daemonSub80State,
                sub80HealProbeActive: daemonHealProbe,
                sub80MechanismSuppressed: daemonSuppressed,
                fullOnceWindowActive: daemonFullOnceWindow,
                chargingDisabledWindowActive: daemonScheduleWindow,
                timestamp: Date()),
            daemonProbeAttempted: true,
            mclProbe: mclProbe,
            mclProbeAttempted: mclAttempted,
            osMajorVersion: osMajorVersion
        )
    }
    func check17(_ inputs: DoctorInputs) -> DoctorCheck? {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "编排通道" }
    }
    func check20(_ inputs: DoctorInputs) -> DoctorCheck? {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "关断残留" }
    }

    // 医生-16（检查 17 改文案版——0.23.1「执行通道（恢复/对账用）」）：判定门 = MCL 探测。
    do {
        let embedded = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil),
            mclAttempted: true
        ))
        check(embedded?.status == .pass
                  && embedded?.detail.contains("执行通道（恢复/对账用）") == true
                  && embedded?.detail.contains("读回 85%") == true,
              "医生-16", "27 ∧ MCL 可读 → PASS「执行通道（恢复/对账用）」（0.23.1 改文案——编排断言面退役，set 剩余职责 = 恢复链 + W4 对账）")
        // 26 同输入 → INFO 不适用形态（26 无 App 内嵌 set 面——daemon 直控）。
        let legacy = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil),
            mclAttempted: true,
            osMajorVersion: 26
        ))
        check(legacy?.status == .info && legacy?.detail.contains("仅 macOS 27+") == true,
              "医生-16", "26 ∧ MCL 可读 → INFO 不适用（daemon 直控）")
        // 27 ∧ MCL 类缺席 → INFO set 通道不可用（域通道承接 + 系统设置退路）。
        let classMissing = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: false, limit: nil,
                                     failureDetail: "PowerUISmartChargeClient 类缺席"),
            mclAttempted: true
        ))
        check(classMissing?.status == .info
                  && classMissing?.detail.contains("App 内嵌 set 通道不可用") == true
                  && classMissing?.detail.contains("类缺席") == true
                  && classMissing?.detail.contains("系统设置") == true,
              "医生-16", "27 ∧ MCL 类缺席 → INFO set 不可用（域承接 + 系统设置退路）")
        // mclAttempted 缺省 → 零渲染（检查 15/16 同款条件渲染兼容约束）。
        check(check17(doctorInputs()) == nil,
              "医生-16", "mclProbeAttempted 缺省 → 检查 17 不渲染（判定门 = MCL 探测）")
        // **0.23.1 检查 19 退役锚**：原「临时放开残留」检查不再渲染（读回 100 ∧
        // policy<100 的触发面 = 域承载稳态——退役后无任何输入组合产出该检查）。
        check(DoctorReportGenerator.generate(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil),
            mclAttempted: true, daemonUpperLimit: 85
        )).checks.first { $0.name == "临时放开残留" } == nil,
              "医生-16", "检查 19 退役——读回 100 ∧ policy 85 不再产出「临时放开残留」（位号留空——编号空洞如实登记）")
    }

    // 医生-18（检查 20 关断残留→MCL 对账）：0.23.1 四行表期望派生 × 读回
    // 失配矩阵 + **§1.3 suppressed/残留双态合取**（suppressed 优先 FAIL 抬退出码
    // ——「info 恒不抬」纪律的登记例外；无 suppressed 才评残留 INFO）。
    do {
        // 双态合取第一态：suppressed（daemon wire）→ FAIL + 三分支教育指引 +
        // **抬退出码**（info 恒不抬纪律的例外——机制被系统设置关闭需用户行动）。
        let suppressed = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonSuppressed: true
        ))
        check(suppressed?.status == .fail
                  && suppressed?.detail.contains("已关闭原生限充机制") == true
                  && suppressed?.detail.contains("具体上限") == true
                  && suppressed?.detail.contains("切勿用 100%") == true,
              "医生-18", "suppressed → FAIL 同名指引（「设具体上限/勿用 100% 作关闭」——优先于残留评估）")
        check(suppressed.map { DoctorReport(checks: [$0]).exitCode } == 2,
              "医生-18", "suppressed FAIL → 抬退出码 2（R2-P3-3：info 恒不抬纪律的唯一例外）")
        // review P3：suppressed 分支在 mcl.readable 门之前——MCL 类缺席/读取失败
        // 的边角形态不压掉 FAIL 臂（域侧 wire 证据不受 MCL 探测可用性门控）。
        let suppressedMclBlind = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: false, limit: nil, failureDetail: "类缺席"),
            mclAttempted: true, daemonUpperLimit: 85, daemonSuppressed: true
        ))
        check(suppressedMclBlind?.status == .fail
                  && suppressedMclBlind?.detail.contains("已关闭原生限充机制") == true,
              "医生-18", "suppressed ∧ MCL 类缺席 → 仍 FAIL（挪序钉面——域侧证据不被 MCL 探测门控）")
        // suppressed 优先于一致态：即使读回 == 期望，suppressed 仍 FAIL（合取次序钉死）。
        let suppressedEvenMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonSuppressed: true,
            daemonFullOnceWindow: true   // 期望 100 == 读回 100
        ))
        check(suppressedEvenMatch?.status == .fail,
              "医生-18", "suppressed ∧ 读回 == 期望 → 仍 FAIL（双态合取：第一态优先）")

        // disable（mode 关）→ 期望 100；读回 85 ≠ 100 → INFO + 修正后指引（三分支教育）。
        let disabledMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonMode: "disabled", daemonUpperLimit: 85
        ))
        check(disabledMismatch?.status == .info && disabledMismatch?.detail.contains("期望值 100%") == true
                  && disabledMismatch?.detail.contains("读回 85%") == true
                  && disabledMismatch?.detail.contains("切勿设 100%") == true,
              "医生-18", "mode 关 + 读回 85 → INFO + G1 修正指引（设具体值或交给 Cellar——不再引导「按需关闭/set 80」）")
        // disable 一致 → PASS。
        let disabledMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonMode: "disabled", daemonUpperLimit: 85
        ))
        check(disabledMatch?.status == .pass && disabledMatch?.detail.contains("MCL 对账一致") == true,
              "医生-18", "mode 关 + 读回 100 → PASS 对账一致")
        // 行 4 非 degraded（域承载全区间新常态）：期望 100；读回 85 → INFO。
        let domainCarry = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85
        ))
        check(domainCarry?.status == .info && domainCarry?.detail.contains("期望值 100%") == true,
              "医生-18", "target 85 非降级 + 读回 85 → INFO 期望 100（**0.23.1 四行表**——原「编排开 → target」行随编排退役删除，域承载全区间 MCL 让域管）")
        let domainCarryMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85
        ))
        check(domainCarryMatch?.status == .pass,
              "医生-18", "target 85 非降级 + 读回 100 → PASS（行 4 非 degraded 臂一致）")
        // <80 非 degraded：期望 100（MCL 让域管）。
        let sub80Mismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75
        ))
        check(sub80Mismatch?.status == .info && sub80Mismatch?.detail.contains("期望值 100%") == true,
              "医生-18", "target 75 + 读回 85 → INFO 期望 100（域承载——MCL 100 让域管）")
        // degraded（行 4 钳臂）：期望 max(target,80)。
        let degradedClamp = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75, daemonSub80State: .degraded
        ))
        check(degradedClamp?.status == .info && degradedClamp?.detail.contains("期望值 80%") == true,
              "医生-18", "target 75 ∧ degraded + 读回 100 → INFO 期望 80（行 4 钳臂——域通道死亡最后防线）")
        let degraded85 = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonSub80State: .degraded
        ))
        check(degraded85?.status == .pass,
              "医生-18", "target 85 ∧ degraded + 读回 85 → PASS（行 4 钳臂 max(85,80)=85——0.23.0 §④ 翻新保留）")
        // 两窗行（行 1/2）：窗在位 → 期望 100；读回 85 → INFO（窗语义=完全放开）。
        let windowMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonFullOnceWindow: true
        ))
        check(windowMismatch?.status == .info && windowMismatch?.detail.contains("期望值 100%") == true,
              "医生-18", "fullOnce 窗 + 读回 85 → INFO 期望 100（行 1 窗覆盖——wire 供给）")
        // code-review P3 补钉：静默态失配 → 附注文案（**0.23.1 宽读**——sub80State
        // == .active 即静默全区间，含 ≥80）——与补偿臂同一门函数单一真相；防文案漂移。
        let silencedMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonSub80State: .active
        ))
        check(silencedMismatch?.status == .info
              && silencedMismatch?.detail.contains("不对账属预期") == true
              && silencedMismatch?.detail.contains("自动对账补偿") == false,
              "医生-19", "静默态失配（域承载 active ∧ 85 失配）→ 附注「不对账属预期」且无补偿承诺（**0.23.1 宽读钉面**——文案分支）")
        // 读回类缺席 → 不渲染（读通道死态无对账可言——诚实缺席）。
        check(check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: false, limit: nil, failureDetail: "类缺席"),
            mclAttempted: true, daemonMode: "disabled")) == nil,
              "医生-18", "MCL 类缺席 → 检查 20 不渲染（读回不可用即无法对账）")
        // 26 → 不渲染（MCL 读回仅 set 路径语境有语义——26 红线）。
        check(check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            osMajorVersion: 26, daemonMode: "disabled")) == nil,
              "医生-18", "26 → 检查 20 不渲染（27 门控——零回归）")
        // 未探测缺省 → 零渲染。
        check(check20(doctorInputs()) == nil, "医生-18", "mclProbeAttempted 缺省 → 检查 20 不渲染")
    }
}

// MARK: - ⑨ 0.22.4 → **0.23.1 宽读**补偿臂静默门（§0.9 红队钉面 + 场景 ≥10 case）

private func runCompensationSilencedScenarios() throws {
    // 门-1（mode/两窗优先级）：mode 非 active → 不静默（W4-now 即时变体放开语义
    // 保留——期望恒 100 与域 100 同值无互搏面）；两窗各 1 → 不静默（窗语义 =
    // 显式放开，期望 100 与域随写 100 同值）。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: false, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active),
        "门-1", "mode 非 active → 不静默（放开语义保留）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: true, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active),
        "门-1", "fullOnce 窗在位 → 不静默（窗覆盖期望 100——域同值无互搏）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: true,
        healProbeActive: false, sub80State: .active),
        "门-1", "chargingDisabled 日程窗在位 → 不静默（完全放开同值）")

    // 门-2（**0.23.1 宽读钉死**）：sub80State == .active 即静默——<80 与 ≥80 同判
    //（域承载全区间新常态；域写值直接流入 MCL 执法——任何区间补偿写都对域写值对抗）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active),
        "门-2", "active ∧ target <80 → 静默（域承载——13:32 元凶面）")
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active),
        "门-2", "active ∧ target ≥80 → 同静默（**宽读**——原「编排开 ∧ ≥80 不静默」分支随编排退役删除；域承载全区间即 MCL 主导替代）")

    // 门-3（混装 G1 防钉面，红队 §0.9）：新 App + 旧 daemon 混装窗——旧 daemon
    // 编排开 ∧ ≥80 域不承载但 wire sub80State 仍 .active；宽读静默使新 App 补偿臂
    // 不对旧 daemon 的 MCL 主导执法写 100（窄读即 G1 复活）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active),
        "门-3", "混装窗（旧 daemon 编排开 ∧ ≥80 → wire active）→ 静默（G1 防线——宽读钉死）")

    // 门-4（degraded 稳态裁决）：**不静默**——W4 写 max(target,80) =「域通道死亡
    // 最后防线」，与 D2 域镜像同值零对抗。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .degraded),
        "门-4", "degraded 稳态 → 不静默（写 max(target,80) 最后防线——与 D2 同值零对抗）")

    // 门-5（F2 探针互搏补格）：degraded ∧ healProbeActive → **静默**（override
    // 先于 degraded 保留判定——不静默则 MCL 80 压制 75 观察窗，证据窗 [74,75]
    // 结构性不可达 → 每小时探针必败 degraded 永不自愈）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: true, sub80State: .degraded),
        "门-5", "degraded ∧ 自愈探针观察窗 → 静默（F2——探针窗让位，证据窗可达）")

    // 门-6（26 红线）：sub80State nil 恒不静默（26/通道关既有行为——恒走原对账）；
    // .off 同不静默（关断清理后 off 语义既有）。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: nil),
        "门-6", "sub80State nil（26/无能力机）→ 不静默（26 红线——nil 恒走原对账）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .off),
        "门-6", "sub80State .off（关断清理后）→ 不静默（off 既有行为不变）")
}
