import Foundation

// MARK: - status 派生失败横幅形态（WP5 §2.3 P1-1 配套；WP4 按硬事实 3 判据下迁）

/// status 派生失败横幅形态：daemonStatus.lastAction 为 enforce:error /
/// enforce:verifyFailed 时由 StatusController 暴露——**不占用 controlFeedback
/// 通道**（daemon 侧 enforce 失败 WP4 横幅本不覆盖；原「双通道」表述系引用未
/// 接线的通道，本条修复该矛盾）。
///
/// ⚠️ 迁移判据（硬事实 3）：类型可迁 CellarCore ⟺ 依赖闭包仅 Foundation/os；
/// **用户可见串必须剥离**——原 `.message` 计算属性（硬引用 App 层
/// NotificationService 文案常量）不随迁，App 层以 extension 补齐（零行为变化）；
/// S3 时文案同走 CellarL10n 的 notification.* key（公告-横幅同源强化）。与
/// CellarCore 既有 notificationEvents 的 lastAction 共享字面量解析（消除双解析
/// 器）同样留给 S3。
public enum StatusFailureKind: Equatable {
    /// 写/传输失败（enforce:error）——红线 5。
    case writeFailed
    /// 外部写者冲突显式化（enforce:verifyFailed）。
    case conflictSuspected
    /// WP2 一次性动作终态（既有横幅通道新分支，P2-4 接线）：
    /// fullOnce:done / timeout / cancel(crash-recovery)——锁存期持续呈现，
    /// 下一次用户动作（新动作/取消/改限）自然清除。
    case actionCompleted
    case actionTimedOut
    case actionInterrupted

    /// 从 daemonStatus 派生（⚠️ lastAction 字面量与 CellarCore 通知分类同契约——
    /// 变更两侧同步暴露，CellarCoreCheck 钉死精确值）。
    public init?(status: DaemonStatus) {
        switch status.lastAction {
        case "enforce:error": self = .writeFailed
        case "enforce:verifyFailed": self = .conflictSuspected
        case "fullOnce:done": self = .actionCompleted
        case "fullOnce:timeout": self = .actionTimedOut
        case "fullOnce:cancel(crash-recovery)": self = .actionInterrupted
        default: return nil
        }
    }
}
