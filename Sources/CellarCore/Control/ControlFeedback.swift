import Foundation

// MARK: - 控制操作反馈（WP4 自 App/StatusController 下迁；规格 §2.3 三态 + §3.4 stale 分支）

/// 控制操作反馈。非成功态全部红色系，面板按 case 渲染；Message 为 daemon 拒绝
/// 原文或本地预检文案。纯值类型（依赖闭包仅 Foundation）——直迁 CellarCore，
/// CellarUI 横幅与 App 控制器共享同一类型（消除 App/组件类型分居）。
public enum ControlFeedback: Equatable {
    case success(String)
    /// daemon 拒绝原文上屏（含面板本地 LimitPolicy 预检失败文案——同一条反馈行）。
    case daemonRejected(String)
    /// 传输失败（timeout/connectionFailed）。
    case transferFailed
    /// stale daemon：版本不匹配（旧二进制无 admin 组判定，拒绝原文对面板用户是错误引导）。
    case staleDaemon
}
