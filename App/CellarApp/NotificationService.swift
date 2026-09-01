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
    func deliver(_ event: CellarNotificationEvent) {
        let now = Date()
        let cooldownKey = Self.identifier(for: event)
        if let last = lastDelivered[cooldownKey], now.timeIntervalSince(last) < Self.cooldownSeconds {
            return
        }
        lastDelivered[cooldownKey] = now
        let content = UNMutableNotificationContent()
        content.title = "Cellar"
        content.body = Self.message(for: event)
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: event),
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
    nonisolated static func message(for event: CellarNotificationEvent) -> String {
        switch event {
        case .limitReached(let upperLimit):
            return String(format: limitReachedFormat, upperLimit)
        case .writeFailed:
            return writeFailedMessage
        case .conflictSuspected:
            return conflictSuspectedMessage
        }
    }

    /// 通知 identifier（同类型复用，冷却范围内重复投递被跳过）。
    private nonisolated static func identifier(for event: CellarNotificationEvent) -> String {
        switch event {
        case .limitReached: return "cellar.limit-reached"
        case .writeFailed: return "cellar.write-failed"
        case .conflictSuspected: return "cellar.conflict-suspected"
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