import AppKit
import CellarCore
import CellarUI
import SwiftUI

// 0.23.16 B8-1 方案 B（§2.1 spike 定版）：MenuBarExtra `.window` 整体退役 →
// AppKit NSStatusItem + NSPopover。spike 实证 macOS 27 上 SwiftUI contextMenu
// 挂状态项不呈现（方案 A 证伪）——右键分流改由 AppKit 原生通路承载。
//
// ⚠️ 真机验证点（B 必验面④——代码层面不可预判，发版硬门由主代理执行）：
// - ①图标随状态刷新：NSHostingView 内 SwiftUI 观察（iconState/busy/percentage）
//   更新是否存活（0.23.9 机制在 popover/statusItem 宿主的复现面）；
// - ②popover 内 PanelView 布局：onGeometryChange 实测内容高机制（0.23.9 修复）
//   在 NSPopover 宿主的复现——塌缩/封顶滚动行为；
// - ③PanelFooterView 的 @Environment(\.openWindow) 在 NSPopover 宿主内可用性
//   （主窗口按钮——登记风险点，勿自行改造 PanelFooterView）；
// - ④图标渲染形态：variableLength 宽度自适应（含百分比文字）/模板着色/alert 红。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// 进程级单例（0.23.16 B8；照 0.23.6 B1-3 NotificationService.shared 先例）：
    /// NSStatusItem 宿主（AppKit 域）需要 App-observable 无关的稳定引用——绕开
    /// @StateObject init 临时实例陷阱（0.23.6 deinit 尸体链教训）。构造私有化，
    /// 唯一合法入口 = `shared`。
    static let shared = StatusItemController()

    /// 状态项强引用宿主（§2.1 B 必验面②）：NSStatusBar.system.statusItem 返回的
    /// NSStatusItem **无人强持即释放消失**——本类单例进程生存期持有，防图标蒸发。
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// 左键面板宿主（.transient = 点击外部自动收起——MenuBarExtra .window 原行为）。
    private let popover = NSPopover()

    /// 依赖组装标记（wire 幂等守卫——组装锚点见 CellarApp Window 内容 onAppear 注记）。
    private var wired = false

    // 六对象注入（§2.1 B 必验面①——逐项：缺 displaySettings 即 crash
    //〔MenuBarPercentageRow @EnvironmentObject〕；缺 cpuFanMonitor 同罪）。
    // statusController 固定取 StatusController.shared（单例化定版，无需传递）。
    private var installer: DaemonInstaller?
    private var loginItems: LoginItemController?
    private var onboarding: OnboardingController?
    private var displaySettings: DisplaySettingsController?
    private var cpuFanMonitor: CpuFanMonitor?
    private var styleController: StyleController?

    private override init() {
        super.init()
        // popover 常驻配置（内容控制器 wire 时挂——依赖五 @StateObject 组装锚点）。
        popover.behavior = .transient
    }

    // MARK: - 装配（两段式：shell 启动即渲染，内容经 wire 锚点注入）

    /// 状态项 shell 装配（AppDelegate.applicationDidFinishLaunching 锚点——图标
    /// 启动即出现；文字内容由 wire 补齐）。幂等：与 wire 无先后顺序约束
    ///（didFinishLaunching 与 Window 内容构建的相对时序未文档化，两段均幂等）。
    func install() {
        guard let button = statusItem.button else { return }
        button.target = self
        // 左右键分流（§2.1）：sendAction 双注册——action 内以 NSApp.currentEvent
        // 判型；右键路径借 statusItem.menu 原生弹出（performClick 触发时 menu 已
        // 置，系统弹菜单不重入 action）。
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 六对象注入 + 图标/面板内容装配（幂等）。
    ///
    /// ⚠️ 组装锚点 = CellarApp Window 内容 onAppear（唯一安全传递点）：五依赖仍
    /// 为 CellarApp @StateObject——App.init 早期访问拿到的是被 SwiftUI 丢弃的临时
    /// 实例（0.23.6 deinit 尸体链实锤）；Window 内容闭包上下文 = 环境注入真身
    /// 同域（:122 起 environmentObject 链实测真身，「幸存实例 = 组合根同一
    /// @StateObject」），onAppear 在真身安装后触发。didFinishLaunching 先行时
    /// shell 已在位（install 幂等），本方法只补内容。
    func wire(
        installer: DaemonInstaller,
        loginItems: LoginItemController,
        onboarding: OnboardingController,
        displaySettings: DisplaySettingsController,
        cpuFanMonitor: CpuFanMonitor,
        styleController: StyleController
    ) {
        guard !wired else { return }
        wired = true
        self.installer = installer
        self.loginItems = loginItems
        self.onboarding = onboarding
        self.displaySettings = displaySettings
        self.cpuFanMonitor = cpuFanMonitor
        self.styleController = styleController

        installIconContent()
        installPopoverContent()
    }

    /// 图标内容：NSHostingView 包 ThemeProvider + MenuBarIconLabel（**维持现有
    /// @ObservedObject 双直注形态**，勿改 environmentObject——v1.10 M2 定版）；
    /// 风格随 styleController 观察（StatusItemIconRoot）实时换肤。
    private func installIconContent() {
        guard let button = statusItem.button,
              let displaySettings, let styleController else { return }
        let iconView = NSHostingView(rootView: StatusItemIconRoot(
            styleController: styleController,
            controller: .shared,
            settings: displaySettings
        ))
        iconView.sizingOptions = [.intrinsicContentSize]   // variableLength：宽度随内容（百分比显隐）自适应
        iconView.translatesAutoresizingMaskIntoConstraints = false
        button.subviews.forEach { $0.removeFromSuperview() }
        button.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: button.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    /// 面板内容：NSHostingController 承载 ThemeProvider + PanelView + **六对象
    /// 注入逐项**（与退役 MenuBarExtra 链 :87-97 逐项等价——cellarUpdater/
    /// statsSampler 原链即不注入：面板树零消费，About/Stats 页为主窗口专属）。
    private func installPopoverContent() {
        guard let installer, let loginItems, let onboarding,
              let displaySettings, let cpuFanMonitor, let styleController else { return }
        popover.contentViewController = NSHostingController(rootView: StatusItemPanelRoot(
            styleController: styleController,
            installer: installer,
            statusController: .shared,
            loginItems: loginItems,
            onboarding: onboarding,
            displaySettings: displaySettings,
            cpuFanMonitor: cpuFanMonitor
        ))
    }

    // MARK: - 左右键分流

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        // 溢出区（«）形态：系统展开后点击仍走本 action（spike 实证——溢出项点击
        // = 直接触发 item 行为，无需特殊处理）。
        if NSApp.currentEvent?.type == .rightMouseUp {
            openQuickMenu(button: button)
        } else {
            togglePopover(of: button)
        }
    }

    /// 左键：toggle NSPopover（同「打开面板」菜单项——§2.2 左键不变条款）。
    private func togglePopover(of button: NSStatusBarButton) {
        guard popover.contentViewController != nil else { return }   // wire 前防御（启动竞态窗）
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    /// 右键：置 menu 后借 performClick 原生弹出（menu 已置 → 系统弹菜单、不重入
    /// action）；didClose 复位 nil——左键通路不受 menu 态干扰。
    private func openQuickMenu(button: NSStatusBarButton) {
        let menu = buildQuickMenu()   // 弹出即重建——防状态陈旧（§2.2 动态刷新条款）
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
    }

    // MARK: - 快捷菜单（§2.2）

    /// 组装薄层（不可直测面）：MenuPresetModel 判定 → title（CellarNumericFormat/
    /// catalog）→ NSMenu。**90/75/100 为菜单专属值不镜像面板**；当前值 stateMode
    /// .on（✓）；busy 门禁用有意保留（勿对齐面板双条件——理由见 MenuPresetModel）。
    private func buildQuickMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false   // isEnabled 手动接管——禁用矩阵按模型落

        // section header（含 100% 语义尾注——「设为固定上限 ≠ 充满一次」，§2.2）。
        menu.addItem(.sectionHeader(title: CellarL10n.s("panel.menu.presets")))

        let controller = StatusController.shared
        let presets = MenuPresetModel.items(
            upperLimit: controller.daemonStatus?.upperLimit,
            mode: controller.daemonStatus?.mode,
            busy: controller.busy,
            actionActive: controller.action != nil
        )
        for preset in presets {
            let item = NSMenuItem(
                title: presetTitle(preset.value),
                action: #selector(applyPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = preset.value
            item.state = preset.isSelected ? .on : .off
            item.isEnabled = preset.enabled
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(menuItem(title: CellarL10n.s("panel.menu.openPanel"), action: #selector(openPanelClicked)))
        menu.addItem(menuItem(title: quitWord, action: #selector(quitClicked)))
        return menu
    }

    /// 预设项 title：100% 用「上限 N%」词形与 fullOnce 动词区分（§2.2 语义边界），
    /// 其余走 NumberFormatter percent 通路（B7-3 单一出口纪律）。
    private func presetTitle(_ value: Int) -> String {
        value == 100 ? CellarL10n.s("panel.menu.capPercent", value) : CellarNumericFormat.percent(value)
    }

    /// 通用菜单项（target/action 接线）。
    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    /// 退出词：theme.word(.quit) 既有通路——resolve 产 theme 后取词（语汇只随
    /// style，scheme 入参为 resolve 签名必填、取词无关，任取 .light 并在此注记）。
    private var quitWord: String {
        CellarTheme.resolve(style: styleController?.style ?? .native, scheme: .light).word(.quit)
    }

    // MARK: - 菜单动作（全部 @MainActor——类隔离即保证）

    /// 预设设值：LimitPolicy 预检（照面板视图先例——60 地板红线一致防御，不省）
    /// → applyLimits 全链（runControl 单槽队列承载连点）。hysteresis 取 daemon
    /// 真相（面板预设同语义）；`?? 2` 兜底在整区禁用门下不可达，防御性保留（§2.2）。
    @objc private func applyPreset(_ sender: NSMenuItem) {
        let controller = StatusController.shared
        let hysteresis = controller.daemonStatus?.hysteresis ?? 2
        do {
            _ = try LimitPolicy(upperLimit: sender.tag, hysteresis: hysteresis)
        } catch {
            // 预检失败不上 XPC，照面板原样上屏（不静默——面板横幅通道，§2.3）。
            controller.reportLocalRejection(CellarL10n.s("common.parameterInvalid", String(describing: error)))
            return
        }
        controller.applyLimits(upperLimit: sender.tag, hysteresis: hysteresis)
    }

    /// 打开面板 = togglePopover（同左键）。
    @objc private func openPanelClicked() {
        guard let button = statusItem.button else { return }
        togglePopover(of: button)
    }

    /// 退出（PanelFooterView 同款 NSApp.terminate 通路）。
    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    /// 菜单收起复位：statusItem.menu = nil——左键 togglePopover 通路恢复
    ///（menu 态残留会吞点击）。此为右键形态的生命周期闭环点。
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}

// MARK: - SwiftUI 内容根（AppKit ↔ SwiftUI 桥）

/// 图标内容根：观察 styleController（换肤重评 ThemeProvider）；MenuBarIconLabel
/// 自身维持 @ObservedObject 直注（本处仅传引用，双观察形态不变）。
private struct StatusItemIconRoot: View {
    @ObservedObject var styleController: StyleController
    @ObservedObject var controller: StatusController
    @ObservedObject var settings: DisplaySettingsController

    var body: some View {
        ThemeProvider(style: styleController.style) {
            MenuBarIconLabel(controller: controller, settings: settings)
        }
    }
}

/// 面板内容根：六对象注入逐项（§2.1 B 必验面①——与退役 MenuBarExtra 链
/// :87-97 逐项等价；缺任一 @EnvironmentObject 即运行时 crash）。
private struct StatusItemPanelRoot: View {
    @ObservedObject var styleController: StyleController
    let installer: DaemonInstaller
    let statusController: StatusController
    let loginItems: LoginItemController
    let onboarding: OnboardingController
    let displaySettings: DisplaySettingsController
    let cpuFanMonitor: CpuFanMonitor

    var body: some View {
        ThemeProvider(style: styleController.style) {
            PanelView()
                .environmentObject(installer)
                .environmentObject(statusController)
                .environmentObject(loginItems)
                .environmentObject(onboarding)
                .environmentObject(displaySettings)
                .environmentObject(cpuFanMonitor)
        }
    }
}
