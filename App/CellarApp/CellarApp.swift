import CellarCore
import CellarUI
import Sparkle
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
    // 0.23.16 B8-1：StatusController 单例化（StatusController.shared，构造私有化
    // ——NotificationService.shared B1-3 先例形态）。动机：NSStatusItem 宿主
    //（StatusItemController，AppKit 域）需要 App-observable 无关的稳定引用，绕开
    // @StateObject init 临时实例陷阱（0.23.6 deinit 尸体链教训）；观察语义不变
    // ——@EnvironmentObject 消费方观察对象本身，单例 App 常驻 = 生命周期等价。
    // 视图消费面（@EnvironmentObject）零改动，仅注入源换 .shared。
    @StateObject private var loginItems = LoginItemController(store: CellarApp.sharedConfigStore)
    // WP5：暂存步属主（引导进度视图重建不丢；与 WP4 三控制器同构）。
    @StateObject private var onboarding = OnboardingController(store: CellarApp.sharedConfigStore)
    // WP3 §3.3：面板风格控制器——启动异步 load 持久化偏好，@Published style 驱动
    // ThemeProvider 全树重算（加载完成前呈现 .native，闪变已登记为已知态）。
    @StateObject private var styleController = StyleController(store: CellarApp.sharedConfigStore)
    // v1.11 M2 T2：显示设置控制器（AppConfig 第四写者；自 MenuBarSettingsController
    // 改名扩位——menuBarPercentageVisible / menuBarBatteryIconVisible 双字段统一宿主）
    // ——load 在自身 init 自标定（App.init 早期访问 @StateObject 临时实例陷阱，
    // StyleController 同款）；菜单栏图标（StatusItemIconRoot，0.23.16 B8 自
    // MenuBarExtra label 闭包迁形态）+ 面板页脚 Toggle + 主窗口通用页 Toggle
    // 多消费源。
    @StateObject private var displaySettings = DisplaySettingsController(store: CellarApp.sharedConfigStore)
    /// 0.18 T5 D-5a：CPU 表面温度/双风扇采样器（panelVisible 门控经
    /// StatusController.setPanelVisible 转发——弱引用回填点在 PanelView.panelAppeared；
    /// @Published 直注 PanelView，不经 statusController 传播的 MenuBarIconLabel 教训）。
    @StateObject private var cpuFanMonitor = CpuFanMonitor()
    // 0.23.16 B8-1（全仓首个 AppDelegate）：didFinishLaunching 组装 StatusItem
    // shell（图标启动即出现；六对象内容由下方 Window 内容 onAppear 锚点注入
    // StatusItemController.shared.wire——@StateObject 真身安全传递点）。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // WP5 通知服务（0.23.6 B1-3）：`private let notifications` 存储属性退役——
    // NotificationService 单例化（NotificationService.shared，构造私有化），通知
    // 接线迁入各控制器 init 自标定（见 init 内登记注释）。
    /// 0.23.3 §1.4 Sparkle 更新控制器（自研 UpdateChecker 0.23.3 退役）：**普通
    /// 存储属性，非 ObservableObject**（常规 P2——Sparkle 标准更新窗为独立 UI 面，
    /// App 视图树零观察需求；普通属性在 App.init 可安全访问，@StateObject 临时
    /// 实例陷阱不适用）。startingUpdater: true = 启动即调度（每日自动检查在
    /// Sparkle 内部 scheduler）；About 页经 EnvironmentKey 消费 `.updater`
    ///（statsSampler 先例）。
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    /// Phase 5 v1.3 统计采样器：非可观察（视图不直接读），60s 常驻采样循环——
    /// 自标定在自身 init（@StateObject 早期访问陷阱：App.init 不触碰）。
    private let statsSampler = StatsSampler()

    init() {
        // 0.23.3 §1.4 Sparkle 启动语义：每日自动检查（automaticallyChecksForUpdates
        // = true）+ **不自动下载安装**（automaticallyDownloadsUpdates = false——
        // 「提示、由我决定」用户钉死语义；Info.plist SUAllowsAutomaticUpdates=false
        // 双保险，更新窗不出现自动下载复选框）。
        updaterController.updater.automaticallyChecksForUpdates = true
        updaterController.updater.automaticallyDownloadsUpdates = false
        // 0.23.3 §1.4：自研 UpdateChecker 遗留 UserDefaults 键一次性清理（节流戳
        // + 同版本去重戳——退役后成死键，启动即清）。
        UserDefaults.standard.removeObject(forKey: "com.cellar.update.lastCheckAt")
        UserDefaults.standard.removeObject(forKey: "com.cellar.update.lastNotifiedVersion")
        // WP5 硬事实 4：通知 delegate 必须在启动早期赋值——迟设错过首条
        // willPresent（前台呈现策略失效）。0.23.6 B1-3：改经进程级单例调用（赋值
        // 幂等）——App.init 仍是启动最早确定性时点，delegate 赋值锚点保留组合根。
        NotificationService.shared.installDelegate()
        // 0.23.6 B1-3：通知接线整体迁出组合根——onNotificationEvent /
        // onScheduleEvent / onSuppressionRecoveryOutcome 三闭包迁入
        // StatusController.init，onInstallSucceeded 迁入 OnboardingController.init
        // （迁移前 4 处闭包接线——既有登记注释「上方两处」系计数漂移，按迁移前
        // 实数在此修正）。动机：App.init 接线依赖「最后一次 init 运行=幸存实例」
        // 的未文档化时序（deinit 尸体链实证）不可靠；接线自标定于控制器 init =
        // 幸存实例诞生即自带（0.4.1 批 refreshCadence/loadCompletedFlag 同款已被
        // 真机验证的形态），时序依赖归零。outlet 本体保留（解耦与可覆写面不变）。
        // 0.23.3 §2：updateChecker.onUpdateAvailable 接线已随自研更新链退役删除
        //（新版发现改由 Sparkle 更新窗承载——不再走系统通知）。
        // WP3：风格加载在 StyleController.init 内自启动。
    }

    var body: some Scene {
        // 0.23.16 B8-1：MenuBarExtra `.window` 场景整体退役（方案 B——NSStatusItem
        // 迁移，§2.1 spike 定版）。0.19.11 isInserted 地雷与 `.window` 求值延迟
        // 症状随场景删除自然消解；菜单栏图标/面板改由 StatusItemController 承载
        // （AppKit 域），PanelView / MenuBarIconLabel 本体零改动。
        // Phase 5 v1.2 §2.1 主窗口（macOS 13+ Window scene）：ThemeProvider 全树
        // 生效 + environmentObject 注入（缺任一将运行时 crash）。M3.5
        // 用户决策：**设置窗退役**——原 Settings scene 删除，设置内容并入侧栏
        // 路由（通用/外观/关于页，共享子视图随迁），本 scene 为唯一常驻窗口。
        // 默认 1080×720 / min 920×620（§2.1 工程裁定，与 mock 748 高度差异为
        // 浏览器留白）；仅带 .defaultSize——可调性由 windowResizability 默认值
        //（自由）保证。
        // ⚠️ **启动接线必须挂在本 scene 链尾**（P0-1 教训：接线挂在不打开的
        // scene 上是死代码——Settings scene 退役后迁入此处）。
        // 0.18.1 T5：窗口标题去除（`Window("")`）——toolbar 不再重复「芯仓」，
        // 侧栏 brandHeader 为唯一品牌区；App 名菜单/Dock 显示走 Info.plist
        // CFBundleName 不受影响；id 不变保路由。
        Window("", id: "main") {
            ThemeProvider(style: styleController.style) {
                MainWindowView()
                    .environmentObject(installer)
                    .environmentObject(StatusController.shared)
                    .environmentObject(loginItems)
                    .environmentObject(onboarding)
                    .environmentObject(styleController)
                    // v1.11 T2：显示设置控制器注入主窗口链（通用页电池图标 Toggle
                    // 的唯一数据源——缺注入运行时 crash，照五对象既有纪律）。
                    .environmentObject(displaySettings)
                    // 0.23.3 §1.4：Sparkle 更新器注入主窗口链（关于页「检查更新」
                    // 唯一入口——EnvironmentKey 可选缺省 nil，statsSampler 先例；
                    // 面板不消费，MenuBarExtra 链不注入）。
                    .environment(\.cellarUpdater, updaterController.updater)
                    // 0.22.0 §4.3：CPU/风扇采样器注入主窗口链（通用页风扇节 Tp00
                    // 参考温度行消费源——@EnvironmentObject 缺注入运行时 crash，
                    // 照 displaySettings 既有纪律；幸存实例 = 组合根同一 @StateObject）。
                    .environmentObject(cpuFanMonitor)
                    // v1.3 统计采样器注入：统计页查询经 StatsSampler actor 后台
                    // 执行（主线程零 SQLite，红线 4）——注入幸存实例，临时实例
                    // 靠采样循环 weak-self 复查自熄（StatsSampler 注记）。
                    .environment(\.statsSampler, statsSampler)
            }
            // 0.23.16 B8-1：StatusItem 内容装配锚点（唯一安全传递点）。五依赖
            // 仍为 @StateObject——App.init 早期访问 = 被丢弃的临时实例（0.23.6
            // 教训）；Window 内容闭包上下文 = 环境注入真身同域（上方
            // environmentObject 链实测真身），onAppear 在真身安装后触发。
            // 幂等；didFinishLaunching 先行时 shell 已在位（install 幂等），
            // wire 只补图标/面板内容。
            // ⚠️ 真机验证点：主窗口内容若不随启动具象化（LSUIElement 形态差异），
            // 图标将只有空 shell——图标含百分比文字随启动呈现 = wire 已触发。
            .onAppear {
                StatusItemController.shared.wire(
                    installer: installer,
                    loginItems: loginItems,
                    onboarding: onboarding,
                    displaySettings: displaySettings,
                    cpuFanMonitor: cpuFanMonitor,
                    styleController: styleController
                )
            }
        }
        .defaultSize(width: 1080, height: 720)
        // §2.8 启动接线：registration → StatusController（连接态语义判定依据）+
        // OnboardingController（收尾规则/安装接续，幂等）。
        .onChange(of: installer.registration) {
            StatusController.shared.registrationChanged(installer.registration)
            onboarding.registrationChanged(installer.registration)
        }
        // P1-3：loaded 置位（首次回包）时补一次引导判定——已注册用户启动瞬间
        // 引导不闪现；首回包与初值同注册值时 onChange(registration) 不触发。
        .onChange(of: installer.loaded) {
            onboarding.registrationChanged(installer.registration)
        }
    }
}

// 0.23.16 B8-1（全仓首个 AppDelegate）：NSStatusItem 迁移宿主锚点（§2.1 B 必验
// 面②）。职责单一——启动时装配 StatusItem shell（图标启动即出现）；NSStatusItem
// 的强引用由 StatusItemController.shared 进程生存期持有，本 delegate 不持有状态。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusItemController.shared.install()
    }
}
