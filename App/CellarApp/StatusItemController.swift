import AppKit
import CellarCore
import CellarUI
import Combine
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
// - ⑤点击外部/ESC 收起面板（0.23.23 补登——B8 漏验项，.transient 在 LSUIElement
//   宿主单独设置不生效，真机实证后由 togglePopover 激活三连修复）；
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

    /// 左键面板宿主（.transient + 弹出时显式激活 App——点击外部/ESC/Cmd+Tab 收起
    /// 的前置条件：popover 窗口成为 key window。LSUIElement 下 .transient 单独
    /// 设置不生效，见 togglePopover 注记——0.23.23 补全，MenuBarExtra .window 原行为）。
    private let popover = NSPopover()

    /// 依赖组装标记（wire 幂等守卫——组装锚点见 DaemonInstaller didSet 自转发 +
    /// AppDelegate didFinishLaunching 双触发注记）。
    private var wired = false
    /// 右键菜单收起后的左键事件吞除窗（真机实证毛刺：menuDidClose 复位 menu=nil
    /// 后，performClick 返回路径上残留的 leftMouseUp 会再触发一次 statusItemClicked
    /// → 面板意外弹开。窗内左键一律吞掉；窗宽 0.35s 覆盖事件残留期）。
    private var swallowLeftClickUntil = Date.distantPast
    /// 图标内容双源订阅（daemonStatus 1Hz 快照 + 百分比显隐——内容变化即重挂
    /// button.image/title）。低电量阈值同源引用（MenuBarIconLabel 既有常量）。
    private var iconSink: AnyCancellable?
    private var visibilitySink: AnyCancellable?

    private override init() {
        super.init()
        // popover 常驻配置（内容控制器 wire 时挂——依赖六 shared 单例静态可达）。
        popover.behavior = .transient
    }

    // MARK: - 装配（shell 启动即渲染，内容 wire 补齐；wire 无参——六依赖全部
    // static shared 单例静态可达，@StateObject 临时实例陷阱归零）

    /// 状态项 shell + 内容装配（AppDelegate.applicationDidFinishLaunching 锚点，
    /// 另有 DaemonInstaller.registration/loaded didSet 自转发双触发——首个回包
    /// 即渲染，图标启动期可见；真机回归修复 2026-11-10：原 Window onAppear 锚点
    /// 在 LSUIElement 形态永不触发）。幂等。
    func install() {
        guard let button = statusItem.button else { return }
        button.target = self
        // 左右键分流（§2.1）：sendAction 双注册——action 内以 NSApp.currentEvent
        // 判型；右键路径借 statusItem.menu 原生弹出（performClick 触发时 menu 已
        // 置，系统弹菜单不重入 action）。
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        wire()
    }

    /// 图标 + 面板内容装配（幂等）。六依赖全部 static shared 单例静态可达
    ///（StatusController.shared + 五控制器同批单例化），装配无时序前提。
    func wire() {
        guard !wired else { return }
        wired = true
        installIconContent()
        installPopoverContent()
    }

    /// 图标内容：**button.image/title 系统管道**（0.23.16 真机回归定版——原
    /// NSHostingView 子视图形态两连败：①variableLength 自适应只询问 button cell，
    /// 约束子视图不参与 → 16pt 视口裁掉 45.5pt 内容（图标隐形）；②SwiftUI 模板
    /// 渲染跟随 NSHostingView effectiveAppearance（浅色=黑）而非状态栏管道恒白，
    /// 浅色外观 + 深色壁纸形态黑上加黑。button.image（isTemplate）走
    /// NSStatusBarButton cell 渲染 = 菜单栏明暗自适应系统管道，title 同理）。
    /// 双源订阅重挂：daemonStatus（电量/充电态/失联）+ 百分比显隐。
    private func installIconContent() {
        guard statusItem.button != nil else { return }
        iconSink = StatusController.shared.$daemonStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncIconAndTitle() }
        visibilitySink = DisplaySettingsController.shared.$menuBarBatteryIconVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncIconAndTitle() }
        syncIconAndTitle()
    }

    /// 图标 + 百分比标题同步（MenuPresetModel 同源判定输入；电池形态回退链 =
    /// CellarCore.menuBarBatteryForm 纯函数——MenuBarIconLabel.batteryForm 同源）。
    private func syncIconAndTitle() {
        guard let button = statusItem.button else { return }
        let controller = StatusController.shared
        let settings = DisplaySettingsController.shared

        // 失联告警态：⚠ 符号（模板自适应明暗；红 tint 在 button cell 模板管道
        // 不可用——登记降级，alert 形态语义由符号形状承载）。
        if controller.iconState == .alert {
            button.image = NSImage(systemSymbolName: resolvedAlertSymbol(),
                                   accessibilityDescription: CellarL10n.s("common.axMenuBarIcon"))
            button.title = settings.percentageVisible ? percentageTitle(controller) : ""
            return
        }

        // 电池位图形态（MenuBarBatteryIconRenderer——isTemplate = !low，
        // button cell 渲染自适应明暗；低电量红非模板实绘保留）。
        let battery = menuBarBatteryForm(
            snapshotPercent: controller.batterySnapshot?.percent,
            snapshotIsCharging: controller.batterySnapshot?.isCharging,
            snapshotExternalConnected: controller.batterySnapshot?.externalConnected,
            powerOverride: controller.powerOverride,
            daemonPercent: controller.daemonStatus?.lastPercent)
        if let battery {
            button.image = MenuBarBatteryIconRenderer.image(
                percent: battery.percent,
                charging: battery.charging,
                plugged: battery.plugged,
                low: battery.percent < MenuBarIconLabel.lowBatteryThresholdPercent)
        } else {
            // 电池形态缺席回退：iconState 符号（符号解析三级降级同源复刻——
            // MenuBarIconLabel.resolvedSymbol 私有，此处最小复刻）。
            let state = controller.iconState
            let primary = menuBarSymbolName(for: state)
            let fallback = menuBarSymbolFallbackName(for: state)
            button.image = NSImage(systemSymbolName: primary, accessibilityDescription: nil)
                .map { $0.isTemplate = true; return $0 }
                ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
                .map { $0.isTemplate = true; return $0 }
                ?? NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil)
        }
        button.title = percentageTitle(controller)
    }

    /// 百分比标题（MenuBarIconLabel.percentageText 同语义：开关开 ∧ lastPercent
    /// 非 nil；裸数字无单位）。nil/关 = 空 title（不占位）。
    private func percentageTitle(_ controller: StatusController) -> String {
        guard DisplaySettingsController.shared.percentageVisible,
              let percent = controller.daemonStatus?.lastPercent else { return "" }
        return "\(percent)"
    }

    /// 失联告警符号（运行时存在性三级降级——MenuBarIconLabel.resolvedSymbol 同款）。
    private func resolvedAlertSymbol() -> String {
        let state = MenuBarIconState.alert
        let primary = menuBarSymbolName(for: state)
        if NSImage(systemSymbolName: primary, accessibilityDescription: nil) != nil { return primary }
        let fallback = menuBarSymbolFallbackName(for: state)
        if NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil { return fallback }
        return "circle.dashed"
    }

    /// 面板内容：NSHostingController 承载 ThemeProvider + PanelView + **六对象
    /// 注入逐项**（与退役 MenuBarExtra 链 :87-97 逐项等价——cellarUpdater/
    /// statsSampler 原链即不注入：面板树零消费，About/Stats 页为主窗口专属）。
    private func installPopoverContent() {
        popover.contentViewController = NSHostingController(rootView: StatusItemPanelRoot())
    }

    // MARK: - 左右键分流

    @objc private func statusItemClicked() {
        // 残留左键吞除（毛刺修复）：右键菜单收起窗内的左键事件一律吞掉。
        if NSApp.currentEvent?.type == .leftMouseUp, Date() < swallowLeftClickUntil {
            return
        }
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
            // LSUIElement 应用点击状态项不激活 App → popover 窗口从不成为 key window，
            // .transient 的「点击外部收起」（挂宿主激活态/关键窗口流转）全程哑火
            //（0.23.16 B8 迁移真机回归，用户实证 2026-11-13：点其他应用面板不收）。
            // 显式激活三连——社区对「状态项 + NSPopover」宿主的标准解法：
            NSApp.activate()   // macOS 14+ 无参形态（deployment target 26.0 无兼容负担；无条件激活语义 = 旧 ignoringOtherApps:true）。本仓 PanelSections.swift:298 旧 deprecated 形态不沿袭——遗留清理登记后续批（R6）
            popover.contentViewController?.view.window?.makeKey()   // activate 后 AppKit 是否自动 key 化 popover 无契约——显式 makeKey 幂等兜底（R3）
        }
    }

    /// 右键：置 menu 后借 performClick 原生弹出（menu 已置 → 系统弹菜单、不重入
    /// action）；didClose 复位 nil——左键通路不受 menu 态干扰。
    private func openQuickMenu(button: NSStatusBarButton) {
        let menu = buildQuickMenu()   // 弹出即重建——防状态陈旧（§2.2 动态刷新条款）
        menu.delegate = self
        statusItem.menu = menu
        swallowLeftClickUntil = Date().addingTimeInterval(0.35)   // 残留左键吞除窗（见属性注记）
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

        // 0.23.18 §2.4：profile 区（预设区之后、开面板项之前）。profiles 空 →
        // **整区省略**（菜单形态对无 profile 用户零变化）；非空 → separator +
        // section header（panel.menu.profiles）+ 逐项（representedObject = id——
        // id 非 Int，preset 的 tag 通路不适用；state .on = activeMatch 读回派生
        // 命中 ✓）。**MenuPresetModel.Section 不扩 enum**（profile 项独立模型
        // MenuProfileModel 独立数组，不与六预设混列表——语义不同不合并；对调研
        // B4「扩 Section enum」建议的偏离，理由见 MenuProfileModel 文件头）。
        // 禁用矩阵在模型（status nil / busy / actionActive；mode disabled 不禁用
        // ——§2.3 同理由）。
        let profileItems = MenuProfileModel.items(
            profiles: ProfileController.shared.profiles,
            status: controller.daemonStatus,
            busy: controller.busy,
            actionActive: controller.action != nil
        )
        if !profileItems.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: CellarL10n.s("panel.menu.profiles")))
            for profileItem in profileItems {
                let item = NSMenuItem(
                    title: profileItem.name,
                    action: #selector(applyProfileClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = profileItem.id
                item.state = profileItem.isSelected ? .on : .off
                item.isEnabled = profileItem.enabled
                menu.addItem(item)
            }
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
        CellarTheme.resolve(style: StyleController.shared.style, scheme: .light).word(.quit)
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

    /// 方案切换（0.23.18 §2.4）：representedObject 取 id → payload → **LimitPolicy
    /// 式预检不适用**（整包下发无单值预检）→ 直接 ProfileController.shared.switchTo
    /// （三门/收敛守卫/失败停链全在编排器）。禁用矩阵（items enabled）已把
    /// status nil / busy / actionActive 拦在菜单层——此处 guard status/payload 为
    /// 防御兜底（非静默面在编排器入口三门）。
    @objc private func applyProfileClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let current = StatusController.shared.daemonStatus,
              let payload = ProfileController.shared.profiles.first(where: { $0.id == id })
        else { return }
        ProfileController.shared.switchTo(payload, current: current)
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

// MARK: - 面板内容根（AppKit ↔ SwiftUI 桥）

/// 面板内容根：六对象注入逐项（§2.1 B 必验面①——与退役 MenuBarExtra 链
/// :87-97 逐项等价；缺任一 @EnvironmentObject 即运行时 crash；单例化后全部
/// 静态可达，构造参数归零）。主题观察内移：@ObservedObject StyleController.shared
///（App body 不再观察控制器——主题切换重评由本根自持观察承接；图标走
/// button.image 模板管道不依赖主题）。
private struct StatusItemPanelRoot: View {
    @ObservedObject private var styleController = StyleController.shared

    var body: some View {
        ThemeProvider(style: styleController.style) {
            PanelView()
                .environmentObject(DaemonInstaller.shared)
                .environmentObject(StatusController.shared)
                .environmentObject(LoginItemController.shared)
                .environmentObject(OnboardingController.shared)
                .environmentObject(DisplaySettingsController.shared)
                .environmentObject(CpuFanMonitor.shared)
        }
    }
}
