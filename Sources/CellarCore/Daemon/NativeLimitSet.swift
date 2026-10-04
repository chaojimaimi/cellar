import Foundation

// MARK: - 0.21.0 §1 set 路径决策核心（方案 §1.1/§1.3/§1.5；CellarCoreCheck 场景域钉死）
//
// 架构总纲（方案 §0）：27 上限充执行转向 App 侧免 root set 路径（80-100 区间）——
// daemon 保留 <80 topoff、放电等 root 职责；快捷指令从「必需前置」降为 fallback。
// 决策纯函数进 CellarCore（照 NativeOrchestration/Topoff 先例），App 侧执行体
// （MCLClient set 面 + LimitExecutor 抽象）与 daemon 分支（fullOnce 27 复活）只消费。

/// set 路径常量与决策纯函数（无状态无 IO——MCL I/O 在 App 侧 MCLClient）。
public enum NativeLimitSet {
    /// MCL set 原生下限（S3 定谳：setMCLLimit <80 被 PowerUISmartChargingErrorDomain
    /// Code=4 拒绝——更低走实验性通道，不在本路线）。
    public static let minimumSetLimit = 80
    /// set 上限（充满语义）。
    public static let maximumSetLimit = 100
    /// §1.3 fullOnce 27 临时放开目标（pendingTarget=100 可 set——policy <80 分支同样合法）。
    public static let fullOnceTarget = 100
    /// §1.1 fallback 触发阈值（R1-P2-3 钉死：set 连续 **2 次**实例级失败 → 会话驻留
    /// 快捷指令 fallback；下次启动重试 set——会话 sticky 语义，S3 实证类缺席为平台终态）。
    public static let fallbackFailureThreshold = 2

    /// 恢复臂 XPC 命令字面量（§1.3 恢复：daemon 置 pending(policy.upperLimit)）。
    /// 与既有命令命名同域（fullOnce / cancelAction / setOrchestration）。
    public static let restoreCommand = "restoreChargeLimit"

    /// set 执行目标映射（**0.22.4 模型 v2 退役版**——<80 → nil 不写）：
    /// target ≥80 → 原值直写；target <80 → **nil**（无 set 值——执行体跳过）。
    /// 历史：0.21.0「钳 80」为三分支模型对齐前的有害形态（MCL 80 主导顶掉域
    /// 75——G1/G2 实证，0.21.3 废除）；0.21.3「<80 → set 100」基于旧期望表
    /// 「域执法需 MCL=100」——已被 13:32 事故证伪（恢复写 80 成功 2s 后被自家
    /// 补偿臂打回 100）：新模型 **域写值直接流入 MCL 执法（含 <80）**，MCL=100
    /// = 无限制且诱发 agent 再关（M2/M4）。v2 口径：<80 时 MCL 无需任何 set——
    /// 恢复臂 max(target,80) 开启垫脚石后域即时接管（M1），任何 100 写入都只会
    /// 造 M2 环境拖慢收敛。生产调用点仅两处同链（全库 grep 定谳）：W4/W1 共用
    /// 执行体 MCLSetLimitExecutor（expected ∈ {80,100,≥80} 恒非 nil——nil 分支
    /// 防御性处理）与 W1 consumeOrchestrationPending（nil → skip 且不回报）。
    public static func setTarget(for pendingTarget: Int) -> Int? {
        pendingTarget >= minimumSetLimit ? pendingTarget : nil
    }

