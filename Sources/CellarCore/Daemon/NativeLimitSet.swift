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

    /// set 执行目标钳制（§1.3 <80 恢复分支钉死）：target ≥80 → 原值直写；
    /// target <80 → set 80（set 下限，解除原生限充压制——域 target 由 topoff 通道
    /// 承载，「MCL 80 与域 75 并存无害」为待验证假设 R2-P2-1，§7.4 真机走查判定）。
    /// 验收口径「≥80 set / <80 topoff」：编排链的 <80 目标本就由 daemon 路由静默
    /// （Topoff.convergenceRoute topoffOwned → desired=nil），本钳制只服务恢复臂
    /// 与防御面——执行体永不向原生 MCL 写 <80 值。
    public static func setTarget(for pendingTarget: Int) -> Int {
        max(pendingTarget, minimumSetLimit)
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

    /// §1.5 关断残留补偿期望值（R3-P1 拆分规则——两路径 daemon 行为不同，规则不可合并）：
    /// - mode 关（面板停用 / CLI / SIGHUP / restoreAndExit）→ **恒 100**（全开语义
    ///   与域 100 对齐；set 80 会重造「UI 已停用实际限 80」残留）；
    /// - mode active ∧ 编排开关关 → target ≥80 → 100（域清 100 对齐）/ target <80
    ///   → **80**（原生限充兜底保留——域保持 75，topoff 不受编排开关门）；
    /// - mode active ∧ 编排开关开 → nil（正常执行态——编排链 + 读回校验既有机制
    ///   执法，无态驱动补偿；fullOnce 临时放开窗同属本态）。
    /// nil = 无补偿期望（App 侧不做态驱动对账）。
    public static func shutdownExpectation(
        modeActive: Bool, orchestrationEnabled: Bool, upperLimit: Int
    ) -> Int? {
        if !modeActive { return maximumSetLimit }
        guard !orchestrationEnabled else { return nil }
        return upperLimit >= minimumSetLimit ? maximumSetLimit : minimumSetLimit
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
