import CellarCore
import CellarUI
import SwiftUI
import UserNotifications

/// 设置窗口（WP3 §4 定版三 Tab：外观 / 通用 / 关于；形态 = spike S1 定版的
/// 原生 Settings scene——组合根声明 + 面板 SettingsLink 入口）。外观 Tab 独立
/// 文件；关于 Tab 的风格展示行同为风格词元（白名单成员），本文件整体属 G1 白名单。
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceTab()
                .tabItem { Label(CellarL10n.s("settings.appearance"), systemImage: "paintpalette") }
            GeneralTab()
                .tabItem { Label(CellarL10n.s("settings.general"), systemImage: "gearshape") }
            AboutTab()
                .tabItem { Label(CellarL10n.s("settings.about"), systemImage: "info.circle") }
        }
        // 高度随通用 Tab 内容增长（v1.1 加风扇区后 300 已裁切内容——三 Tab 共用
        // 一帧，取最高 Tab 适配；Form 不自动滚动，高度不足即静默裁切）。
        .frame(width: 420, height: 680)
    }
}

// MARK: - 通用 Tab（WP3 §4）：开机启动双入口（与面板同源）+ 登录项注册态/
// 重新注册 + 通知授权态（onAppear 直查系统，不经 NotificationService——非
// Observable 且组合根私有，评审 P2-2 定版；App 不自管通知开关，授权是系统域）。

private struct GeneralTab: View {
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme
    /// 通知授权态（nil = 查询中；getNotificationSettings 异步回主线程刷新）。
    @State private var notificationAuthorized: Bool?
    /// 自动放电开启两步内嵌确认块（nil = 未展开；确认/取消后关闭）。
    @State private var autoDischargeConfirming = false

    var body: some View {
        Form {
            Toggle(CellarL10n.s("common.launchAtLogin"), isOn: Binding(
                get: { loginItems.launchAtLogin },
                set: { loginItems.toggle($0) }
            ))
            .disabled(loginItems.busy)

            // WP2' 自动放电组（登录项下方）：开关绑定 daemonStatus 单一真相（daemon
            // 确认后状态回传翻转）；开启两步内嵌确认块，关闭直通（关是安全方向）。
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

            // Phase 5 v1.1：风扇智能降温区（参数驱动组件，照校准区先例——开关两步
            // 内嵌确认/策略 Picker/阈值与转速滑杆/twoStage 条件参数/九态状态行；
            // 旧 daemon（fan==nil）控件禁用 + 升级提示）。
            FanSectionView(
                fan: statusController.fanStatus,
                busy: statusController.busy,
                onApply: { statusController.setFan($0) }
            )

            Divider()

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
        }
        .padding()
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

// MARK: - 关于 Tab（WP3 §4）：App/daemon 版本（不匹配 = 既有 stale 语义警示）+
// 复制诊断摘要（App/daemon 版本、注册态、连接态、风格，贴剪贴板）。

private struct AboutTab: View {
    @EnvironmentObject private var statusController: StatusController
    @EnvironmentObject private var loginItems: LoginItemController
    @EnvironmentObject private var styleController: StyleController
    @Environment(\.cellarTheme) private var theme
    /// 摘要已复制的轻反馈（2s 后自动清除）。
    @State private var copied = false

    var body: some View {
        Form {
            LabeledContent(CellarL10n.s("settings.appVersion"), value: appVersion)

            LabeledContent(CellarL10n.s("settings.daemonVersion"), value: daemonVersionText)

            // 版本不匹配警示（既有 stale 语义复用：版本行 ≠ 期望值 → 提示重装）。
            if daemonMismatch {
                Text(CellarL10n.s("settings.versionMismatch"))
                    .font(.caption)
                    .foregroundStyle(theme.alert)
            }

            LabeledContent(CellarL10n.s("settings.connectionStatus"), value: connectionText)
            // 用户可见行用本地化展示名；原始存储值只进诊断摘要（排障需要）。
            LabeledContent(CellarL10n.s("settings.panelStyle"),
                           value: styleController.style == .amber
                               ? CellarL10n.s("settings.styleAmber")
                               : CellarL10n.s("settings.styleNative"))

            Button(copied ? CellarL10n.s("settings.copied") : CellarL10n.s("settings.copySummary")) { copyDiagnostics() }
        }
        .padding()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? CellarL10n.s("common.unknown")
    }

    private var daemonVersionText: String {
        statusController.daemonStatus?.version ?? CellarL10n.s("settings.unknownVersion")
    }

    /// daemon 版本与内嵌期望值不一致（首查前不判定，防初始化期误报）。
    private var daemonMismatch: Bool {
        guard let version = statusController.daemonStatus?.version else { return false }
        return version != DaemonXPC.daemonVersion
    }

    private var connectionText: String {
        switch statusController.connection {
        case .connected: return CellarL10n.s("settings.connected")
        case .unreachable: return CellarL10n.s("settings.unreachable")
        case .unknown: return CellarL10n.s("common.unknown")
        }
    }

    /// 诊断摘要贴剪贴板（NSPasteboard；注册态经控制器投影，不走 SMAppService——
    /// View 不直呼系统服务，评审 P2-2 同款纪律）。摘要为排障用途，版本号等
    /// 原始值保留（约等号语义），行文经 CellarL10n 本地化。
    private func copyDiagnostics() {
        let registration: String = {
            switch loginItems.registration {
            case .enabled: return CellarL10n.s("settings.regEnabled")
            case .requiresApproval: return CellarL10n.s("about.regApproval")
            case .notRegistered: return CellarL10n.s("common.notRegistered")
            case .unknown: return CellarL10n.s("about.regUnknown")
            }
        }()
        let daemonStatusText = daemonMismatch
            ? CellarL10n.s("about.mismatch", DaemonXPC.daemonVersion)
            : CellarL10n.s("about.match")
        let summary = [
            CellarL10n.s("about.appVersionLine", appVersion),
            CellarL10n.s("about.daemonLine", daemonVersionText, daemonStatusText),
            CellarL10n.s("about.loginItemLine", registration),
            CellarL10n.s("about.connectionLine", connectionText),
            CellarL10n.s("about.styleLine", styleController.style.rawValue),
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
