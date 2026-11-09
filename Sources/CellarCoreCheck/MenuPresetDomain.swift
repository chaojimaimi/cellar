// CellarCoreCheck —— 0.23.16 B8「菜单栏图标快捷预设批」场景域（方案 §2.2/§2.3）
//
// 两面（照 AccessibilityDomain / ContrastDomain 先例）：
// - 菜单预设-1..7：MenuPresetModel 判定纯函数直测（六预设值/✓ 归属/禁用矩阵
//   四门逐项与叠加/nil 代理）——落点纪律钉死 CellarCore（CellarCoreCheck 唯一
//   依赖 ["CellarCore"]，模型落 CellarUI 则本域不可 import，模型即失效点）；
// - 菜单源钉-1..3：组装薄层源钉（StatusItemController 六注入逐项/ThemeProvider
//   双包裹/host 强引用/左右键分流/menu 复位/LimitPolicy 预检 + 面板零改动反钉
//   + 主窗口不做反钉 + catalog 新 key 双语直读）。
//
// 全部源文件读取（Data 注入仓库相对路径），零渲染、零进程。

import CellarCore
import Foundation

/// 0.23.16 B8 批菜单预设场景域入口（Main.main 调用）。
func runMenuPresetDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            check(false, "菜单预设-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    // ---- 菜单预设-1：六预设值与顺序 + 正常态恰一项选中（§2.2）----

    let normal = MenuPresetModel.items(upperLimit: 80, mode: "active", busy: false, actionActive: false)
    check(normal.map(\.value) == [60, 70, 75, 80, 90, 100]
              && normal.count == 6,
          "菜单预设-1", "六预设值与菜单顺序（60/70/75/80/90/100——90/75/100 菜单专属，§2.2）")
    check(normal.filter(\.isSelected).map(\.value) == [80]
              && normal.allSatisfy { $0.section == .quickLimit }
              && normal.allSatisfy(\.enabled),
          "菜单预设-1", "正常态：当前值 80 恰一项 ✓，全项 enabled，section 恒 quickLimit")

    // ---- 菜单预设-2：✓ 归属边界（nil 全 off / 非 nil 不等全 off）----

    let lost = MenuPresetModel.items(upperLimit: nil, mode: nil, busy: false, actionActive: false)
    check(lost.allSatisfy { !$0.isSelected },
          "菜单预设-2", "失联（双 nil）：零 ✓（upperLimit nil 不等任何预设）")
    let none90 = MenuPresetModel.items(upperLimit: 90, mode: "active", busy: false, actionActive: false)
    check(none90.filter(\.isSelected).map(\.value) == [90]
              && none90.first { $0.value == 60 }?.isSelected == false,
          "菜单预设-2", "✓ 归属恰一：仅当前上限 90 打 ✓，其余（60…100）全 off")

    // ---- 菜单预设-3：mode disabled 禁用矩阵（面板预设同族语义）----

    let disabled = MenuPresetModel.items(upperLimit: 60, mode: "disabled", busy: false, actionActive: false)
    check(disabled.allSatisfy { !$0.enabled },
          "菜单预设-3", "mode disabled：六项全禁用（ControlSectionView isModeDisabled 同族）")
    check(disabled.first { $0.value == 60 }?.isSelected == true,
          "菜单预设-3", "disabled ∧ 当前值 60：✓ 保留呈现（选中态与禁用态可并存）")

    // ---- 菜单预设-4：actionActive 禁用矩阵（一次性动作在轨）----

    let action = MenuPresetModel.items(upperLimit: 80, mode: "active", busy: false, actionActive: true)
    check(action.allSatisfy { !$0.enabled },
          "菜单预设-4", "actionActive：六项全禁用（面板预设同族 isActionActive）")

    // ---- 菜单预设-5：busy 禁用矩阵（有意新增门——勿对齐面板双条件）----

    let busy = MenuPresetModel.items(upperLimit: 80, mode: "active", busy: true, actionActive: false)
    check(busy.allSatisfy { !$0.enabled },
          "菜单预设-5", "busy：六项全禁用（菜单无防抖宿主 + latest-wins 覆盖风险，§2.2）")
    let busyStacked = MenuPresetModel.items(upperLimit: 70, mode: "disabled", busy: true, actionActive: true)
    check(busyStacked.first { $0.value == 70 }?.isSelected == true
              && busyStacked.allSatisfy { !$0.enabled },
          "菜单预设-5", "busy ∧ disabled ∧ action 叠加：全禁用 + 选中态保留（矩阵单调不翻绿）")

    // ---- 菜单预设-6：nil 代理矩阵（双 nil = 失联整区禁用；单 nil 混合为装配层
    // 不可达形态——模型按「非失联」判定，语义钉死防实现漂移）----

    let nilUpperOnly = MenuPresetModel.items(upperLimit: nil, mode: "active", busy: false, actionActive: false)
    check(nilUpperOnly.allSatisfy(\.enabled) && nilUpperOnly.allSatisfy { !$0.isSelected },
          "菜单预设-6", "单 nil（upper nil + mode 存在）：不失联——enabled 保留、零 ✓（装配层同源不可达，防御语义钉死）")
    let nilModeOnly = MenuPresetModel.items(upperLimit: 80, mode: nil, busy: false, actionActive: false)
    check(nilModeOnly.first { $0.value == 80 }?.isSelected == true,
          "菜单预设-6", "单 nil（mode nil + upper 存在）：80 ✓ 在位（同上——modeDisabled 判定对 nil 安全）")

    // ---- 菜单预设-7：四字段全矩阵口径复核（禁用门单调性：任一门开启即禁用）----

    let allValues = [60, 70, 75, 80, 90, 100]
    var gateMonotonic = true
    for value in allValues {
        let gates: [(busy: Bool, actionActive: Bool, mode: String?, upper: Int?)] = [
            (false, false, "active", value),   // 基准 enabled
            (true, false, "active", value), (false, true, "active", value),
            (false, false, "disabled", value), (false, false, nil, nil),
        ]
        let results = gates.map { MenuPresetModel.items(upperLimit: $0.upper, mode: $0.mode, busy: $0.busy, actionActive: $0.actionActive).first { $0.value == value }! }
        // 单调性：基准 enabled，任一增益门（busy/action/disabled/失联）开启即禁用。
        if !(results[0].enabled && results.dropFirst().allSatisfy { !$0.enabled }) { gateMonotonic = false }
    }
    check(gateMonotonic,
          "菜单预设-7", "六值 × 五态矩阵：基准 enabled，busy/action/disabled/失联任一门开启即全禁用（单调无翻绿）")

    // ---- 菜单源钉-1：模型落点钉（CellarCore + 不带 title）+ 面板零改动反镜像 ----

    // 落点 = 仓库布局钉死（source() 读不到即红）：Sources/CellarCore/Control/ 下；
    // 模型不带 title——零 CellarL10n/CellarUI/CellarNumericFormat/String 格式化面
    //（title 生成移入 App 层组装薄层，方案 §2.3 第一轮 P1）。
    let modelSrc = source("Sources/CellarCore/Control/MenuPresetModel.swift")
    let modelImports = modelSrc.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("import ") }
    check(modelImports == ["import Foundation"],
          "菜单源钉-1", "MenuPresetModel 零 title 面（import 闭包恰 = Foundation——无 CellarUI/CellarL10n/formatter/UI 框架通路）")
    check(modelSrc.contains("public static let presetValues = [60, 70, 75, 80, 90, 100]")
              && modelSrc.contains("public static func items(")
              && modelSrc.contains("let linkLost = upperLimit == nil && mode == nil"),
          "菜单源钉-1", "模型纯函数面在位（presetValues 六值 + items 双 nil 失联代理）")

    // 面板零改动纪律（红线）：预设行 80/70/60 原样 + 面板预设禁用态无 busy 门
    //（菜单 busy 门为有意差异，勿「对齐」面板）。
    let controlSrc = source("App/CellarApp/ControlSectionView.swift")
    check(controlSrc.contains("ForEach([80, 70, 60], id: \\.self)")
              && controlSrc.contains(".disabled(isModeDisabled || isActionActive)"),
          "菜单源钉-1", "面板预设行零改动钉（80/70/60 三钮 + disabled 双条件无 busy——菜单 90/75/100 不镜像面板）")

    // ---- 菜单源钉-2：组装薄层六注入逐项 + ThemeProvider 双包裹 + 面板零改动 ----

    let statusItemSrc = source("App/CellarApp/StatusItemController.swift")
    let sixInjections = ["installer", "statusController", "loginItems", "onboarding",
                         "displaySettings", "cpuFanMonitor"]
        .map { ".environmentObject(\($0))" }
    check(sixInjections.allSatisfy { statusItemSrc.contains($0) },
          "菜单源钉-2", "popover 六对象注入逐项在位（\(sixInjections.joined(separator: " / "))——缺 displaySettings 即 crash）")
    check(statusItemSrc.components(separatedBy: "ThemeProvider(style: styleController.style)").count - 1 >= 2,
          "菜单源钉-2", "ThemeProvider 双包裹（图标 + 面板——面板视图消费 .cellarTheme，§2.1 B 必验面①）")
    // 原退役 MenuBarExtra 链 :87-97 即无 cellarUpdater/statsSampler（面板树零消费
    // ——About/Stats 页为主窗口专属）——popover 环境注入与其逐项等价（反钉缺席面）。
    check(!statusItemSrc.contains(#".environment(\.cellarUpdater"#)
              && !statusItemSrc.contains(#".environment(\.statsSampler"#),
          "菜单源钉-2", "popover 环境注入与原链等价（无 cellarUpdater/statsSampler 注入点——反钉缺席面）")
    // PanelView / MenuBarIconLabel 本体零改动（红线）：零 StatusItemController 依赖。
    let panelViewSrc = source("App/CellarApp/PanelView.swift")
    let iconLabelSrc = source("App/CellarApp/MenuBarIconLabel.swift")
    check(!panelViewSrc.contains("StatusItemController") && !iconLabelSrc.contains("StatusItemController")
              && iconLabelSrc.contains("@ObservedObject var controller: StatusController")
              && iconLabelSrc.contains("@ObservedObject var settings: DisplaySettingsController"),
          "菜单源钉-2", "PanelView / MenuBarIconLabel 零改动（无 StatusItemController 依赖；直注双观察形态原样）")

    // ---- 菜单源钉-3：宿主强引用 + 分流/复位 + 动作链 + 主窗口不做反钉 + 锚点 ----

    check(statusItemSrc.contains("private let statusItem = NSStatusBar.system.statusItem(withLength:")
              && statusItemSrc.contains("static let shared = StatusItemController()")
              && statusItemSrc.contains("popover.behavior = .transient"),
          "菜单源钉-3", "NSStatusItem 强引用宿主 + 单例 + popover .transient（§2.1 B 必验面②——无人强持即释放消失）")
    check(statusItemSrc.contains("button.sendAction(on: [.leftMouseUp, .rightMouseUp])")
              && statusItemSrc.contains("NSApp.currentEvent?.type == .rightMouseUp")
              && statusItemSrc.contains("func menuDidClose(_ menu: NSMenu)")
              && statusItemSrc.contains("statusItem.menu = nil")
              && statusItemSrc.contains("button.performClick(nil)"),
          "菜单源钉-3", "左右键分流在位（双事件 sendAction + currentEvent 判型 + menu 置位 performClick 弹出 + didClose 复位 nil）")
    check(statusItemSrc.contains("try LimitPolicy(upperLimit: sender.tag, hysteresis: hysteresis)")
              && statusItemSrc.contains("controller.daemonStatus?.hysteresis ?? 2")
              && statusItemSrc.contains("controller.applyLimits(upperLimit: sender.tag, hysteresis: hysteresis)")
              && statusItemSrc.contains("controller.reportLocalRejection("),
          "菜单源钉-3", "动作链在位（LimitPolicy 预检 → applyLimits 全链；hysteresis 取 daemon 真相 ?? 2 防御兜底；预检失败 reportLocalRejection 不上 XPC）")
    check(statusItemSrc.contains("NSApp.terminate(nil)")
              && !statusItemSrc.contains(#"@Environment(\.openWindow) private"#),
          "菜单源钉-3", "退出 = NSApp.terminate；主窗口不做（AppKit 域无 openWindow 通路——登记偏差，方案 §2.2）")
    let cellarAppSrc = source("App/CellarApp/CellarApp.swift")
    check(cellarAppSrc.contains("@NSApplicationDelegateAdaptor(AppDelegate.self)")
              && cellarAppSrc.contains("StatusItemController.shared.install()")
              && cellarAppSrc.contains("StatusItemController.shared.wire(")
              && cellarAppSrc.contains(".environmentObject(StatusController.shared)")
              && !cellarAppSrc.contains("MenuBarExtra {")
              && !cellarAppSrc.contains(".menuBarExtraStyle"),
          "菜单源钉-3", "CellarApp 锚点在位（Adaptor + didFinishLaunching install + Window 内容 onAppear wire + StatusController.shared 注入；MenuBarExtra 场景退役反钉）")

    // ---- catalog 新 key 双语直读（三 key 有意增量登记：479 → 482）----

    let catalogURL = repoRoot.appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")
    if let data = try? Data(contentsOf: catalogURL),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let strings = root["strings"] as? [String: Any] {
        let expectations: [String: (zh: String, en: String)] = [
            "panel.menu.presets": ("快速限充——设为固定上限（≠充满一次）", "Quick limit — set fixed cap (≠ charge to full once)"),
            "panel.menu.capPercent": ("上限 %lld%%", "Cap %lld%%"),
            "panel.menu.openPanel": ("打开面板", "Open Panel"),
        ]
        var allPresent = true
        for (key, expected) in expectations {
            func localized(_ locale: String) -> String? {
                if let entry = strings[key] as? [String: Any],
                   let localizations = entry["localizations"] as? [String: Any],
                   let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any] {
                    return unit["value"] as? String
                }
                return nil
            }
            if localized("zh-Hans") != expected.zh || localized("en") != expected.en {
                allPresent = false
            }
        }
        check(allPresent, "菜单源钉-3", "catalog 新 key 三项双语在位（presets/capPercent/openPanel——479 → 482 有意增量登记）")
    } else {
        check(false, "菜单源钉-3", "catalog 键结构缺席（双语源钉红）")
    }
}
