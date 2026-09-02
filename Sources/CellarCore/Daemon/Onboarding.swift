import Foundation

// MARK: - 首启引导状态机（WP5 §2.1 定版）

/// 首启引导步骤（四步 + 终结态）。done = 无暂存步（引导完成）。
public enum OnboardingStep: CaseIterable, Hashable, Sendable {
    /// 1. 欢迎：Cellar 是什么/将做什么（安装 root 守护进程并接管限充/60 地板说明）。
    case welcome
    /// 2. 环境检查（冲突门）。
    case conflictCheck
    /// 3. daemon 安装授权。
    case install
    /// 4. 设定上限。
    case limit
    /// 完成（暂存步不存在）。
    case done
}

/// 冲突门结果（§2.1 P1-6 定版枚举）：UI 层把扫描结果 + 用户确认折叠成该枚举——
/// 纯转移函数不见布尔旁路。
public enum ConflictGateOutcome: Equatable, Sendable {
    /// 无命中（放行）。
    case clear
    /// 层 1 精确标识命中（红线 3「确认同类工具」语义：硬阻断）。
    case exactBlocked
    /// 层 2 词根命中（疑似误报：软警示，停留待用户确认）。
    case genericNeedsConfirm
    /// 用户已确认「仍要继续」（generic 之后放行）。
    case genericConfirmed
}

/// 引导纯转移函数（§2.1 定版规则逐条）：
/// - welcome → conflictCheck（gate/registration 无关）
/// - conflictCheck：exactBlocked / genericNeedsConfirm 停留（硬阻断待清除 /
///   软警示待确认）；clear / genericConfirmed → install
/// - install：registration == .enabled → limit；否则停留（UI 呈现 pending/迁移指引）
/// - limit → done
/// - done → nil（已终结；进一步转移为非法）
/// UI 只消费本函数，不自行计算转移。
public func onboardingNext(
    step: OnboardingStep,
    gate: ConflictGateOutcome,
    registration: RegistrationStatus
) -> OnboardingStep? {
    switch step {
    case .welcome:
        return .conflictCheck
    case .conflictCheck:
        switch gate {
        case .exactBlocked, .genericNeedsConfirm:
            return .conflictCheck
        case .clear, .genericConfirmed:
            return .install
        }
    case .install:
        return registration == .enabled ? .limit : .install
    case .limit:
        return .done
    case .done:
        return nil
    }
}

// MARK: - 通知分类（WP5 §2.3 定版）

/// 通知事件（三类；App 侧 NotificationService 投递，10 分钟同类型冷却；
/// WP2 动作终态三事件独立 identifier + 豁免冷却——一次性命中，不重复打扰）。
public enum CellarNotificationEvent: Hashable, Sendable {
    /// 已达充电上限（lastAction 转移 enforce:disableCharging 触发）。
    case limitReached(upperLimit: Int)
    /// 充电控制写入失败（enforce:error）。
    case writeFailed
    /// 检测到外部写者在写充电状态（enforce:verifyFailed——外部写者冲突显式化）。
    case conflictSuspected
    /// 一次性动作完成（lastAction 转移 fullOnce:done；kind = 动作类型字面量）。
    case actionCompleted(kind: String)
    /// 一次性动作超时（lastAction 转移 fullOnce:timeout）。
    case actionTimeout(kind: String)
    /// 一次性动作中断（lastAction 转移 fullOnce:cancel(crash-recovery)）。
    case actionInterrupted(kind: String)
}

/// 通知分类纯函数（§2.3 定版）。
///
/// ⚠️ **lastAction 字面量契约**：与 daemon 侧动作串是隐式契约——本函数与
/// Sources/cellar-daemon/DaemonCore.swift:512-533 的 actionName 赋值互为镜像；
/// daemon 侧任何动作串变更会被 CellarCoreCheck 的字面量钉死场景两侧同步暴露。
///
/// 规则：
/// - `previous == nil`（首样本）：`.limitReached` **抑制**——首样本的 lastAction
///   可能是数小时前的陈旧值，且 decide 无记忆（limitReached 只在转移 tick 出现），
///   抑制正确。**`.writeFailed`/`.conflictSuspected` 破例仍产出**：失败类每 tick
///   刷新（持续失败 = 此刻正在失败），首样本抑制 + 转移守卫的组合会造成
///   「App 重启后持续失败永久静默」，与红线 5（写失败必须显著告警）冲突。
/// - 转移触发（previous.lastAction != current.lastAction）：
///   `enforce:disableCharging` → `.limitReached(upperLimit:)`；
///   `enforce:error` → `.writeFailed`；`enforce:verifyFailed` → `.conflictSuspected`。
/// - `sleep:*`、`disable`、`enable`、`noop` → 不通知（睡眠停充/用户动作语义；
///   睡眠路径 verifyFailed 也不写 lastAction，DaemonCore.swift:229-233 只记日志）。
/// - **WP2 动作字面量（P1-3 + P1-4）**：
///   `fullOnce:done` 转移 → `.actionCompleted`；`fullOnce:timeout` 转移 →
///   `.actionTimeout`；`fullOnce:cancel(crash-recovery)` 转移 →
///   `.actionInterrupted`；`fullOnce:cancel`（用户/隐式取消）→ 无事件；
///   首样本（previous == nil）→ 空数组（既有语义；终态锁存保证 App 重启前转移可见）。
///   **P1-4**：previous.lastAction 带 `fullOnce:` 前缀（终态锁存）→ 本次不产
///   `.limitReached`——防「充满完成→恢复停充」被误报为达到 80% 上限。
public func notificationEvents(
    previous: DaemonStatus?,
    current: DaemonStatus
) -> [CellarNotificationEvent] {
    guard let previous else {
        switch current.lastAction {
        case "enforce:error":
            return [.writeFailed]
        case "enforce:verifyFailed":
            return [.conflictSuspected]
        default:
            return []
        }
    }
    guard current.lastAction != previous.lastAction else { return [] }
    switch current.lastAction {
    case "enforce:disableCharging":
        // P1-4：previous 为 fullOnce:*（终态锁存）→ 恢复停充是动作的期望收尾，
        // 不误报 limitReached（前缀含 start——该转移不可达，防御覆盖无害）。
        if previous.lastAction?.hasPrefix("fullOnce:") == true { return [] }
        return [.limitReached(upperLimit: current.upperLimit)]
    case "enforce:error":
        return [.writeFailed]
    case "enforce:verifyFailed":
        return [.conflictSuspected]
    case OneShotLiteral.done():
        return [.actionCompleted(kind: OneShot.fullOnceKind)]
    case OneShotLiteral.timeout():
        return [.actionTimeout(kind: OneShot.fullOnceKind)]
    case OneShotLiteral.cancelCrashRecovery():
        return [.actionInterrupted(kind: OneShot.fullOnceKind)]
    case OneShotLiteral.cancel():
        return []
    default:
        return []
    }
}