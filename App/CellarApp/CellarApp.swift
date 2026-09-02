import CellarCore
import CellarUI
import SwiftUI

@main
struct CellarApp: App {
    // WP3 §3.1（评审 P0-1）：唯一 AppConfigStore 共享实例——风格/登录项/引导完成
    // 三写者共用，actor 原子 update() 读改写保证字段互不覆盖（控制器默认参数保留
    // 供测试单独注入）。
    private static let sharedConfigStore = AppConfigStore(url: AppConfigStore.defaultURL)
    // 组合根提升（规格 §2.8）：控制器常驻 App 层——面板视图重建不断供数据源；
    // App 启动即刷新注册态，图标新鲜度不依赖面板首开。
    @StateObject private var installer = DaemonInstaller()
    @StateObject private var statusController = StatusController()
    @StateObject private var loginItems = LoginItemController(store: CellarApp.sharedConfigStore)
    // WP5：暂存步属主（引导进度视图重建不丢；与 WP4 三控制器同构）。
    @StateObject private var onboarding = OnboardingController(store: CellarApp.sharedConfigStore)
    // WP3 §3.3：面板风格控制器——启动异步 load 持久化偏好，@Published style 驱动
    // ThemeProvider 全树重算（加载完成前呈现 .native，闪变已登记为已知态）。
    @StateObject private var styleController = StyleController(store: CellarApp.sharedConfigStore)
    /// WP5 通知服务：非可观察（视图不直接读），CellarApp 持有并接线。
    private let notifications = NotificationService()

    init() {
        // WP5 硬事实 4：通知 delegate 必须在启动早期赋值——迟设错过首条
        // willPresent（前台呈现策略失效）。
        notifications.installDelegate()
        // §2.3 单一入口接线：StatusController 事件出口 → NotificationService 投递。
        // WP2'：载荷附带 status.lastPercent（放电终态文案「当前电量 N%」组装）。
        statusController.onNotificationEvent = { [notifications] event, lastPercent in
            notifications.deliver(event, lastPercent: lastPercent)
        }
        // 引导安装成功（授权完成转 enabled）后请求一次通知授权（拒绝静默停用）。
        onboarding.onInstallSucceeded = { [notifications] in
            notifications.requestAuthorization()
        }
        onboarding.loadCompletedFlag()
        installer.refresh()
        // WP5 实例替换取证修复：statusController 的启动期自标定（后台轮询档 +
        // IOPS 图标即时化订阅）已移入 StatusController 自身 init——App.init 早期
        // 访问 @StateObject 拿到的是被 SwiftUI 丢弃的临时实例（deinit 尸体链实锤，
        // 见 StatusController.init 注释）；installer/onboarding 的 init 期调用经
        // 面板生命周期 re-trigger 兜底，观察期登记（不在此处改动）。
        // WP3：风格加载同理在 StyleController.init 内自启动。
    }

    var body: some Scene {
        MenuBarExtra {
            // WP3 §3.3：面板内容经 ThemeProvider 包裹——View 上下文取 colorScheme
            // 解析注入 cellarTheme（spike S2/S3 验证点 = 使用点）。
            ThemeProvider(style: styleController.style) {
                PanelView()
                    .environmentObject(installer)
                    .environmentObject(statusController)
                    .environmentObject(loginItems)
                    .environmentObject(onboarding)
            }
        } label: {
            MenuBarIconLabel(controller: statusController)
        }
        .menuBarExtraStyle(.window)
        // WP3 §4：设置窗口（spike S1 检查点）；注入五对象 = 四控制器 +
        // styleController，内容同经 ThemeProvider 包裹（与面板一致的主题链路）。
        Settings {
            ThemeProvider(style: styleController.style) {
                SettingsView()
                    .environmentObject(installer)
                    .environmentObject(statusController)
                    .environmentObject(loginItems)
                    .environmentObject(onboarding)
                    .environmentObject(styleController)
            }
        }
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
