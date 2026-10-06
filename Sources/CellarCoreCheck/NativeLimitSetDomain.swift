// CellarCoreCheck —— 0.21.0 §1 set 路径场景域（方案 §1.1/§1.2/§1.3/§1.5）
//
// 覆盖清单（工单门禁钉死项）：
// ① set 分流与拒绝链（≥80 set / <80 钳 80 / Code=4 结构化拒绝 + 文案钉死 / 失败
//    分类三态 / UInt8 越界防御面）
// ② fullOnce 27（编排开关关拒收 / 开关开放行 / <80 policy 分支 pending(100) 可 set
//    / 26 回归由 OrchestrationDomain 编排-8..10 背书）
// ③ 执行器抽象（set 优先 / fallback 触发阈值 2 / 会话驻留 / 成功清零 / Code=4 中性
//    / 味道路由）
// ④ 恢复臂判定源（R2-P2-4 读回驱动：读回 100 ∧ policy < 100 矩阵）
// ⑤ 关断残留检测（0.21.1 §2.2 重定版期望派生：disable 恒 100 / 编排关 ≥80→nil
//    <80→80 / 正常执行态 nil——态驱动读回驱动分支全矩阵）
// ⑥ convergenceRoute fullOnce 窗（窗内 target/desired 强制 100、topoffOwned 失效、
//    窗清恢复既有链、缺省参数零 diff——26 回归锚）
// ⑦ 恢复臂 XPC 命令字面量 + makeMessage/validateRequest 通道
// ⑧ doctor 检查 17 set 可用分支 + 检查 19 临时放开残留 + 检查 20 关断残留
//    （分支矩阵 + 缺省零渲染 + 26 门控）
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
    try runFullOnceRestoreJudgmentScenarios()
    try runShutdownExpectationScenarios()
    try runConvergenceRouteFullOnceWindowScenarios()
    try runRestoreWireScenarios()
    try runDoctorNativeLimitScenarios()
    try runCompensationSilencedScenarios()
    try runDegradedWriteValueScenarios()
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
    check(NativeLimitSet.fullOnceTarget == 100, "set-1", "fullOnce 临时放开目标 = 100（§1.3；0.23.0 §② fallback 阈值随快捷指令通道退役删除）")
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

// MARK: - ③ 恢复臂判定源（R2-P2-4 读回驱动；原执行器抽象 fallback 族随 0.23.0
// §② 快捷指令通道退役删除——set 为唯一执行通道）

private func runFullOnceRestoreJudgmentScenarios() throws {
    // set-6：按钮二态判定源 = MCL 读回 100 ∧ policy < 100（读回驱动非本地态）。
    check(NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 100, policyUpperLimit: 85),
          "set-6", "读回 100 ∧ policy 85 → 恢复臂可见（临时放开在轨）")
    check(NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 100, policyUpperLimit: 75),
          "set-6", "读回 100 ∧ policy 75（<80 分支）→ 恢复臂可见（0.22.4 起 pending(75) 消费面 setTarget → nil 不写 MCL——恢复臂 max(75,80) 开启垫脚石后域直接执法）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 100, policyUpperLimit: 100),
          "set-6", "policy 100 → 不可见（无限充语义——无恢复可言）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 85, policyUpperLimit: 85),
          "set-6", "读回 85 == policy 85 → 不可见（正常执行态）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 85, policyUpperLimit: 75),
          "set-6", "读回 85 ≠ 100 → 不可见（读回驱动——值不符）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: nil, policyUpperLimit: 85),
          "set-6", "读回不可用 → 不可见（nil 不猜测语义）")
}

// MARK: - ⑤ MCL 对账期望值八行表（0.21.3 §2.1 统一重定版）

