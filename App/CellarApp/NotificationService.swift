import CellarCore
import CellarUI
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
/// - 文案定版（WP4 S3）：全部经 CellarL10n 解析 notification.* key（compose 时
///   在 App 进程内解析——UNUserNotificationCenter 展示不再解析，硬事实 9）；
///   面板失败横幅文案与通知同 catalog 同源（§2.3）。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    // S3：文案常量全部移除——message(for:) 经 CellarL10n 解析 notification.* key
    // （catalog 双形态：xcodebuild 编译 lproj / swift build 原始 xcstrings 回退）；
    // 面板横幅（StatusFailureKind.message）与通知同源共用同一批 key。

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

    /// 文案映射（投递 + 面板失败横幅同源——§2.3 定版：同走 CellarL10n 的
    /// notification.* key）。⚠️ 解析点 = **compose 时**（App 进程内，硬事实 9）；
    /// 插值经 CellarL10n.s 的 String(format:)（%lld%% 转义）。lastPercent 组装
    /// 「当前电量 N%」。
    nonisolated static func message(for event: CellarNotificationEvent, lastPercent: Int? = nil) -> String {
        let dischargeKind = Discharge.dischargeToLimitKind
        switch event {
        case .limitReached(let upperLimit):
            return CellarL10n.s("notification.limitReached", upperLimit)
        case .writeFailed:
            return CellarL10n.s("notification.writeFailed")
        case .conflictSuspected:
            return CellarL10n.s("notification.conflictSuspected")
        case .actionCompleted(let kind):
            return kind == dischargeKind
                ? CellarL10n.s("notification.dischargeCompleted", lastPercent ?? 0)
                : CellarL10n.s("notification.actionCompleted")
        case .actionTimeout(let kind):
            return kind == dischargeKind
                ? CellarL10n.s("notification.dischargeTimeout", lastPercent ?? 0)
                : CellarL10n.s("notification.actionTimeout")
        case .actionSafetyTerminated(let kind):
            return kind == dischargeKind
                ? CellarL10n.s("notification.dischargeSafety", lastPercent ?? 0)
                : CellarL10n.s("notification.actionSafetyTerminated")
        case .actionCancelled:
            // 仅 discharge 系产生 actionCancelled（fullOnce 用户取消不通知，§2.3
            // 对照）——kind 无分流，单一文案（审查 L3：收敛恒等三元）。
            return CellarL10n.s("notification.dischargeCancelled")
        case .actionInterrupted(let kind):
            return kind == dischargeKind ? CellarL10n.s("notification.dischargeInterrupted") : CellarL10n.s("notification.actionInterrupted")
        case .autoDischargeStarted(let upperLimit):
            // WP2' 自动放电启动（触发时用户不在场；目标 = 触发时刻策略上限）。
            return CellarL10n.s("notification.autoDischargeStarted", upperLimit)
        case .calibrationPhaseChanged(let phase):
            // WP3 校准相位转移：相位词经 CellarL10n（calibration.phase.*，与面板
            // 同 catalog 同源——夜间过夜场景用户须能区分相位）。
            let word: String
            switch phase {
            case .chargeFull: word = CellarL10n.s("calibration.phase.chargeFull")
            case .hold: word = CellarL10n.s("calibration.phase.hold")
            case .discharge: word = CellarL10n.s("calibration.phase.discharge")
            }
            return CellarL10n.s("notification.calibrationPhase", word)
        case .calibrationCompleted:
            return CellarL10n.s("notification.calibrationCompleted")
        case .calibrationInterrupted:
            return CellarL10n.s("notification.calibrationInterrupted")
        }
    }

    /// 通知 identifier（同类型复用，冷却范围内重复投递被跳过）。
    /// WP2 动作终态：`action.<kind>.<终态>.<epoch>`（epoch = 投递时刻，
    /// identifier 全局唯一 + 豁免冷却；§1.7 定版；WP2' discharge 同款）。
    /// WP2' 自动放电启动：同款独立 identifier + epoch——不走 10 分钟同型冷却
    /// （触发本身有 30 分钟 daemon 侧冷却，双冷却叠加会压掉启动可见性）。
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
        case .autoDischargeStarted: return "action.\(Discharge.dischargeToLimitKind).autostart.\(Int(now.timeIntervalSince1970))"
        case .calibrationPhaseChanged: return "calibration.phase.\(Int(now.timeIntervalSince1970))"
        case .calibrationCompleted: return "calibration.completed.\(Int(now.timeIntervalSince1970))"
        case .calibrationInterrupted: return "calibration.interrupted.\(Int(now.timeIntervalSince1970))"
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