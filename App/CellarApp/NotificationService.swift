import CellarCore
import Foundation
import os
import UserNotifications

/// 通知中心服务（WP5 §2.3；仅 App target——root daemon 不可发用户通知）。
///
/// - **delegate 必须在 App 启动早期赋值（CellarApp.init）**：迟设错过首条
///   willPresent（硬事实 4），前台呈现策略失效。
/// - 授权请求在引导 step 3 安装成功后发起（拒绝 → 静默停用：功能不受损，
///   面板横幅仍承担告警通道）。
/// - 投递冷却：同事件类型 10 分钟（**内存级，App 重启清零**，登记 §2.3）。
/// - 前台（面板可见）呈现 = `.list`（通知中心留档不弹横幅——面板内已有横幅
///   通道，双通道错开）。
/// - 文案定版（§2.3，Phase 2 仅中文；面板失败横幅文案与本类常量同源）。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    /// 已达充电上限（§2.3 定版文案）。
    nonisolated static let limitReachedFormat = "已达充电上限 %d%，已停止充电"
    /// 写失败告警（红线 5）。
    nonisolated static let writeFailedMessage = "充电控制写入失败，限充可能未生效——请打开面板查看"
    /// 外部写者冲突告警。
    nonisolated static let conflictSuspectedMessage = "检测到其他工具在改动充电状态，可能与 Cellar 冲突"
    /// WP2 一次性动作终态文案（§1.1 终态事件；与失败横幅通道同源）。
    nonisolated static let actionCompletedMessage = "「充满一次」已完成：已恢复限充"
    nonisolated static let actionTimeoutMessage = "「充满一次」超时（4 小时未充满）：已恢复限充"
    nonisolated static let actionInterruptedMessage = "「充满一次」已中断（守护进程重启）：已恢复限充"
    /// WP2' 放电终态文案（中文硬编码，WP4 S3 统一本地化；「当前电量 N%」按
    /// event.kind + status.lastPercent 组装——评审 P2-6，参数不进线格式）。
    nonisolated static let dischargeCompletedFormat = "已放电至上限 %d%%，限充已恢复"
    nonisolated static let dischargeTimeoutFormat = "已达安全时限，已恢复限充（当前电量 %d%%）"
    nonisolated static let dischargeSafetyMessageFormat = "放电已安全终止，已恢复充电（当前电量 %d%%）"
    nonisolated static let dischargeCancelledMessage = "已取消放电，已恢复充电"
    nonisolated static let dischargeInterruptedMessage = "放电已中断（守护进程重启）：已恢复充电"
    /// safety 终态横幅文案（横幅通道无 lastPercent 可组装，与通知文案的百分比
    /// 变体同源去参——StatusFailureKind.message App 侧扩展消费）。
    nonisolated static let actionSafetyTerminatedMessage = "放电已安全终止，已恢复充电"

    /// 同事件类型投递冷却（秒；内存级，App 重启清零）。
    private static let cooldownSeconds: TimeInterval = 600
    private var lastDelivered: [String: Date] = [:]

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "notifications")

    /// delegate 早期赋值（App 启动时调用一次；硬事实 4）。
    func installDelegate() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 请求通知授权（引导 step 3 安装成功后发起）。拒绝 → 静默停用：功能不受损，
    /// 面板横幅仍承担告警；不反复打扰。
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let detail = error.map { "，错误：\($0.localizedDescription)" } ?? ""
            Self.log.info("通知授权结果：\(granted ? "已授予" : "未授予")\(detail)")
        }
    }

    /// 投递事件（StatusController 事件出口）。同类型冷却内静默跳过（不重发）。
    /// 冷却键 = 事件类型字符串（评审 P2）：非 Hashable 整体——limitReached(80) 与
    /// limitReached(90) 共享同类型冷却，对齐规格「同事件类型 10 分钟」口径。
    /// WP2 动作终态事件**豁免冷却**：identifier 内嵌投递时刻 epoch（全局唯一），
    /// 冷却表永不命中——一次性动作终态命中即达，不重复打扰（WP2' 放电终态同款）。
    /// WP2'：lastPercent 参与放电终态文案组装（`当前电量 N%`）。
    func deliver(_ event: CellarNotificationEvent, lastPercent: Int? = nil) {
        let now = Date()
        let cooldownKey = Self.identifier(for: event, now: now)
        if let last = lastDelivered[cooldownKey], now.timeIntervalSince(last) < Self.cooldownSeconds {
            return
        }
        lastDelivered[cooldownKey] = now
        let content = UNMutableNotificationContent()
        content.title = "Cellar"
        content.body = Self.message(for: event, lastPercent: lastPercent)
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: event, now: now),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("通知投递失败：\(error.localizedDescription)")
            }
        }
    }

    /// 文案映射（投递 + 面板失败横幅同源——§2.3 定版常量集中本类）。
    /// WP2'：放电终态文案按 kind 分流（fullOnce 文案不变，零回归）+ lastPercent
    /// 组装「当前电量 N%」。
    nonisolated static func message(for event: CellarNotificationEvent, lastPercent: Int? = nil) -> String {
        let dischargeKind = Discharge.dischargeToLimitKind
        switch event {
        case .limitReached(let upperLimit):
            return String(format: limitReachedFormat, upperLimit)
        case .writeFailed:
            return writeFailedMessage
        case .conflictSuspected:
            return conflictSuspectedMessage
        case .actionCompleted(let kind):
            return kind == dischargeKind
                ? String(format: dischargeCompletedFormat, lastPercent ?? 0)
                : actionCompletedMessage
        case .actionTimeout(let kind):
            return kind == dischargeKind
                ? String(format: dischargeTimeoutFormat, lastPercent ?? 0)
                : actionTimeoutMessage
        case .actionSafetyTerminated(let kind):
            return kind == dischargeKind
                ? String(format: dischargeSafetyMessageFormat, lastPercent ?? 0)
                : actionSafetyTerminatedMessage
        case .actionCancelled:
            // 仅 discharge 系产生 actionCancelled（fullOnce 用户取消不通知，§2.3
            // 对照）——kind 无分流，单一文案（审查 L3：收敛恒等三元）。
            return dischargeCancelledMessage
        case .actionInterrupted(let kind):
            return kind == dischargeKind ? dischargeInterruptedMessage : actionInterruptedMessage
        }
    }

    /// 通知 identifier（同类型复用，冷却范围内重复投递被跳过）。
    /// WP2 动作终态：`action.<kind>.<终态>.<epoch>`（epoch = 投递时刻，
    /// identifier 全局唯一 + 豁免冷却；§1.7 定版；WP2' discharge 同款）。
    private nonisolated static func identifier(for event: CellarNotificationEvent, now: Date) -> String {
        switch event {
        case .limitReached: return "cellar.limit-reached"
        case .writeFailed: return "cellar.write-failed"
        case .conflictSuspected: return "cellar.conflict-suspected"
        case .actionCompleted(let kind): return "action.\(kind).done.\(Int(now.timeIntervalSince1970))"
        case .actionTimeout(let kind): return "action.\(kind).timeout.\(Int(now.timeIntervalSince1970))"
        case .actionInterrupted(let kind): return "action.\(kind).interrupted.\(Int(now.timeIntervalSince1970))"
        case .actionSafetyTerminated(let kind): return "action.\(kind).safety.\(Int(now.timeIntervalSince1970))"
        case .actionCancelled(let kind): return "action.\(kind).cancelled.\(Int(now.timeIntervalSince1970))"
        }
    }

    /// 前台呈现 = `.list`（通知中心留档不弹横幅；面板横幅通道承担即时可见性）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }
}