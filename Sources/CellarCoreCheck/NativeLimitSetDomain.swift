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
    try runExecutorFallbackScenarios()
    try runFullOnceRestoreJudgmentScenarios()
    try runShutdownExpectationScenarios()
    try runConvergenceRouteFullOnceWindowScenarios()
    try runRestoreWireScenarios()
    try runDoctorNativeLimitScenarios()
}

// MARK: - ① set 分流（≥80 set / <80 钳 80）

private func runSetRouteScenarios() throws {
    // set-1：执行目标钳制（§1.3 <80 恢复分支 = App set 80；编排链 ≥80 目标恒等）。
    check(NativeLimitSet.setTarget(for: 85) == 85, "set-1", "85 → 85（≥80 直通——S3 实证目标）")
    check(NativeLimitSet.setTarget(for: 100) == 100, "set-1", "100 → 100（充满语义）")
    check(NativeLimitSet.setTarget(for: 80) == 80, "set-1", "80 → 80（set 下限边界恒等）")
    check(NativeLimitSet.setTarget(for: 75) == 80, "set-1", "75 → 80（<80 恢复分支——set 下限解除原生压制，域 75 由 topoff 承载）")
    check(NativeLimitSet.setTarget(for: 60) == 80, "set-1", "60（地板值）→ 80")
    // 常量钉死。
    check(NativeLimitSet.minimumSetLimit == 80 && NativeLimitSet.maximumSetLimit == 100,
          "set-1", "set 域 80-100（S3 定谳——<80 被 Code=4 拒绝）")
    check(NativeLimitSet.fullOnceTarget == 100, "set-1", "fullOnce 临时放开目标 = 100（§1.3）")
    check(NativeLimitSet.fallbackFailureThreshold == 2, "set-1", "fallback 触发阈值 = 2（R1-P2-3 钉死）")
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
    // 文案钉死（§1.1 失败链——UI 如实提示，不静默）。
    check(String(describing: MCLSetFailure.nativeFloorMinimum)
              == "系统原生限充最低 80——更低走实验性通道",
          "set-2", "Code=4 结构化拒绝文案钉死（更低走实验性通道）")
    check(String(describing: MCLSetFailure.channelUnavailable)
              .contains("类缺席"),
          "set-2", "类缺席失败文案含「类缺席」（sticky 平台终态）")
    check(String(describing: MCLSetFailure.callFailed(domain: "D", code: 9, message: "boom"))
              == "原生限充 set 调用失败（D Code=9）：boom",
          "set-2", "实例级失败文案含域/码/详情（原文通道上屏）")
}

// MARK: - ③ 执行器抽象（set 优先 / fallback 触发 / 驻留）

private func runExecutorFallbackScenarios() throws {
    // set-3：味道路由（set 优先——会话初值；驻留后 shortcut，本会话不回切）。
    check(NativeLimitSet.executorFlavor(dwellingShortcut: false) == .embeddedSet,
          "set-3", "未驻留 → embeddedSet（0.21.0 主通道——set 优先）")
    check(NativeLimitSet.executorFlavor(dwellingShortcut: true) == .shortcut,
          "set-3", "驻留 → shortcut（0.20 通道 fallback——会话 sticky，下次启动重试 set）")
    // set-4：fallback 触发阈值（R1-P2-3：连续 2 次实例级失败）。
    check(!NativeLimitSet.shouldDwellShortcutFallback(failureStreak: 0), "set-4", "连击 0 → 不驻留")
    check(!NativeLimitSet.shouldDwellShortcutFallback(failureStreak: 1), "set-4", "连击 1 → 不驻留（阈值 2 未达）")
    check(NativeLimitSet.shouldDwellShortcutFallback(failureStreak: 2), "set-4", "连击 2 → 驻留（阈值钉死）")
    check(NativeLimitSet.shouldDwellShortcutFallback(failureStreak: 3), "set-4", "连击 3 → 驻留（驻留后继续累计仍真——本会话不回切）")
    // set-5：失败簿记推进（consecutive 语义 + Code=4 中性 + 成功清零）。
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 0, outcome: nil)
              == (streak: 0, dwell: false),
          "set-5", "成功 → 连击清零（consecutive 语义）")
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 1, outcome: nil)
              == (streak: 0, dwell: false),
          "set-5", "失败 1 次后成功 → 清零（连续计数中断）")
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 1, outcome: .channelUnavailable)
              == (streak: 2, dwell: true),
          "set-5", "实例级失败连击 1→2 → 驻留（类缺席计实例级）")
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 1, outcome: .callFailed(domain: "D", code: 9, message: "x"))
              == (streak: 2, dwell: true),
          "set-5", "实例级失败连击 1→2 → 驻留（callFailed 计实例级）")
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 1, outcome: .nativeFloorMinimum)
              == (streak: 1, dwell: false),
          "set-5", "Code=4 结构化拒绝 → 中性（不计连击不清连击——值级拒绝与通道健康无关）")
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 2, outcome: .nativeFloorMinimum)
              == (streak: 2, dwell: true),
          "set-5", "已驻留后 Code=4 → 态不变（中性，不解除驻留）")
    check(NativeLimitSet.advancedFailureBookkeeping(streak: 0, outcome: .channelUnavailable)
              == (streak: 1, dwell: false),
          "set-5", "首拍实例级失败 → 连击 1 不驻留（下拍重试 set——S3 实证实例失败可重建）")
}

