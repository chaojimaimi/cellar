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
    /// WP2 一次性动作终态（横幅通道）：timeout / cancel(crash-recovery)——安全
    /// 终态锁存期持续呈现（用户需知情），下一次用户动作自然清除。
    /// ⚠️ **done（成功完成）不进本通道**（真机验收修正 2026-09-02：成功被渲染为
    /// 红色告警横幅且锁存常驻——改走 controlFeedback .success + 5s 自动消退，
    /// StatusController.ingest 上升沿检测）。
    case actionTimedOut
    case actionInterrupted
    /// WP2' discharge 安全终止（dischargeToLimit:safety——温度/地板/监护缺失/
    /// CHIE 残留巡检；横幅 + 通知同源，App 侧文案含当前电量组装）。
    case actionSafetyTerminated

    /// 从 daemonStatus 派生（⚠️ lastAction 字面量与 CellarCore 通知分类同契约——
    /// 变更两侧同步暴露，CellarCoreCheck 钉死精确值）。done 字面量（fullOnce/
    /// dischargeToLimit/calibration）不映射（成功走 success 反馈通道）；超时/崩溃
    /// 中断映射安全终态；取消（cancel）不入通道（用户动作，不打扰）。
    /// WP3（R2 P2-3 钉死）：calibration:safety/timeout/cancel(crash-recovery) →
    /// .actionInterrupted（校准中止红色横幅如实上屏；横幅复用既有 actionInterrupted
    /// 通用文案不显「校准」字样——通知通道有专属文案，横幅为次通道，失真登记 R2
    /// P3-2）；calibration:done/cancel 不入失败通道（done 走成功横幅、cancel 走
    /// statusFailure 无痕）。
    public init?(status: DaemonStatus) {
        switch status.lastAction {
        case "enforce:error": self = .writeFailed
        case "enforce:verifyFailed": self = .conflictSuspected
        case "fullOnce:timeout", "dischargeToLimit:timeout": self = .actionTimedOut
        case "fullOnce:cancel(crash-recovery)", "dischargeToLimit:cancel(crash-recovery)": self = .actionInterrupted
        case "calibration:safety", "calibration:timeout", "calibration:cancel(crash-recovery)": self = .actionInterrupted
        case "dischargeToLimit:safety": self = .actionSafetyTerminated
        default: return nil
        }
    }
}