private func runShutdownExpectationScenarios() throws {
    // set-7（八行表行 1-3）：两窗与 mode 关恒 100（优先级自上而下；行 1/2 由
    // 新 wire 两窗字段供给——窗覆盖优先于一切）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: true, upperLimit: 85,
            fullOnceWindowActive: true) == 100,
          "set-7", "fullOnce 窗 ∧ 编排开 ∧ 85 → 100（行 1 窗覆盖——优先级最高）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 75,
            chargingDisabledWindowActive: true) == 100,
          "set-7", "chargingDisabled 日程窗 ∧ 编排关 ∧ 75 → 100（行 2 完全放开——与断言链 desired=100 同源）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: false, orchestrationEnabled: true, upperLimit: 75) == 100,
          "set-7", "mode 关 ∧ 编排开 ∧ target 75 → 100（行 3 全开语义与域 100 对齐——set 80 会重造「UI 已停用实际限 80」残留）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: false, orchestrationEnabled: false, upperLimit: 85) == 100,
          "set-7", "mode 关 ∧ 编排关 ∧ target 85 → 100（行 3 不分流）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: false, orchestrationEnabled: false, upperLimit: 75,
            degraded: true) == 100,
          "set-7", "mode 关 ∧ degraded → 仍 100（行 3 优先于 degraded 行——真停用即全开）")

    // set-8（八行表行 4-6，编排开三行）：≥80 → target（MCL 主导——对账即周期
    // 防线）；<80 非 degraded → 100（sub80 承载，MCL 让域管）；<80 ∧ degraded
    // → 80（0.23.0 §④ 行 6 翻新 = degradedWriteValue(for:)=max(target,80)，<80
    // 目标即 80——与 Topoff 降级稳态钳/四写点同源；漏行后果 = 对账写 100 与编排
    // 钳互搏 30s 乒乓）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: true, upperLimit: 85) == 85,
          "set-8", "编排开 ∧ target 85 → 85（行 4——MCL 主导，App set 执法的周期对账面）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: true, upperLimit: 80) == 80,
          "set-8", "编排开 ∧ target 80（边界）→ 80（行 4 判据 ≥80）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: true, upperLimit: 75) == 100,
          "set-8", "编排开 ∧ target 75（<80 非 degraded）→ 100（行 5——MCL 必须 100 让域管）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: true, upperLimit: 75,
            degraded: true) == 80,
          "set-8", "编排开 ∧ target 75 ∧ degraded → 80（行 6 对齐编排钳——R1-P0 漏行补全）")

    // set-9（八行表行 7-8，编排关两行——**0.23.0 §④ 行 7 翻新**）：degraded →
    // degradedWriteValue(for:)=max(target,80)（<80 目标 80 不变——域通道死亡最后
    // 防线；≥80 目标随域随写 target——降级写值统一后编排关 degraded 85 停 85，
    // 对账期望随行，防 D2×W4 新互搏）；非 degraded（含 <80 与 ≥80）→ 100
    //（**§1.1 域承载全区间**——MCL 必须 100 让域管；旧「<80→80 兜底」行为 G1
    // 实证有害〔MCL 80 主导顶掉域 75〕废除；旧「≥80→nil」同废——全区间恒有
    // 期望值，对账不缺位）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 75,
            degraded: true) == 80,
          "set-9", "编排关 ∧ target 75 ∧ degraded → 80（行 7——max(75,80)=80，域通道死亡最后防线）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 85,
            degraded: true) == 85,
          "set-9", "编排关 ∧ target 85 ∧ degraded → 85（**0.23.0 §④ 行 7 翻新**：max(85,80)=85——降级写值统一后域随写 target，期望随行不再钳 80）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 80,
            degraded: true) == 80,
          "set-9", "编排关 ∧ target 80（边界）∧ degraded → 80（行 7 边界恒等——max(80,80)）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 75) == 100,
          "set-9", "编排关 ∧ target 75（<80 非 degraded）→ 100（行 8——旧 80 兜底行为 G1 有害废除）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 85) == 100,
          "set-9", "编排关 ∧ target 85（≥80 非 degraded）→ 100（行 8——旧 nil 缺位废除：域承载全区间，MCL 必须 100）")
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: false, upperLimit: 100) == 100,
          "set-9", "编排关 ∧ target 100 → 100（行 8 全开恒等）")

    // set-9b：缺省参数保源兼容（degraded/两窗缺省 false——既有构造点零 diff；
    // 26 平台消费面 orchestrationTerminal/osMajorVersion 门内恒不达）。
    check(NativeLimitSet.shutdownExpectation(
            modeActive: true, orchestrationEnabled: true, upperLimit: 85) == 85,
          "set-9b", "缺省三参（degraded=false/两窗 false）→ 行 4 target（既有调用点行为确定）")

    // set-9c（**0.23.0 迁移钉面**——原 DischargeOscillationDomain :177/:267 的 W4
    // 断言随振荡场景域收缩迁入本域，行 6/7 翻新基底不灭）：
    check(NativeLimitSet.shutdownExpectation(
        modeActive: true, orchestrationEnabled: false, upperLimit: 80) == 100,
          "set-9c", "编排关 ∧ target 80 → 期望 100（迁移自振荡域 乒乓-2——0.21.3 §2.1 行 8，域承载全区间 MCL 100 让域管）")
    check(NativeLimitSet.shutdownExpectation(
        modeActive: false, orchestrationEnabled: true, upperLimit: 80) == 100,
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

    // 降-2（写点 ①convergenceRoute desired）：degraded 稳态断言目标随写值统一。
    let desired75 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false,
        degraded: true, healProbeActive: false
    )
    check(desired75.orchestrationDesired == 80, "降-2",
          "degraded ∧ target 75 ∧ 编排开 → 编排钳 80（写点①——<80 恒 80 与旧值恒等）")
    let desired85 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 85, sub80Capable: true, actionActive: false,
        degraded: true, healProbeActive: false
    )
    check(desired85.orchestrationDesired == 85, "降-2",
          "degraded ∧ target 85 ∧ 编排开 → 断言 85（**写点①翻新**——max(85,80)=85，编排钳不再拉 80）")
    let probe75 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false,
        degraded: true, healProbeActive: true
    )
    check(probe75.orchestrationDesired == nil, "降-2",
          "degraded ∧ 探针观察窗 ∧ target 75（承载态）→ 编排静默（既有互斥臂零变化；≥80 编排开不进 owned——域承载门不变）")

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

