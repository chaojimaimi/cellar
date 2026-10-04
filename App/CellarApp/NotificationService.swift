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
///   面板横幅仍承担告警通道）；0.22.2 §3 起投递统一入口（post）再查授权态
///   ——notDetermined 即场请求（实证既有接线存在前完成的引导从不触发请求，
///   ncprefs 无 Cellar 条目 = 从未授权）。
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

    // MARK: - 0.22.2 §3 投递统一入口（ensureAuthorization 收敛）

    /// 投递统一入口（单一真相源——内部构 request）：投递前查授权态——
    /// `.notDetermined` → 即场 `requestAuthorization`（options [.alert, .sound]
    /// 与既有 requestAuthorization 一致；系统弹窗，用户点允许后投递本条，拒绝/
    /// 未答/出错 → 静默丢弃）；`.authorized/.provisional` → 直接投递；其余
    /// （denied 等）→ 丢弃（既有语义）。
    ///
    /// WHY 0.22.2 补此门：授权请求唯一触发点在引导安装成功臂，用户引导流程在
    /// 该接线存在之前已完成（换 App 不重跑）——实证 ncprefs 无 Cellar 条目 =
    /// 大多数安装从未收到过授权请求，通知被系统静默丢弃（未授权态 add 无错
    /// 不显示）。弹窗只在首个有意义通知到期时出现一次（上下文自解释）。
    /// **冷却戳语义保持既有形状（先戳后投）**：弹窗未答时戳已消耗——本条虽
    /// 允许后仍投，但被弹窗占用的窗口内同型重报被冷却吞掉，方案已接受。
    /// 呈现预期：willPresent 恒 [.list]——App 前台只进通知中心列表不弹横幅，
    /// 非前台才弹横幅。
    /// 形态注记：async + 非 escaping content 闭包（授权门是异步链——回调式
    /// 跨闭包捕获在 Swift 6 严格并发下触发 sending 竞态检查；async 形态全程
    /// 驻留 MainActor 帧（类为 @MainActor，await 恢复点回同 actor），content
    /// 闭包在帧内构造即消费零跨界。调用点以 `Task { await post(...) { ... } }`
    /// 承载，闭包字面量在 Task 帧内构造。
    private func post(identifier: String, content: () -> UNNotificationContent) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // 错误与用户拒绝分流（code-review P3：try? 吞错会把系统侧失败误读
            // 为用户拒绝——排障方向相反；照既有引导路径 helper 记 error detail）。
            let granted: Bool
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.log.error("通知授权请求失败（\(identifier, privacy: .public)）：\(error.localizedDescription)")
                granted = false
            }
            Self.log.info("通知授权即场请求（\(identifier, privacy: .public)）：\(granted ? "已授予，投递本条" : "未授予，静默丢弃")")
            guard granted else { return }
            add(identifier: identifier, content: content())
        case .authorized, .provisional:
            add(identifier: identifier, content: content())
        default:
            break   // denied 等 → 丢弃（既有语义：面板横幅承担告警通道）
        }
    }

    /// 实际投递（post 的授权放行后终端；错误 os_log 可见化，identifier 随行
    /// 定位来源——四条路径日志归一）。
    private func add(identifier: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("通知投递失败（\(identifier, privacy: .public)）：\(error.localizedDescription)")
            }
        }
    }

    /// 投递事件（StatusController 事件出口）。同类型冷却内静默跳过（不重发）。
    /// 冷却键 = 事件类型字符串（评审 P2）：非 Hashable 整体——limitReached(80) 与
    /// limitReached(90) 共享同类型冷却，对齐规格「同事件类型 10 分钟」口径。
    /// WP2 动作终态事件**豁免冷却**：identifier 内嵌投递时刻 epoch（全局唯一），
    /// 冷却表永不命中——一次性动作终态命中即达，不重复打扰（WP2' 放电终态同款）。
    /// WP2'：lastPercent 参与放电终态文案组装（`当前电量 N%`）。
    /// 0.22.2 §3：投递收敛 post 统一入口（授权检查 + 即场请求）。
    func deliver(_ event: CellarNotificationEvent, lastPercent: Int? = nil) {
        let now = Date()
        let cooldownKey = Self.identifier(for: event, now: now)
        if let last = lastDelivered[cooldownKey], now.timeIntervalSince(last) < Self.cooldownSeconds {
            return
        }
        lastDelivered[cooldownKey] = now
        let identifier = Self.identifier(for: event, now: now)
        Task {
            await post(identifier: identifier) {
                let content = UNMutableNotificationContent()
                content.title = "Cellar"
                content.body = Self.message(for: event, lastPercent: lastPercent)
                return content
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

    // MARK: - Phase 5 v1.6 充电日程边沿（UD-7）

    /// 日程边沿通知直投（不走 CellarNotificationEvent 映射——UD-7 不新增 case）。
    /// identifier 内嵌投递时刻 epoch **豁免 10 分钟同型冷却**（照校准事件先例——
    /// 相邻窗口边沿是真事件，冷却会吞掉切换可见性；边沿本身有 daemon 30s tick
    /// 粒度，不会高频重复）。0.22.2 §3：投递收敛 post 统一入口（授权检查 +
    /// 即场请求）。
    func deliverSchedule(_ notification: ScheduleNotification) {
        let now = Date()
        let identifier: String
        let body: String
        switch notification {
        case .entered(let summary):
            identifier = "schedule.entered.\(Int(now.timeIntervalSince1970))"
            body = CellarL10n.s("notification.scheduleEntered", summary)
        case .restored:
            identifier = "schedule.restored.\(Int(now.timeIntervalSince1970))"
            body = CellarL10n.s("notification.scheduleRestored")
        }
        Task {
            await post(identifier: identifier) {
                let content = UNMutableNotificationContent()
                content.title = "Cellar"
                content.body = body
                return content
            }
        }
    }

    // MARK: - 0.22.0 §4.2 sub80 机制关闭系统通知（UD-7 形态直投）

    /// suppression 通知独立限频（内存级静态 1 h 窗——App 重启清零；与 deliver
    /// 既有 600s 同型冷却机制互不相干，独立静态时间戳）。⚠️ static var：类为
    /// @MainActor，静态态读写只在主 actor——无数据竞争面。
    private static let suppressionCooldownSeconds: TimeInterval = 3600
    private static var lastSuppressionDelivery: Date?

    /// sub80 机制关闭通知直投（不走 CellarNotificationEvent 映射——UD-7 形态，
    /// 照 deliverSchedule 先例）。identifier 静态复用（限频窗内重复投递被跳过；
    /// 静态 id 兼防限频外堆叠——后到覆盖通知中心的未读同 id 项）。文案首要
    /// 指引「在 Cellar 重新应用上限」（API 路径——保机制使能且保域执法，§11.9
    /// 三分支），次选系统设置设具体上限；与既有横幅 settings.sub80.suppressed
    /// 同源措辞。授权未授予/未请求 → post 统一入口处理（0.22.2 起即场请求，
    /// 拒绝静默丢弃）。
    /// 0.22.1：消费面收缩为恢复写失败臂（成功改投 deliverSuppressionRecovered；
    /// 首拍失败指引 + 冷却重试拍失败经本窗 1h 静默——不重复轰炸）。
    /// 0.22.2 §3：投递收敛 post 统一入口（授权检查 + 即场请求）。
    func deliverSuppressionNotice(now: Date = Date()) {
        if let last = Self.lastSuppressionDelivery,
           now.timeIntervalSince(last) < Self.suppressionCooldownSeconds {
            return
        }
        Self.lastSuppressionDelivery = now
        Task {
            await post(identifier: "cellar.sub80-suppressed") {
                let content = UNMutableNotificationContent()
                content.title = "Cellar"
                content.body = CellarL10n.s("notification.sub80Suppressed")
                return content
            }
        }
    }

    /// suppression 自动恢复成功通知独立限频（内存级静态 1 h 窗——App 重启清零；
    /// 与 deliverSuppressionNotice 限频同形态、独立静态时间戳互不相干）。
    private static var lastSuppressionRecoveredDelivery: Date?

    /// suppression 自动恢复成功通知直投（0.22.1 §1.3；照 deliverSuppressionNotice
    /// 形态——静态 id 兼防限频外堆叠）。冷却重试拍成功也投（评审 P3-7：用户可能
    /// 已开始手动操作，须告知已自动恢复）——本通知自身 1h 限频兜底防轰炸。文案
    /// 如实口径：端到端含 daemon 冷却重写（0-10 min）+ agent 分钟级跟随，不写
    /// 「约 1 分钟」（评审 P1-1）。授权未请求（ncprefs 实证常态）→ post 统一
    /// 入口即场请求——0.22.2 现场 = 首次弹授权请求，允许后本条即投。
    /// 0.22.2 §3：投递收敛 post 统一入口（授权检查 + 即场请求）。
    func deliverSuppressionRecovered(now: Date = Date()) {
        if let last = Self.lastSuppressionRecoveredDelivery,
           now.timeIntervalSince(last) < Self.suppressionCooldownSeconds {
            return
        }
        Self.lastSuppressionRecoveredDelivery = now
        Task {
            await post(identifier: "cellar.sub80-recovered") {
                let content = UNMutableNotificationContent()
                content.title = "Cellar"
                content.body = CellarL10n.s("notification.sub80Recovered")
                return content
            }
        }
    }
}