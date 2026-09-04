import CellarCore
import CellarUI
import SwiftUI
import UserNotifications

/// 通用分节内容（M3.5 工单 4 自 SettingsView 内 private GeneralTab 提取——设置
/// 窗退役后并入主窗口通用页；登录项开关 + 注册态 + 通知授权 + 自动放电组 +
/// 风扇组全部随迁，行为零变化）。
///
/// ⚠️ 不含 ScrollView / 内容理想高测量 / `@Binding contentHeight` 成帧——那些
/// 是设置窗成帧包装的专属装置，随设置窗一并退役（reportContentHeight /
/// contentHeightMeasurement 零残留）。
struct GeneralSections: View {
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme
    /// 通知授权态（nil = 查询中；getNotificationSettings 异步回主线程刷新）。
    @State private var notificationAuthorized: Bool?
    /// 自动放电开启两步内嵌确认块（nil = 未展开；确认/取消后关闭）。
    @State private var autoDischargeConfirming = false

    var body: some View {
        Form {
            // 节头一律 CellarL10n.s 构造——App target 查不到 CellarUI bundle 的
            // 裸 key 字面量会渲染裸字符串，无机械门拦截（R1 P3 红线）。
            Section {
                Toggle(CellarL10n.s("common.launchAtLogin"), isOn: Binding(
                    get: { loginItems.launchAtLogin },
                    set: { loginItems.toggle($0) }
                ))
                .disabled(loginItems.busy)

                LabeledContent(CellarL10n.s("settings.registrationStatus")) {
                    HStack {
                        Text(registrationText)
                        // 修复路径落控制器（评审 P2-2）；已注册态按钮无意义，禁用。
                        Button(CellarL10n.s("settings.reregister")) { loginItems.reregister() }
                            .disabled(loginItems.busy || loginItems.registration == .enabled)
                    }
                }

                LabeledContent(CellarL10n.s("settings.notifications")) {
                    HStack {
                        Text(notificationText)
                        Button(CellarL10n.s("settings.openSystemSettings")) { openNotificationSettings() }
                    }
                }

                if let feedback = loginItems.feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            } header: {
                Text(CellarL10n.s("settings.section.general"))
            }

            // WP2' 自动放电组——无头节（R1 P1-1 定案）：开关标签「自动放电」
            // 自任标题，带节头必同文相邻重复；仅取节间距分组。开关绑定 daemonStatus
            // 单一真相（daemon 确认后状态回传翻转）；开启两步内嵌确认块，关闭
            // 直通（关是安全方向）。
            Section {
                Toggle(CellarL10n.s("settings.autoDischarge"), isOn: Binding(
                    get: { statusController.daemonStatus?.autoDischargeEnabled == true },
                    set: { toggleAutoDischarge($0) }
                ))
                .disabled(autoDischargeCapabilityAvailable == false)

                // 开关旁一句话说明（code-review P2-3：消费 desc key，防空目录死项）。
                Text(CellarL10n.s("settings.autoDischarge.desc"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)

                // 能力门控提示（三态惯例：capabilities nil = 旧 daemon 需升级；已上报
                // 但缺 autoDischarge = 当前机型或版本不支持；含 = 可用且无提示）。
                if let hint = autoDischargeGateHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }

                // 开启两步内嵌确认块（同 ActionSectionView 确认形态）：弹出前已刷新一次
                // status——upper/hys 取 daemonStatus 现值，缩 60s 陈旧窗（R2 P3）。
                if autoDischargeConfirming {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(CellarL10n.s("settings.autoDischarge.warning"))
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                        HStack {
                            Button(CellarL10n.s("settings.autoDischarge.confirm")) { confirmAutoDischarge() }
                                .disabled(statusController.busy)
                            Button(CellarL10n.s("common.cancel")) { autoDischargeConfirming = false }
                        }
                    }
                }
            }

            Section {
                // Phase 5 v1.1：风扇智能降温区（参数驱动组件，照校准区先例——开关两步
                // 内嵌确认/策略 Picker/阈值与转速滑杆/twoStage 条件参数/九态状态行；
                // 旧 daemon（fan==nil）控件禁用 + 升级提示）。v1.2：showsTitle false——
                // 标题由节头「智能风扇降温」承担，组件自身标题关掉防同文重复。
                FanSectionView(
                    fan: statusController.fanStatus,
                    busy: statusController.busy,
                    onApply: { statusController.setFan($0) },
                    showsTitle: false
                )
            } header: {
                Text(CellarL10n.s("settings.section.fan"))
            }
        }
        .onAppear {
            loginItems.load()
            loginItems.refreshRegistration()
            queryNotificationAuthorization()
        }
    }

    // MARK: - WP2' 自动放电

    /// 能力门控：capabilities 含 autoDischarge 才可用（nil = 旧 daemon 未上报，
    /// [] = 已上报但不含能力）。
    private var autoDischargeCapabilityAvailable: Bool {
        statusController.capabilities?.contains(DaemonXPC.capabilityAutoDischarge) == true
    }

    /// 禁用态提示（nil = 可用，无提示）。capabilities == nil → 需升级守护进程
    /// （复用面板既有 needUpgrade 文案 key——同三态惯例）；缺能力 → 不支持。
    private var autoDischargeGateHint: String? {
        guard !autoDischargeCapabilityAvailable else { return nil }
        if statusController.capabilities == nil {
            return CellarL10n.s("panel.action.needUpgrade")
        }
        return CellarL10n.s("settings.autoDischarge.unsupported")
    }

    /// 开关动作：开启 → 先刷新一次 status（缩窗）再展开确认块；关闭直通。
    private func toggleAutoDischarge(_ enabled: Bool) {
        guard autoDischargeCapabilityAvailable else { return }
        if enabled {
            statusController.refreshNow()
            autoDischargeConfirming = true
        } else {
            autoDischargeConfirming = false
            applyAutoDischarge(false)
        }
    }

    /// 确认开启：upper/hys 取 daemonStatus 现值（单一真相），auto 显式 true。
    private func confirmAutoDischarge() {
        guard let status = statusController.daemonStatus else {
            autoDischargeConfirming = false
            return
        }
        autoDischargeConfirming = false
        statusController.applyLimits(
            upperLimit: status.upperLimit, hysteresis: status.hysteresis, autoDischarge: true
        )
    }

    /// 关闭直通（经 setLimits auto=0 持久化；daemon 缺席保持语义下显式传 false
    /// 即关——在轨自动放电不被打断，属设计）。
    private func applyAutoDischarge(_ enabled: Bool) {
        guard let status = statusController.daemonStatus else { return }
        statusController.applyLimits(
            upperLimit: status.upperLimit, hysteresis: status.hysteresis, autoDischarge: enabled
        )
    }

    private var registrationText: String {
        switch loginItems.registration {
        case .enabled: return CellarL10n.s("settings.regEnabled")
        case .requiresApproval: return CellarL10n.s("settings.regApproval")
        case .notRegistered: return CellarL10n.s("common.notRegistered")
        case .unknown: return CellarL10n.s("common.querying")
        }
    }

    private var notificationText: String {
        guard let authorized = notificationAuthorized else { return CellarL10n.s("common.querying") }
        return authorized ? CellarL10n.s("settings.notifAuthorized") : CellarL10n.s("settings.notifDenied")
    }

    /// 通知授权态直查（异步回调回主线程刷新；拒授权属常态非错误，不上告警色）。
    private func queryNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                notificationAuthorized = authorized
            }
        }
    }

    /// 打开系统通知设置（App 不自管通知开关——授权是系统域，评审 P2-2 定版 URL）。
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}