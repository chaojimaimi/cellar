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
    // v1.11 M2 T2：显示设置控制器（AppConfig 第四写者；自 MenuBarSettingsController
    // 改名扩位——menuBarPercentageVisible / menuBarBatteryIconVisible 双字段统一宿主）
    // ——load 在自身 init 自标定（App.init 早期访问 @StateObject 临时实例陷阱，
    // StyleController 同款）；MenuBarExtra label 闭包 + 面板页脚 Toggle + 主窗口
    // 通用页 Toggle 多消费源。
    @StateObject private var displaySettings = DisplaySettingsController(store: CellarApp.sharedConfigStore)
    /// 0.18 T5 D-5a：CPU 表面温度/双风扇采样器（panelVisible 门控经
    /// StatusController.setPanelVisible 转发——弱引用回填点在 PanelView.panelAppeared；
    /// @Published 直注 PanelView，不经 statusController 传播的 MenuBarIconLabel 教训）。
    @StateObject private var cpuFanMonitor = CpuFanMonitor()
    /// WP5 通知服务：非可观察（视图不直接读），CellarApp 持有并接线。
    private let notifications = NotificationService()
    /// Phase 5 v1.3 统计采样器：非可观察（视图不直接读），60s 常驻采样循环——
    /// 自标定在自身 init（@StateObject 早期访问陷阱：App.init 不触碰）。
    private let statsSampler = StatsSampler()

    init() {
        // WP5 硬事实 4：通知 delegate 必须在启动早期赋值——迟设错过首条
        // willPresent（前台呈现策略失效）。
        notifications.installDelegate()
        // §2.3 单一入口接线：StatusController 事件出口 → NotificationService 投递。
        // WP2'：载荷附带 status.lastPercent（放电终态文案「当前电量 N%」组装）。
        statusController.onNotificationEvent = { [notifications] event, lastPercent in
            notifications.deliver(event, lastPercent: lastPercent)
        }
        // Phase 5 v1.6 日程边沿通知（UD-7）：不走 CellarNotificationEvent 映射的
        // 第二出口——deliverSchedule 直投（identifier 内嵌 epoch 豁免冷却）。
        statusController.onScheduleEvent = { [notifications] notification in
            notifications.deliverSchedule(notification)
        }
        // 引导安装成功（授权完成转 enabled）后请求一次通知授权（拒绝静默停用）。
        onboarding.onInstallSucceeded = { [notifications] in
            notifications.requestAuthorization()
        }
        // 0.4.1 批（观察期收尾）：installer/onboarding 的启动期调用已迁移进各自
        // init 自标定（StatusController/StyleController 同款模式）——App.init 早期
        // 访问 @StateObject 拿到的是被 SwiftUI 丢弃的临时实例（deinit 尸体链实锤），
        // 自标定保证幸存实例必然完成首次刷新/加载。已知残留：上方两处回调接线
        // 仍接线于临时实例且无 re-trigger 兜底（真机通知实证工作，登记不扩 scope）。
        // WP3：风格加载在 StyleController.init 内自启动。
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
                    .environmentObject(displaySettings)
                    // 0.18 T5：面板观察增强采样器注入（@Published 直注——缺注入
                    // 运行时 crash，照 displaySettings 既有纪律）。
                    .environmentObject(cpuFanMonitor)
            }
        } label: {
            // v1.10 M2：双观察源直注（StatusController 图标态 + DisplaySettingsController
            // 百分比显隐——更新传播见 MenuBarIconLabel 注记）。
            MenuBarIconLabel(controller: statusController, settings: displaySettings)
        }
        .menuBarExtraStyle(.window)
        // Phase 5 v1.2 §2.1 主窗口（macOS 13+ Window scene）：ThemeProvider 全树
        // 生效 + environmentObject 五对象注入（缺任一将运行时 crash）。M3.5
        // 用户决策：**设置窗退役**——原 Settings scene 删除，设置内容并入侧栏
        // 路由（通用/外观/关于页，共享子视图随迁），本 scene 为唯一常驻窗口。
        // 默认 1080×720 / min 920×620（§2.1 工程裁定，与 mock 748 高度差异为
        // 浏览器留白）；仅带 .defaultSize——可调性由 windowResizability 默认值
        //（自由）保证。
        // ⚠️ **启动接线必须挂在本 scene 链尾**（P0-1 教训：接线挂在不打开的
        // scene 上是死代码——Settings scene 退役后迁入此处；MenuBarExtra 链尾
        // 不重复接线，面板侧接线已随面板自身 onChange 保留）。
        Window(CellarL10n.s("main.window.title"), id: "main") {
            ThemeProvider(style: styleController.style) {
                MainWindowView()
                    .environmentObject(installer)
                    .environmentObject(statusController)
                    .environmentObject(loginItems)
                    .environmentObject(onboarding)
                    .environmentObject(styleController)
                    // v1.11 T2：显示设置控制器注入主窗口链（通用页电池图标 Toggle
                    // 的唯一数据源——缺注入运行时 crash，照五对象既有纪律）。
                    .environmentObject(displaySettings)
                    // v1.3 统计采样器注入：统计页查询经 StatsSampler actor 后台
                    // 执行（主线程零 SQLite，红线 4）——注入幸存实例，临时实例
                    // 靠采样循环 weak-self 复查自熄（StatsSampler 注记）。
                    .environment(\.statsSampler, statsSampler)
            }
        }
        .defaultSize(width: 1080, height: 720)
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