// MARK: - ④ 恢复臂判定源（R2-P2-4 读回驱动）

private func runFullOnceRestoreJudgmentScenarios() throws {
    // set-6：按钮二态判定源 = MCL 读回 100 ∧ policy < 100（读回驱动非本地态）。
    check(NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 100, policyUpperLimit: 85),
          "set-6", "读回 100 ∧ policy 85 → 恢复臂可见（临时放开在轨）")
    check(NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 100, policyUpperLimit: 75),
          "set-6", "读回 100 ∧ policy 75（<80 分支）→ 恢复臂可见（恢复 = pending(75) → App set 80）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 100, policyUpperLimit: 100),
          "set-6", "policy 100 → 不可见（无限充语义——无恢复可言）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 85, policyUpperLimit: 85),
          "set-6", "读回 85 == policy 85 → 不可见（正常执行态）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: 85, policyUpperLimit: 75),
          "set-6", "读回 85 ≠ 100 → 不可见（读回驱动——值不符）")
    check(!NativeLimitSet.fullOnceRestoreAvailable(mclReadback: nil, policyUpperLimit: 85),
          "set-6", "读回不可用 → 不可见（nil 不猜测语义）")
}

// MARK: - ⑤ 关断残留补偿期望值（R3-P1 拆分规则）

