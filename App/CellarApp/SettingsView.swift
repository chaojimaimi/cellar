import CellarCore
import SwiftUI
import UserNotifications

/// 设置窗口（WP3 §4 定版三 Tab：外观 / 通用 / 关于；形态 = spike S1 定版的
/// 原生 Settings scene——组合根声明 + 面板 SettingsLink 入口）。外观 Tab 独立
/// 文件；关于 Tab 的风格展示行同为风格词元（白名单成员），本文件整体属 G1 白名单。
struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceTab()
                .tabItem { Label("外观", systemImage: "paintpalette") }
            GeneralTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AboutTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 300)
    }
}

// MARK: - 通用 Tab（WP3 §4）：开机启动双入口（与面板同源）+ 登录项注册态/
// 重新注册 + 通知授权态（onAppear 直查系统，不经 NotificationService——非
// Observable 且组合根私有，评审 P2-2 定版；App 不自管通知开关，授权是系统域）。

private struct GeneralTab: View {
    @EnvironmentObject private var loginItems: LoginItemController
    @Environment(\.cellarTheme) private var theme
    /// 通知授权态（nil = 查询中；getNotificationSettings 异步回主线程刷新）。
    @State private var notificationAuthorized: Bool?

    var body: some View {
        Form {
            Toggle("开机启动 Cellar", isOn: Binding(
                get: { loginItems.launchAtLogin },
                set: { loginItems.toggle($0) }
            ))
            .disabled(loginItems.busy)

            LabeledContent("登录项注册态") {
                HStack {
                    Text(registrationText)
                    // 修复路径落控制器（评审 P2-2）；已注册态按钮无意义，禁用。
                    Button("重新注册") { loginItems.reregister() }
                        .disabled(loginItems.busy || loginItems.registration == .enabled)
                }
            }

            LabeledContent("通知") {
                HStack {
                    Text(notificationText)
                    Button("打开系统设置") { openNotificationSettings() }
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

    private var registrationText: String {
        switch loginItems.registration {
        case .enabled: return "已注册"
        case .requiresApproval: return "待批准（请在系统设置确认）"
        case .notRegistered: return "未注册"
        case .unknown: return "查询中…"
        }
    }

    private var notificationText: String {
        guard let authorized = notificationAuthorized else { return "查询中…" }
        return authorized ? "已授权" : "未授权"
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
            LabeledContent("应用版本", value: appVersion)

            LabeledContent("守护进程版本", value: daemonVersionText)

            // 版本不匹配警示（既有 stale 语义复用：版本行 ≠ 期望值 → 提示重装）。
            if daemonMismatch {
                Text("守护进程版本与应用期望不一致，请卸载后重新安装守护进程")
                    .font(.caption)
                    .foregroundStyle(theme.alert)
            }

            LabeledContent("连接状态", value: connectionText)
            // 用户可见行用中文展示名；原始存储值只进诊断摘要（排障需要）。
            LabeledContent("面板风格", value: styleController.style == .amber ? "酒窖琥珀" : "原生")

            Button(copied ? "已复制" : "复制诊断摘要") { copyDiagnostics() }
        }
        .padding()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    private var daemonVersionText: String {
        statusController.daemonStatus?.version ?? "未知（未连接）"
    }

    /// daemon 版本与内嵌期望值不一致（首查前不判定，防初始化期误报）。
    private var daemonMismatch: Bool {
        guard let version = statusController.daemonStatus?.version else { return false }
        return version != DaemonXPC.daemonVersion
    }

    private var connectionText: String {
        switch statusController.connection {
        case .connected: return "已连接"
        case .unreachable: return "失联"
        case .unknown: return "未知"
        }
    }

    /// 诊断摘要贴剪贴板（NSPasteboard；注册态经控制器投影，不走 SMAppService——
    /// View 不直呼系统服务，评审 P2-2 同款纪律）。
    private func copyDiagnostics() {
        let registration: String = {
            switch loginItems.registration {
            case .enabled: return "已注册"
            case .requiresApproval: return "待批准"
            case .notRegistered: return "未注册"
            case .unknown: return "未查询"
            }
        }()
        let daemonStatusText = daemonMismatch ? "不匹配（期望 \(DaemonXPC.daemonVersion)）" : "匹配"
        let summary = """
        App 版本：\(appVersion)
        守护进程版本：\(daemonVersionText)（\(daemonStatusText)）
        登录项注册态：\(registration)
        连接状态：\(connectionText)
        面板风格：\(styleController.style.rawValue)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