    /// 0.22.4 补偿臂静默门（W4 关断残留对账 30s 循环 + reconcileShutdownResidualNow
    /// 即时变体共用；方案 §3.1 v2 终版门式，CellarCoreCheck 场景域钉死——App 只消费）。
    ///
    /// 根因模型 v2（13:32 事故定谳）：域写值直接流入 MCL 执法（agent 跟随域值，
    /// 含 <80 区间），MCL=100 = 无限制且诱发 agent 自主再关（M2/M4）——补偿臂在
    /// 域承载态写 100 与域 75 互搏（期望表旧模型「域执法需 MCL=100」证伪）。
    ///
    /// 静默判据：mode active ∧ 两窗不在位 ∧（自愈探针观察窗让位（F2——探针只在
    /// degraded 态跑，本项先于 degraded 保留判定；不静默则 MCL 80 压制 75 观察
    /// 窗 → 证据窗结构性不可达 → degraded 永不自愈）∨ 域承载（sub80State ==
    /// .active ∧（upperLimit < 80 ∨ 编排关）——域自足区间，写手让位））。
    ///
    /// **显式排除（红队 F1/常规 P0 裁决记录，随代码落注）**：
    /// - 编排开 ∧ ≥80：sub80State 虽 .active 但 NOT owned——W4 是本区间周期对账
    ///   防线唯一执行者，静默即失防（门第一支 <80 命中不外溢）；
    /// - degraded 稳态（无探针）：W4 写 80 =「域通道死亡最后防线」，与 D2 域镜像
    ///   80 同值零对抗——保留写；
    /// - sub80State == .off / nil：26/通道关——既有行为不变（26 红线：nil 恒不
    ///   静默，恒走原对账）。
    /// - mode 关 / 两窗在位：期望恒 100（放开语义），无互搏面——不静默（W4-now
    ///   即时变体语义保留）。
    public static func compensationSilenced(
        modeActive: Bool,
        fullOnceWindow: Bool,
        chargingDisabledWindow: Bool,
        healProbeActive: Bool,
        sub80State: Sub80State?,
        upperLimit: Int,
        orchestrationEnabled: Bool
    ) -> Bool {
        guard modeActive else { return false }
        // 两窗在位 = 显式放开意图（期望恒 100 与域随写 100 同值——无互搏面）。
        guard !fullOnceWindow, !chargingDisabledWindow else { return false }
        // F2 override：探针观察窗让位（先于 degraded 保留判定——探针只在 degraded
        // 态，恒真时静默让 75 观察窗可达）。
        if healProbeActive { return true }
        // 域承载支：仅 .active 态参与（degraded 稳态防线保留 / off / nil 排除——
        // 裁决记录见头注）。
        guard sub80State == .active else { return false }
        return upperLimit < minimumSetLimit || !orchestrationEnabled
    }

    /// §1.1 fallback 触发判定（R1-P2-3）：实例级失败连击达阈值 → 会话驻留快捷指令。
    public static func shouldDwellShortcutFallback(failureStreak: Int) -> Bool {
        failureStreak >= fallbackFailureThreshold
    }

    /// 执行体路由（§1.1：set 优先——会话初值 embeddedSet；驻留后 shortcut，
    /// 本会话不回切，下次启动重试 set）。
    public enum ExecutorFlavor: Equatable, Sendable {
        case embeddedSet
        case shortcut
    }

    public static func executorFlavor(dwellingShortcut: Bool) -> ExecutorFlavor {
        dwellingShortcut ? .shortcut : .embeddedSet
    }

    /// §1.1 失败簿记推进（纯函数——App 消费面按此更新连击/驻留态）：
    /// - `nil`（成功）→ 连击清零（consecutive 语义）、不驻留；
    /// - `.nativeFloorMinimum`（Code=4 结构化拒绝）→ **中性**：值级拒绝与通道健康
    ///   无关——不计连击、不清连击（重试同值仍拒绝，UI 如实提示，§1.1 失败链）；
    /// - `.channelUnavailable` / `.callFailed`（实例级）→ 连击 +1，达阈值 → 驻留。
    public static func advancedFailureBookkeeping(
        streak: Int, outcome: MCLSetFailure?
    ) -> (streak: Int, dwell: Bool) {
        switch outcome {
        case .none:
            return (0, false)
        case .nativeFloorMinimum:
            return (streak, shouldDwellShortcutFallback(failureStreak: streak))
        case .channelUnavailable, .callFailed:
            let next = streak + 1
            return (next, shouldDwellShortcutFallback(failureStreak: next))
        }
    }

    /// §1.3 恢复臂按钮判定源（R2-P2-4 钉死，**读回驱动非本地态**——重启与滑杆
    /// 变更自然收敛）：`MCL 读回 100 ∧ policy < 100`。调用方（App 面板）另叠加
    /// 27 终态 ∧ mode active ∧ 编排开关开（开关关 = 恢复臂拒收，R3-P3-1——按钮
    /// 隐藏 + 引导重开）。
    public static func fullOnceRestoreAvailable(mclReadback: Int?, policyUpperLimit: Int) -> Bool {
        mclReadback == fullOnceTarget && policyUpperLimit < fullOnceTarget
    }