// MARK: - ⑥ convergenceRoute fullOnce 窗（§1.3 临时放开窗）

private func runConvergenceRouteFullOnceWindowScenarios() throws {
    // set-10：窗内汇聚目标/断言目标强制 100（等价「完全放开」——域随写 100 防 agent
    // 层对抗 App set；断言防 valueChange 回拉 policy 值致临时放开 30-60s 坍缩）。
    // topoffOwned 失效（convergenceTarget=100 不 <80）。
    let window75 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false, fullOnceWindow: true
    )
    check(window75.convergenceTarget == 100, "set-10", "窗内 target 75 → 汇聚目标 100（域随写 100）")
    check(window75.orchestrationDesired == 100, "set-10", "窗内断言目标 100（防 valueChange 回拉 75）")
    check(!window75.topoffOwned, "set-10", "窗内 topoffOwned 失效（100 不 <80——channelTick 不对抗）")
    let window85 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 85, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false, fullOnceWindow: true
    )
    check(window85.convergenceTarget == 100 && window85.orchestrationDesired == 100 && !window85.topoffOwned,
          "set-10", "窗内 target 85 → 同形态（policy ≥80 分支同样强制 100）")
    // set-11：窗与编排开关互斥次序——编排关 ∧ 窗在 → desired nil（开关门先行）；
    // 汇聚目标仍 100（域侧放开不受编排开关门——但窗会随 setOrchestration toggle 清除，
    // 本行为仅覆盖 toggle 与 tick 竞争窗）。
    let windowOff = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false, fullOnceWindow: true
    )
    check(windowOff.orchestrationDesired == nil, "set-11", "编排关 ∧ 窗在 → desired nil（开关门先于窗——App 消费面首门不可绕过）")
    check(windowOff.convergenceTarget == 100, "set-11", "编排关 ∧ 窗在 → 汇聚目标仍 100（域侧按窗放开）")
    // set-12：mode 门仍最优先——mode 关 ∧ 窗在 → 全 nil（窗位随 disable 清除，
    // 纯函数层面 mode 门兜底）。
    let windowDisabled = Topoff.convergenceRoute(
        modeActive: false, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false, fullOnceWindow: true
    )
    check(windowDisabled.convergenceTarget == nil && windowDisabled.orchestrationDesired == nil,
          "set-12", "mode 关 ∧ 窗在 → 双 nil（mode 门最优先——R3-P1 期望派生由调用侧承担）")
    // set-13：缺省参数零 diff（26 回归锚——既有构造不传 fullOnceWindow，真值表逐值不变）。
    let legacy75 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 75, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(legacy75.convergenceTarget == 75 && legacy75.orchestrationDesired == nil && legacy75.topoffOwned,
          "set-13", "缺省（窗 false）→ target 75 汇聚、desired nil（topoff 承载）——0.20.2 既有真值零回归")
    let legacy85 = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 85, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(legacy85.convergenceTarget == 85 && legacy85.orchestrationDesired == 85 && !legacy85.topoffOwned,
          "set-13", "缺省 target 85 → 0.19.20 链逐值不变（26 行为零变化回归锚）")
    // set-14：OrchestrationState 窗位形态（内存态不持久化——重启自然收敛）。
    check(OrchestrationState.empty.fullOnceWindowActive == false,
          "set-14", "空状态窗位 false（daemon 启动初值）")
    var windowState = OrchestrationState.empty
    windowState.fullOnceWindowActive = true
    check(windowState.fullOnceWindowActive && windowState != OrchestrationState.empty,
          "set-14", "窗位置位可见（Equatable 合成含新字段——27 复活臂置位）")
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
              "set-15", "恢复臂消息 → cmd 提取 + 无参形态（daemon 端恢复目标 = policy.upperLimit 快照）")
    }
    // set-16：恢复臂拒收错误形态（R3-P3-1——编排开关关，文案同 fullOnce 27 前置）。
    check(OneShotStartRejection.orchestrationSwitchOff.message
              == "系统限充执行已停用——请在通用页开启后使用",
          "set-16", "恢复臂拒收文案钉死（同 fullOnce 27 前置——R3-P3-1 同适用）")
}