private func runShutdownExpectationScenarios() throws {
    // set-7：disable（mode 关，含面板/CLI/SIGHUP/restoreAndExit）→ **恒 100**。
    check(NativeLimitSet.shutdownExpectation(modeActive: false, orchestrationEnabled: true, upperLimit: 75) == 100,
          "set-7", "mode 关 ∧ 编排开 ∧ target 75 → 100（全开语义与域 100 对齐——set 80 会重造「UI 已停用实际限 80」残留）")
    check(NativeLimitSet.shutdownExpectation(modeActive: false, orchestrationEnabled: false, upperLimit: 85) == 100,
          "set-7", "mode 关 ∧ 编排关 ∧ target 85 → 100（恒 100——R3-P1 第一行不分流）")
    check(NativeLimitSet.shutdownExpectation(modeActive: false, orchestrationEnabled: false, upperLimit: 75) == 100,
          "set-7", "mode 关 ∧ 编排关 ∧ target 75 → 100（第一行优先——不落第二行 80）")
    // set-8：编排开关关（mode 仍 active）→ **0.21.1 §2.2 重定版**：target ≥80 → nil
    //（编排关不断域——域随写 target 覆盖全区间，无残留可补；旧 ≥80→100 为域 100
    // 顶掉用户系统 MCL + 乒乓循环的第①层根因，废除）/ target <80 → 80（原生限充
    // 兜底保留——域保持 75，topoff 不受编排开关门；域通道故障时 MCL 80 兜底）。
    check(NativeLimitSet.shutdownExpectation(modeActive: true, orchestrationEnabled: false, upperLimit: 85) == nil,
          "set-8", "编排关 ∧ target 85（≥80）→ nil（0.21.1 §2.2——编排关不断域，域随写 85，App 不再补偿 set 100）")
    check(NativeLimitSet.shutdownExpectation(modeActive: true, orchestrationEnabled: false, upperLimit: 80) == nil,
          "set-8", "编排关 ∧ target 80（边界）→ nil（≥80 判据——乒乓根因①废除）")
    check(NativeLimitSet.shutdownExpectation(modeActive: true, orchestrationEnabled: false, upperLimit: 75) == 80,
          "set-8", "编排关 ∧ target 75（<80）→ 80（原生限充兜底保留——NativeLimitSet.swift 原理由不变）")
    check(NativeLimitSet.shutdownExpectation(modeActive: true, orchestrationEnabled: false, upperLimit: 60) == 80,
          "set-8", "编排关 ∧ target 60（地板）→ 80")
    // set-9：正常执行态（编排开 ∧ mode active）→ nil（无态驱动补偿——编排链 + 读回
    // 校验既有机制执法；fullOnce 临时放开窗同属本态，补偿不对抗）。
    check(NativeLimitSet.shutdownExpectation(modeActive: true, orchestrationEnabled: true, upperLimit: 85) == nil,
          "set-9", "编排开 ∧ target 85 → nil（正常执行态）")
    check(NativeLimitSet.shutdownExpectation(modeActive: true, orchestrationEnabled: true, upperLimit: 75) == nil,
          "set-9", "编排开 ∧ target 75（topoff 承载）→ nil（<80 由 topoff 域执法——App 不写）")
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
        orchestrationProbe: OrchestrationDoctorProbe? = nil,
        orchestrationAttempted: Bool = false
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
                timestamp: Date()),
            daemonProbeAttempted: true,
            orchestrationProbe: orchestrationProbe,
            orchestrationProbeAttempted: orchestrationAttempted,
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

    // 医生-16（检查 17 set 分支）：27 ∧ MCL 可读 → 「执行通道：App 内嵌（免快捷指令）」
    // （先行于 shortcuts 三分支——快捷指令指引降级）。
    do {
        let embedded = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil),
            mclAttempted: true,
            orchestrationProbe: OrchestrationDoctorProbe(
                listSucceeded: true, shortcutCount: 2, defaultShortcutPresent: false, failureDetail: nil),
            orchestrationAttempted: true
        ))
        check(embedded?.status == .pass && embedded?.detail.contains("App 内嵌（免快捷指令）") == true
                  && embedded?.detail.contains("读回 85%") == true,
              "医生-16", "27 ∧ MCL 可读 → PASS 内嵌执行通道文案（快捷指令指引降级——即使动作未建）")
        // 26 同输入 → 不进 set 分支（原 shortcuts 三分支——零回归）。
        let legacy = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil),
            mclAttempted: true,
            osMajorVersion: 26,
            orchestrationProbe: OrchestrationDoctorProbe(
                listSucceeded: true, shortcutCount: 2, defaultShortcutPresent: false, failureDetail: nil),
            orchestrationAttempted: true
        ))
        check(legacy?.status == .info && legacy?.detail.contains("未找到") == true,
              "医生-16", "26 ∧ MCL 可读 → 原指引分支（set 分支 27 门控——零回归）")
        // 27 ∧ MCL 类缺席 → 原指引分支（set 不可用态回退）。
        let classMissing = check17(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: false, limit: nil,
                                     failureDetail: "PowerUISmartChargeClient 类缺席"),
            mclAttempted: true,
            orchestrationProbe: OrchestrationDoctorProbe(
                listSucceeded: true, shortcutCount: 1, defaultShortcutPresent: true, failureDetail: nil),
            orchestrationAttempted: true
        ))
        check(classMissing?.status == .pass && classMissing?.detail.contains("已找到") == true,
              "医生-16", "27 ∧ MCL 类缺席 → 原三分支（已找到动作 PASS——set 不可用回退快捷指令）")
    }

    // 医生-17（检查 19 临时放开残留）：读回 100 ∧ policy < 100 → INFO + 恢复指引。
    do {
        let residual = check19(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85
        ))
        check(residual?.status == .info && residual?.detail.contains("临时放开未恢复") == true
                  && residual?.detail.contains("恢复限充") == true,
              "医生-17", "读回 100 ∧ policy 85 → INFO 残留 + 恢复指引（R2-P2-4 同式判定）")
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

    // 医生-18（检查 20 关断残留）：0.21.1 重定版期望派生 × 读回失配矩阵。
    do {
        // disable（mode 关）→ 期望 100；读回 85 ≠ 100 → INFO。
        let disabledMismatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 85, failureDetail: nil), mclAttempted: true,
            daemonMode: "disabled", daemonUpperLimit: 85, daemonOrchestrationEnabled: true
        ))
        check(disabledMismatch?.status == .info && disabledMismatch?.detail.contains("期望值 100%") == true
                  && disabledMismatch?.detail.contains("读回 85%") == true,
              "医生-18", "mode 关 + 读回 85 → INFO「读回 85% 与关断期望值 100% 不符」（mode 关恒 100——真停用=放开）")
        // disable 一致 → PASS。
        let disabledMatch = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonMode: "disabled", daemonUpperLimit: 85, daemonOrchestrationEnabled: true
        ))
        check(disabledMatch?.status == .pass && disabledMatch?.detail.contains("关断对账一致") == true,
              "医生-18", "mode 关 + 读回 100 → PASS 对账一致")
        // 编排关 ∧ target 75 → 期望 80；读回 100 ≠ 80 → INFO（<80 兜底形态）。
        let orchOffSub80 = check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 75, daemonOrchestrationEnabled: false
        ))
        check(orchOffSub80?.status == .info && orchOffSub80?.detail.contains("期望值 80%") == true,
              "医生-18", "编排关 ∧ target 75 + 读回 100 → INFO 期望 80（<80 兜底行保留——原生限充兜底）")
        // 编排关 ∧ target ≥80 → 期望 nil → 不渲染（0.21.1 §2.2——编排关不断域，
        // 域随写 target 覆盖全区间，无态驱动补偿；旧「期望 100 + 读回 PASS」形态废除）。
        check(check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: false)) == nil,
              "医生-18", "编排关 ∧ target 85 → 检查 20 不渲染（期望 nil——0.21.1 域语义一致化，不再引导 set 100）")
        // 正常执行态（编排开）→ 期望 nil → 不渲染（fullOnce 窗同态——补偿不对抗）。
        check(check20(doctorInputs(
            mclProbe: MCLDoctorProbe(readable: true, limit: 100, failureDetail: nil), mclAttempted: true,
            daemonUpperLimit: 85, daemonOrchestrationEnabled: true)) == nil,
              "医生-18", "编排开 ∧ mode active → 检查 20 不渲染（期望 nil——无态驱动补偿）")
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