    /// MCL 对账期望值（0.21.3 §2.1 **八行表统一重定版**——三分支模型对齐，G1
    /// 根治；App 态驱动对账与 doctor 检查 20 同源消费；优先级自上而下）：
    ///
    /// 1. fullOnce 窗            → 100（窗覆盖——优先级最高）
    /// 2. chargingDisabled 日程窗 → 100（完全放开——与断言链 desired=100 同源）
    /// 3. mode 关（disable）     → 100（API 写全开语义；分支 2 路径保机制使能）
    /// 4. 编排开 ∧ target ≥80    → target（MCL 主导，App set 执法——周期对账防线）
    /// 5. 编排开 ∧ target <80 ∧ 非 degraded → 100（sub80 topoff 承载，MCL 必须
    ///   100 让域管）
    /// 6. 编排开 ∧ target <80 ∧ degraded → 80（对齐编排钳 desired=80——
    ///   Topoff.swift 降级稳态分支；漏行后果 = 对账写 100 与编排钳互搏 30s 乒乓）
    /// 7. 编排关 ∧ degraded      → 80（域通道死亡时的最后防线——MCL 80 总比无
    ///   执法好；三分支分支 1 主导此时是期望行为）
    /// 8. 编排关 ∧ 非 degraded（含 ≥80）→ 100（**0.21.3 §1.1 域承载全区间**——
    ///   MCL 必须 100 让域管；旧「<80→80 兜底」行为 G1 实证有害〔MCL 80 主导
    ///   顶掉域 75〕，废除）
    ///
    /// App 对账补偿执行统一走 API set（保机制使能——三分支分支 2 路径）。
    /// nil 不再出现于 27 正常态（八行恒有期望值）；两窗输入由 wire
    /// `fullOnceWindowActive`/`chargingDisabledWindowActive` 供给（27 恒填；
    /// 26 缺省 false = 既有语义）。缺省参数保源兼容（既有构造点零 diff）。
    public static func shutdownExpectation(
        modeActive: Bool,
        orchestrationEnabled: Bool,
        upperLimit: Int,
        degraded: Bool = false,
        fullOnceWindowActive: Bool = false,
        chargingDisabledWindowActive: Bool = false
    ) -> Int? {
        if fullOnceWindowActive { return maximumSetLimit }            // 行 1
        if chargingDisabledWindowActive { return maximumSetLimit }    // 行 2
        if !modeActive { return maximumSetLimit }                     // 行 3
        if orchestrationEnabled {
            if upperLimit >= minimumSetLimit { return upperLimit }    // 行 4
            return degraded ? minimumSetLimit : maximumSetLimit       // 行 6 / 行 5
        }
        return degraded ? minimumSetLimit : maximumSetLimit           // 行 7 / 行 8
    }
}

/// §1.1 set 失败链的结构化失败分类（App MCLClient.setLimit 产出；文案照 daemon
/// 拒绝串先例硬编码 zh——daemonError 原文通道上屏，不静默）。
public enum MCLSetFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// PowerUISmartChargingErrorDomain Code=4（80 下限）——结构化拒绝（S3 定谳）。
    case nativeFloorMinimum
    /// 类缺席（sticky 平台终态——计实例级失败连击）。
    case channelUnavailable
    /// 其他调用失败（实例级——实例丢弃重建自愈；计实例级失败连击）。
    case callFailed(domain: String, code: Int, message: String)

    /// NSError 分类入口（domain/code → 结构化 case；无 NSError 的 BOOL=false 同样
    /// 折叠为 callFailed——不猜测语义）。
    public static func classify(domain: String, code: Int, message: String) -> MCLSetFailure {
        if domain == PowerUISmartChargingErrorDomain && code == floorRejectionCode {
            return .nativeFloorMinimum
        }
        return .callFailed(domain: domain, code: code, message: message)
    }

    /// PowerUI 智能充电动画错误域字面量（S3 spike 实测；字符串常量单一真相）。
    public static let PowerUISmartChargingErrorDomain = "PowerUISmartChargingErrorDomain"
    /// 80 下限拒绝 Code（S3 定谳）。
    public static let floorRejectionCode = 4

    public var description: String {
        switch self {
        case .nativeFloorMinimum:
            return "系统原生限充最低 80——更低走实验性通道"
        case .channelUnavailable:
            return "原生限充 set 通道不可用（PowerUISmartChargeClient 类缺席）"
        case .callFailed(let domain, let code, let message):
            return "原生限充 set 调用失败（\(domain) Code=\(code)）\(message.isEmpty ? "" : "：\(message)")"
        }
    }
}