// MARK: - ⑧ doctor 检查 17 set 分支 + 检查 19/20 残留检测

private func runDoctorNativeLimitScenarios() throws {
    let snapshot = try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date())
    func doctorInputs(
        mclProbe: MCLDoctorProbe? = nil,
        mclAttempted: Bool = false,
        osMajorVersion: Int = 27,
        daemonMode: String = "active",
        daemonUpperLimit: Int = 85,
        daemonOrchestrationEnabled: Bool = true,
        daemonCapabilities: [String]? = ["orchestration"],
        daemonSub80State: Sub80State? = nil,
        daemonSuppressed: Bool? = nil,
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
                orchestration: OrchestrationStatus(enabled: daemonOrchestrationEnabled),
                sub80State: daemonSub80State,
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
    func check19(_ inputs: DoctorInputs) -> DoctorCheck? {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "临时放开残留" }
    }
    func check20(_ inputs: DoctorInputs) -> DoctorCheck? {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "关断残留" }
    }

    // 医生-16（检查 17 收敛版——0.23.0 §② Shortcuts 备用退役）：判定门 = MCL 探测。
    do {
        let embedded = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil),
            mclAttempted: true
        ))
        check(embedded?.status == .pass
                  && embedded?.detail.contains("App 内嵌 set 通道（唯一）") == true
                  && embedded?.detail.contains("读回 85%") == true,
              "医生-16", "27 ∧ MCL 可读 → PASS「App 内嵌 set 通道（唯一）」（0.23.0 收敛——快捷指令备用语义退役）")
        // 26 同输入 → INFO 不适用形态（26 无 App 内嵌 set 面——daemon 直控）。
        let legacy = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil),
            mclAttempted: true,
            osMajorVersion: 26
        ))
        check(legacy?.status == .info && legacy?.detail.contains("仅 macOS 27+") == true,
              "医生-16", "26 ∧ MCL 可读 → INFO 不适用（收敛版——原 shortcuts 指引三分支退役）")
        // 27 ∧ MCL 类缺席 → INFO set 通道不可用（域通道承接 + 系统设置退路，
        // **无快捷指令指引**——红队 F2 语义真空修复）。
        let classMissing = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: false, limit: nil,
                                     failureDetail: "PowerUISmartChargeClient 类缺席"),
            mclAttempted: true
        ))
        check(classMissing?.status == .info
                  && classMissing?.detail.contains("App 内嵌 set 通道不可用") == true
                  && classMissing?.detail.contains("类缺席") == true
                  && classMissing?.detail.contains("系统设置") == true,
              "医生-16", "27 ∧ MCL 类缺席 → INFO set 不可用（域承接 + 系统设置退路——不再指引创建快捷指令）")
        // mclAttempted 缺省 → 零渲染（检查 15/16 同款条件渲染兼容约束）。
        check(check17(doctorInputs()) == nil,
              "医生-16", "mclProbeAttempted 缺省 → 检查 17 不渲染（收敛版判定门 = MCL 探测）")
    }

    // 医生-17（检查 19 临时放开残留）：读回 100 ∧ policy < 100 → INFO + 恢复指引；
    // **0.21.3 §2.1 fullOnce 窗在位（wire）→ 零渲染**（窗内读回 100 是显式放开
    // 意图非残留——旧「属预期形态」附注由显式窗态取代）。
    do {
        let residual = check19(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85
        ))
        check(residual?.status == .info && residual?.detail.contains("临时放开未恢复") == true
                  && residual?.detail.contains("恢复限充") == true,
              "医生-17", "读回 100 ∧ policy 85 → INFO 残留 + 恢复指引（R2-P2-4 同式判定）")
        check(check19(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonFullOnceWindow: true)) == nil,
              "医生-17", "fullOnce 窗在位（daemon wire）→ 检查 19 零渲染（显式放开意图非残留——0.21.3 §2.1）")
        // 正常态：读回 85 == policy 85 → 不渲染。
        check(check19(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85)) == nil,
              "医生-17", "读回 == policy → 检查 19 不渲染")
        // 编排开关关 → 不渲染（读回 100 属 §1.5 关断期望态——检查 20 承接，不双报）。
        check(check19(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: false)) == nil,
              "医生-17", "编排开关关 → 检查 19 不渲染（关断期望态归检查 20）")
        // 未探测缺省 → 零渲染（条件渲染兼容约束——既有 count 断言零回归）。
        check(check19(doctorInputs()) == nil, "医生-17", "mclProbeAttempted 缺省 → 检查 19 不渲染")
    }

    // 医生-18（检查 20 关断残留→MCL 对账）：0.21.3 §2.1 八行表期望派生 × 读回
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
            daemonMode: "disabled", daemonUpperLimit: 85, daemonOrchestrationEnabled: true
        ))
        check(disabledMismatch?.status == .info && disabledMismatch?.detail.contains("期望值 100%") == true
                  && disabledMismatch?.detail.contains("读回 85%") == true
                  && disabledMismatch?.detail.contains("切勿设 100%") == true,
              "医生-18", "mode 关 + 读回 85 → INFO + G1 修正指引（设具体值或交给 Cellar——不再引导「按需关闭/set 80」）")
        // disable 一致 → PASS。
        let disabledMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonMode: "disabled", daemonUpperLimit: 85, daemonOrchestrationEnabled: true
        ))
        check(disabledMatch?.status == .pass && disabledMatch?.detail.contains("MCL 对账一致") == true,
              "医生-18", "mode 关 + 读回 100 → PASS 对账一致")
        // 编排开 ∧ ≥80（行 4）：读回失配 → INFO（周期对账面可见化——旧 nil 缺位废除）。
        let executingMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 80, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: true
        ))
        check(executingMismatch?.status == .info
                  && executingMismatch?.detail.contains("期望值 85%") == true,
              "医生-18", "编排开 ∧ 85 + 读回 80 → INFO 期望 85（行 4——MCL 主导区间的对账可见化）")
        let executingMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: true
        ))
        check(executingMatch?.status == .pass,
              "医生-18", "编排开 ∧ 85 + 读回 85 → PASS（行 4 一致）")
        // 编排开 ∧ <80 非 degraded（行 5）：期望 100；读回 85 → INFO（MCL 让域管）。
        let sub80Mismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75, daemonOrchestrationEnabled: true
        ))
        check(sub80Mismatch?.status == .info && sub80Mismatch?.detail.contains("期望值 100%") == true,
              "医生-18", "编排开 ∧ 75 + 读回 85 → INFO 期望 100（行 5——MCL 100 让域管）")
        // 编排开 ∧ <80 ∧ degraded（行 6）：期望 80。
        let degradedClamp = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75, daemonOrchestrationEnabled: true,
            daemonSub80State: .degraded
        ))
        check(degradedClamp?.status == .info && degradedClamp?.detail.contains("期望值 80%") == true,
              "医生-18", "编排开 ∧ 75 ∧ degraded + 读回 100 → INFO 期望 80（行 6 对齐编排钳——R1-P0 漏行）")
        // 编排关 ∧ 非 degraded（行 8）：期望 100；读回 100 → PASS（**0.21.3 重定版**
        // ——旧「编排关 ∧ <80 → 期望 80」G1 有害引导与旧「≥80 → nil 不渲染」缺位
        // 一并废除：域承载全区间，MCL 必须 100）。
        let orchOffSub80Harmful = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 80, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75, daemonOrchestrationEnabled: false
        ))
        check(orchOffSub80Harmful?.status == .info
                  && orchOffSub80Harmful?.detail.contains("期望值 100%") == true,
              "医生-18", "编排关 ∧ 75 + 读回 80 → INFO 期望 100（行 8 重定版——旧「期望 80」G1 有害引导废除）")
        let orchOffMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: false
        ))
        check(orchOffMatch?.status == .pass,
              "医生-18", "编排关 ∧ 85 + 读回 100 → PASS（行 8 一致——旧 nil 不渲染缺位废除）")
        // 两窗行（行 1/2）：窗在位 → 期望 100；读回 85 → INFO（窗语义=完全放开）。
        let windowMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: true,
            daemonFullOnceWindow: true
        ))
        check(windowMismatch?.status == .info && windowMismatch?.detail.contains("期望值 100%") == true,
              "医生-18", "fullOnce 窗 + 读回 85 → INFO 期望 100（行 1 窗覆盖——wire 供给）")
        // code-review P3 补钉：静默态失配 → 附注文案（域承载态不对账属预期）——
        // 与补偿臂同一门函数单一真相；防文案漂移（编排关∧active∧75 失配形态）。
        let silencedMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 75, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75, daemonOrchestrationEnabled: false, daemonSub80State: .active
        ))
        check(silencedMismatch?.status == .info
              && silencedMismatch?.detail.contains("不对账属预期") == true
              && silencedMismatch?.detail.contains("自动对账补偿") == false,
              "医生-19", "静默态失配（编排关∧75）→ 附注「不对账属预期」且无补偿承诺（文案分支钉面）")
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

