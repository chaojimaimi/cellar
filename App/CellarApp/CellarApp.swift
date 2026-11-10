import CellarCore
import CellarUI
import Sparkle
import SwiftUI

@main
struct CellarApp: App {
    // 0.23.16 B8-1（全仓首个 AppDelegate）：didFinishLaunching 组装 StatusItem
    // shell + 内容（六依赖 static shared 静态可达——wire 无参，图标启动即渲染）。
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
        // StatusController.init，onInstallSucceeded 迁入 OnboardingController.init。
        // 0.23.16 B8：六控制器单例化（五 @StateObject 退役 → 各类 static shared，
        // B1-3 同款完成形态）——didFinishLaunching 组装不再依赖 @StateObject 真身
        // 时序（临时实例陷阱归零）。
        // WP3：风格加载在 StyleController.init 内自启动。
    }

    var body: some Scene {
        // 0.23.16 B8-1：MenuBarExtra `.window` 场景整体退役（方案 B——NSStatusItem
        // 迁移，§2.1 spike 定版）。0.19.11 isInserted 地雷与 `.window` 求值延迟
        // 症状随场景删除自然消解；菜单栏图标/面板改由 StatusItemController 承载
        // （AppKit 域），PanelView / MenuBarIconLabel 本体零改动。
        // Phase 5 v1.2 §2.1 主窗口（macOS 13+ Window scene）：主题观察内移
        // MainWindowView（@ObservedObject = StyleController.shared——0.23.16 B8
        // 单例化后 App body 不再观察控制器，主题切换重评由视图自持观察承接；
        // PanelView 侧同形态 = StatusItemPanelRoot）。environmentObject 注入
        // （缺任一将运行时 crash）。M3.5 用户决策：**设置窗退役**——原 Settings
        // scene 删除，设置内容并入侧栏路由（通用/外观/关于页，共享子视图随迁），
        // 本 scene 为唯一常驻窗口。默认 1080×720 / min 920×620（§2.1 工程裁定，
        // 与 mock 748 高度差异为浏览器留白）；仅带 .defaultSize——可调性由
        // windowResizability 默认值（自由）保证。
        // ⚠️ **0.23.16 B8 拆除注记**：原「启动接线挂本 scene 链尾」（P0-1）与
        // registration/loaded onChange（P1-3）随六控制器单例化退役——接线迁
        // DaemonInstaller didSet 自转发（赋值必经路径，零时序依赖；LSUIElement
        // 形态本 scene 内容永不具象化 = 原 onAppear/onChange 挂点全部死代码的
        // 真机实证 2026-11-10）。
        // 0.18.1 T5：窗口标题去除（`Window("")`）——toolbar 不再重复「芯仓」，
        // 侧栏 brandHeader 为唯一品牌区；App 名菜单/Dock 显示走 Info.plist
        // CFBundleName 不受影响；id 不变保路由。
        Window("", id: "main") {
            MainWindowView()
                .environmentObject(DaemonInstaller.shared)
                .environmentObject(StatusController.shared)
                .environmentObject(LoginItemController.shared)
                .environmentObject(OnboardingController.shared)
                .environmentObject(StyleController.shared)
                // v1.11 T2：显示设置控制器注入主窗口链（通用页电池图标 Toggle
                // 的唯一数据源——缺注入运行时 crash，照五对象既有纪律）。
                .environmentObject(DisplaySettingsController.shared)
                // 0.23.3 §1.4：Sparkle 更新器注入主窗口链（关于页「检查更新」
                // 唯一入口——EnvironmentKey 可选缺省 nil，statsSampler 先例）。
                .environment(\.cellarUpdater, updaterController.updater)
                // 0.22.0 §4.3：CPU/风扇采样器注入主窗口链（通用页风扇节 Tp00
                // 参考温度行消费源——@EnvironmentObject 缺注入运行时 crash，
                // 照 displaySettings 既有纪律；幸存实例 = static shared 同例）。
                .environmentObject(CpuFanMonitor.shared)
                // v1.3 统计采样器注入：统计页查询经 StatsSampler actor 后台
                // 执行（主线程零 SQLite，红线 4）——注入幸存实例，临时实例
                // 靠采样循环 weak-self 复查自熄（StatsSampler 注记）。
                .environment(\.statsSampler, statsSampler)
        }
        .defaultSize(width: 1080, height: 720)
    }
}

// 0.23.16 B8-1（全仓首个 AppDelegate）：NSStatusItem 迁移宿主锚点（§2.1 B 必验
// 面②）。职责：①逐一点火七控制器单例（各 init 自标定语义——refresh/load/观察
// 启动，与原 @StateObject 启动形态等价；无人首访则 static 惰性不启动 = 真机
// 实测回归形态）；②装配 StatusItem shell + 内容（图标启动即渲染）。
// NSStatusItem 的强引用由 StatusItemController.shared 进程生存期持有。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = DaemonInstaller.shared        // init 自标定 refresh → didSet 转发 wire
        _ = LoginItemController.shared
        _ = OnboardingController.shared
        _ = DisplaySettingsController.shared
        _ = StyleController.shared
        _ = CpuFanMonitor.shared
        _ = StatusController.shared
        StatusItemController.shared.install()
    }
}
