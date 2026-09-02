import SwiftUI

@main
struct CellarApp: App {
    // 组合根提升（规格 §2.8）：控制器常驻 App 层——面板视图重建不断供数据源；
    // App 启动即刷新注册态，图标新鲜度不依赖面板首开。
    @StateObject private var installer = DaemonInstaller()
    @StateObject private var statusController = StatusController()
    @StateObject private var loginItems = LoginItemController()
    // WP5：暂存步属主（引导进度视图重建不丢；与 WP4 三控制器同构）。
    @StateObject private var onboarding = OnboardingController()
    /// WP5 通知服务：非可观察（视图不直接读），CellarApp 持有并接线。
    private let notifications = NotificationService()

    init() {
        // WP5 硬事实 4：通知 delegate 必须在启动早期赋值——迟设错过首条
        // willPresent（前台呈现策略失效）。
        notifications.installDelegate()
        // §2.3 单一入口接线：StatusController 事件出口 → NotificationService 投递。
        statusController.onNotificationEvent = { [notifications] event in
            notifications.deliver(event)
        }
        // 引导安装成功（授权完成转 enabled）后请求一次通知授权（拒绝静默停用）。
        onboarding.onInstallSucceeded = { [notifications] in
            notifications.requestAuthorization()
        }
        onboarding.loadCompletedFlag()
        installer.refresh()
        // §2.8 启动即入 60s 图标新鲜度档（双路线解耦定版：轮询恒在、与注册态无关
        // ——不依赖面板首开；XPC 无应答快速失败，开销可忽略）。
        statusController.setPolling(panelVisible: false)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(installer)
                .environmentObject(statusController)
                .environmentObject(loginItems)
                .environmentObject(onboarding)
        } label: {
            MenuBarIconLabel(controller: statusController)
        }
        .menuBarExtraStyle(.window)
        // §2.8 启动接线：registration → StatusController（连接态语义判定依据）+
        // OnboardingController（收尾规则/安装接续，幂等）。
        .onChange(of: installer.registration) {
            statusController.registrationChanged(installer.registration)
            onboarding.registrationChanged(installer.registration)
        }
        // P1-3：loaded 置位（首次回包）时补一次引导判定——已注册用户启动瞬间
        // 引导不闪现；首回包与初值同注册值时 onChange(registration) 不触发。
        .onChange(of: installer.loaded) {
            onboarding.registrationChanged(installer.registration)
        }
    }
}