// MARK: - ⑨ 0.22.4 补偿臂静默门（方案 §3.1 v2 门式 + §5 清单 ≥10 case）

private func runCompensationSilencedScenarios() throws {
    // 门-1（mode/两窗优先级）：mode 非 active → 不静默（W4-now 即时变体放开语义
    // 保留——期望恒 100 与域 100 同值无互搏面）；两窗各 1 → 不静默（窗语义 =
    // 显式放开，期望 100 与域随写 100 同值）。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: false, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 75,
        orchestrationEnabled: true),
        "门-1", "mode 非 active → 不静默（放开语义保留）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: true, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 75,
        orchestrationEnabled: true),
        "门-1", "fullOnce 窗在位 → 不静默（窗覆盖期望 100——域同值无互搏）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: true,
        healProbeActive: false, sub80State: .active, upperLimit: 75,
        orchestrationEnabled: true),
        "门-1", "chargingDisabled 日程窗在位 → 不静默（完全放开同值）")

    // 门-2（G7 域承载全区间·编排关）：sub80 .active ∧ 编排关 → 静默，<80 与
    // ≥80 any target 同判（域自足——M5；编排关区间无 MCL 主导写入者）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 75,
        orchestrationEnabled: false),
        "门-2", "编排关 ∧ active ∧ target 75 → 静默（G7 域承载——13:32 元凶面）")
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 85,
        orchestrationEnabled: false),
        "门-2", "编排关 ∧ active ∧ target 85（≥80 全区间）→ 静默（域随写 85 直接执法）")

    // 门-3（编排开 ∧ <80）：静默（W1 <80 不写 + W4 静默 → D1 自足——矩阵行 3）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 75,
        orchestrationEnabled: true),
        "门-3", "编排开 ∧ active ∧ target 75 → 静默（域承载——<80 命中门第一支）")

    // 门-4（F1/P0 防御性钉面·编排开 ∧ ≥80）：**不静默**——sub80State 虽 .active
    // 但 NOT owned，W4 是本区间周期对账防线唯一执行者（矩阵行 4；门误杀即失防）。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 85,
        orchestrationEnabled: true),
        "门-4", "编排开 ∧ active ∧ target 85 → 不静默（F1 防线保留——本区间对账唯一执行者）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 80,
        orchestrationEnabled: true),
        "门-4", "编排开 ∧ active ∧ target 80（边界恒等）→ 不静默（≥80 判据下界钉面）")

    // 门-5（degraded 稳态裁决·两轨分歧收敛格）：编排开/关皆 **不静默**——W4 写
    // 80 =「域通道死亡最后防线」，与 D2 域镜像 80 同值零对抗（矩阵行 6/7）。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .degraded, upperLimit: 75,
        orchestrationEnabled: true),
        "门-5", "degraded 稳态 ∧ 编排开 → 不静默（写 80 最后防线——与 D2 同值零对抗）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .degraded, upperLimit: 75,
        orchestrationEnabled: false),
        "门-5", "degraded 稳态 ∧ 编排关 → 不静默（防线保留——行 7 同裁决）")

    // 门-6（F2 探针互搏补格）：degraded ∧ healProbeActive → **静默**（override
    // 先于 degraded 保留判定——不静默则 MCL 80 压制 75 观察窗，证据窗 [74,75]
    // 结构性不可达 → 每小时探针必败 degraded 永不自愈）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: true, sub80State: .degraded, upperLimit: 75,
        orchestrationEnabled: true),
        "门-6", "degraded ∧ 自愈探针观察窗 → 静默（F2——探针窗让位，证据窗可达）")

    // 门-7（79/80 边界双 case·门第一支 upperLimit < 80 判据）。
    check(NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 79,
        orchestrationEnabled: true),
        "门-7", "编排开 ∧ target 79（<80 边界下侧）→ 静默（域承载判据 <80）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .active, upperLimit: 80,
        orchestrationEnabled: true),
        "门-7", "编排开 ∧ target 80（边界上侧）→ 不静默（80 恒等属 MCL 主导区）")

    // 门-8（26 红线）：sub80State nil 恒不静默（26/通道关既有行为——恒走原对账）；
    // .off 同不静默（关断清理后 off 语义既有）。
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: nil, upperLimit: 75,
        orchestrationEnabled: true),
        "门-8", "sub80State nil（26/无能力机）→ 不静默（26 红线——nil 恒走原对账）")
    check(!NativeLimitSet.compensationSilenced(
        modeActive: true, fullOnceWindow: false, chargingDisabledWindow: false,
        healProbeActive: false, sub80State: .off, upperLimit: 75,
        orchestrationEnabled: true),
        "门-8", "sub80State .off（关断清理后）→ 不静默（off 既有行为不变）")
}
