// CellarCoreCheck —— 0.23.15「B7 打磨批」对比度矩阵 + 字面量源钉场景域（方案 §2.2/§2.3/§5.2）
//
// 两组一文件（照 FullChargeAutoRestoreDomain 三组同文件先例）：
// - 对比度-1..6：WCAG 2.x 相对亮度/比值纯函数 + §2.2 钉表全组合 ≥4.5:1 断言 +
//   横幅双背景口径（hysteresis 有 warning@0.12 tint 背景 → vs tint；degraded 无
//   背景字直接画面板底 → vs panel 名义实色——第一轮 P2 修正口径）+ hex 钉值防
//   漂移 + native 去 transparent 源钉 + 横幅字色 (style, scheme) 消费链源钉；
// - 字面量-1..4：B7-3 百分号 formatter 通路 / 单位 key 通路 / "--"→common.nodata /
//   °C 带空格统一 / LocalizedStringKey 插值绕过反钉（CellarL10n.swift:5-9 注释
//   警告形态）——渲染面文本格式源钉。
//
// 全部源文件读取（Data 注入仓库相对路径），零渲染、零进程；比值计算纯函数直测。

import CellarCore
import Foundation

// MARK: - WCAG 2.x 纯函数（场景域内独立实现——第二双眼睛纪律，不引 UI 依赖）

/// sRGB hex → WCAG 相对亮度（IEC 亮度系数 0.2126/0.7152/0.0722 + 伽马展开）。
func wcagRelativeLuminance(hex: UInt32) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    let r = channel(Double((hex >> 16) & 0xFF) / 255)
    let g = channel(Double((hex >> 8) & 0xFF) / 255)
    let b = channel(Double(hex & 0xFF) / 255)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// 对比度比值 = (L亮 + 0.05) / (L暗 + 0.05)（WCAG 2.x 文本线 AA ≥4.5:1）。
func wcagContrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
    let la = wcagRelativeLuminance(hex: a)
    let lb = wcagRelativeLuminance(hex: b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

/// 警示 tint 合成色：warning @ 0.12 alpha 叠面板名义实色（hysteresis 横幅
/// Capsule 背景的逐通道 alpha 合成——Sub80StatusView `.background(theme.warning
/// .opacity(0.12))` 的实底近似）。
func warningTintComposite(warning: UInt32, panel: UInt32) -> UInt32 {
    let alpha = 0.12
    func mix(_ wa: Int, _ pa: Int) -> UInt32 {
        UInt32((Double(wa) * alpha + Double(pa) * (1 - alpha)).rounded())
    }
    return mix(Int((warning >> 16) & 0xFF), Int((panel >> 16) & 0xFF)) << 16
        | mix(Int((warning >> 8) & 0xFF), Int((panel >> 8) & 0xFF)) << 8
        | mix(Int(warning & 0xFF), Int(panel & 0xFF))
}

/// 0.23.15 B7 批对比度 + 字面量场景域入口（Main.main 调用）。
func runContrastDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            check(false, "对比度-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    let themeSrc = source("Sources/CellarUI/Theme.swift")
    let supportSrc = source("Sources/CellarUI/ThemeSupport.swift")
    let sub80Src = source("Sources/CellarUI/Sub80StatusView.swift")
    let uicheckSrc = source("Sources/CellarUICheck/main.swift")

    // ---- 对比度-1：WCAG 公式自洽（方案 §1.2 实测锚哨兵——公式实现错误即红）----

    check(abs(wcagContrastRatio(0x69451E, warningTintComposite(warning: 0xC98A45, panel: 0xFFFDF8)) - 7.48) < 0.05
              && abs(wcagContrastRatio(0x69451E, 0xFFFDF8) - 8.36) < 0.05,
          "对比度-1", "公式对照实测锚：#69451E vs amberLight tint ≈7.48:1 / vs panel ≈8.36:1（方案 §1.2 钉值）")
    check(abs(wcagContrastRatio(0x7B4C1D, warningTintComposite(warning: 0xB8722C, panel: 0xF3F5F4)) - 5.81) < 0.05
              && abs(wcagContrastRatio(0x7B4C1D, 0xF3F5F4) - 6.63) < 0.05,
          "对比度-1", "公式对照实测锚：#7B4C1D vs industrialLight tint ≈5.81:1 / vs panel ≈6.63:1（方案 §1.2 钉值）")

    // ---- 对比度-2：tertiaryText 四主题实色钉表 vs panel ≥4.5:1（§2.2 钉表）----

    let tertiaries: [(theme: String, fg: UInt32, panel: UInt32, expected: Double)] = [
        ("amberLight", 0x635849, 0xFFFDF8, 6.83),
        ("amberDark", 0x998770, 0x211A13, 4.95),
        ("industrialLight", 0x5F6972, 0xF3F5F4, 5.11),
        ("industrialDark", 0x88949B, 0x1B1F23, 5.33),
    ]
    for entry in tertiaries {
        let ratio = wcagContrastRatio(entry.fg, entry.panel)
        check(ratio >= 4.5 && abs(ratio - entry.expected) < 0.05,
              "对比度-2", "tertiaryText \(entry.theme) vs 面板名义实色 \(String(format: "%.2f", ratio)):1 ≥4.5:1（钉值达标且与方案钉表一致）")
    }

    // ---- 对比度-3：secondaryText 四主题 vs panel ≥4.5:1（amberLight 新钉 +
    //      其余三主题既有值回归锚——方案 §2.2「其余三主题不动」）----

    let secondaries: [(theme: String, fg: UInt32, panel: UInt32, expected: Double)] = [
        ("amberLight", 0x5C5144, 0xFFFDF8, 7.61),
        ("amberDark", 0xA08D74, 0x211A13, 5.37),
        ("industrialLight", 0x55606A, 0xF3F5F4, 5.87),
        ("industrialDark", 0x98A4AC, 0x1B1F23, 6.51),
    ]
    for entry in secondaries {
        let ratio = wcagContrastRatio(entry.fg, entry.panel)
        check(ratio >= 4.5 && abs(ratio - entry.expected) < 0.05,
              "对比度-3", "secondaryText \(entry.theme) vs 面板名义实色 \(String(format: "%.2f", ratio)):1 ≥4.5:1")
    }

    // ---- 对比度-4：横幅字色双口径 ≥4.5:1（消费色 = 两浅色新钉 / 两暗主题
    //      warning；hysteresis vs tint 合成 / degraded vs panel——两横幅各两口径）----

    let banners: [(theme: String, text: UInt32, warning: UInt32, panel: UInt32, vsTint: Double, vsPanel: Double)] = [
        ("amberLight", 0x69451E, 0xC98A45, 0xFFFDF8, 7.48, 8.36),
        ("amberDark", 0xEAB765, 0xEAB765, 0x211A13, 7.31, 9.38),
        ("industrialLight", 0x7B4C1D, 0xB8722C, 0xF3F5F4, 5.81, 6.63),
        ("industrialDark", 0xD99A4E, 0xD99A4E, 0x1B1F23, 5.58, 6.85),
    ]
    for entry in banners {
        let tintRatio = wcagContrastRatio(entry.text, warningTintComposite(warning: entry.warning, panel: entry.panel))
        let panelRatio = wcagContrastRatio(entry.text, entry.panel)
        check(tintRatio >= 4.5 && abs(tintRatio - entry.vsTint) < 0.05,
              "对比度-4", "横幅字色 \(entry.theme) vs tint（hysteresis 形态）\(String(format: "%.2f", tintRatio)):1 ≥4.5:1")
        check(panelRatio >= 4.5 && abs(panelRatio - entry.vsPanel) < 0.05,
              "对比度-4", "横幅字色 \(entry.theme) vs panel 名义实色（degraded 形态）\(String(format: "%.2f", panelRatio)):1 ≥4.5:1")
    }

    // ---- 对比度-5：hex 钉值防漂移 + 旧透明形态反钉 + native 去 transparent 源钉----

    let pinnedHexes = ["0x635849", "0x998770", "0x5F6972", "0x88949B",
                       "0x5C5144", "0x69451E", "0x7B4C1D"]
    let missingHexes = pinnedHexes.filter { !themeSrc.contains($0) }
    check(missingHexes.isEmpty,
          "对比度-5", "七钉值 hex 字面量在位（tertiary×4 + amberLight secondary + 横幅字色×2——防漂移源钉；缺席：\(missingHexes)）")
    check(!themeSrc.contains("tertiaryText: Color(hex: 0x8A7A66).opacity(0.6)")
              && !themeSrc.contains("tertiaryText: Color(hex: 0xA08D74).opacity(0.6)")
              && !themeSrc.contains("tertiaryText: Color(hex: 0x55606A).opacity(0.6)")
              && !themeSrc.contains("tertiaryText: Color(hex: 0x98A4AC).opacity(0.6)")
              && !themeSrc.contains("Color.secondary.opacity(0.6)"),
          "对比度-5", "旧透明形态反钉（tertiary base@0.6 四主题 + native Color.secondary.opacity(0.6) 全数清零）")
    check(themeSrc.contains("tertiaryText: .secondary"),
          "对比度-5", "native tertiary 去 transparent 源钉（.secondary 系统管理—— tertiary 行无 @0.6 残留）")
    check(themeSrc.contains("secondaryText: Color(hex: 0x5C5144)")
              && themeSrc.contains("tertiaryText: Color(hex: 0x635849)")
              && themeSrc.contains("tertiaryText: Color(hex: 0x998770)")
              && themeSrc.contains("tertiaryText: Color(hex: 0x5F6972)")
              && themeSrc.contains("tertiaryText: Color(hex: 0x88949B)"),
          "对比度-5", "token 定义行钉值在位（secondary amberLight + tertiary 四主题实色形态）")

    // ---- 对比度-6：横幅字色 (style, scheme) 消费链源钉（方案 §2.2 实现形态）----

    check(themeSrc.contains("static func bannerTextColor(style: PanelStyle, scheme: ColorScheme) -> Color"),
          "对比度-6", "bannerTextColor (style, scheme) 二元签名在位（resolve(style:scheme:) 先例——CellarTheme resolve 后值无 style/scheme 字段）")
    check(sub80Src.components(separatedBy: "CellarTheme.bannerTextColor(style: cellarStyle, scheme: colorScheme)").count - 1 == 2,
          "对比度-6", "Sub80StatusView 两横幅（degraded/hysteresis）各一消费点直调静态函数（恰两处——不从 CellarTheme 反推）")
    check(!sub80Src.contains(".foregroundStyle(theme.warning)"),
          "对比度-6", "横幅 theme.warning 直消费清零（字色全部走钉表函数——dark 主题经函数内 warning 分支维持）")
    check(supportSrc.contains(#".environment(\.cellarStyle, style)"#)
              && supportSrc.contains("var cellarStyle: PanelStyle"),
          "对比度-6", "cellarStyle environment 键 + ThemeProvider 注入在位（横幅字色选色信号携带 style）")
    check(uicheckSrc.contains(#".environment(\.cellarStyle, style)"#),
          "对比度-6", "CellarUICheck wrap 同点注入（快照消费面与生产 ThemeProvider 同形）")

    // ---- 字面量-1：CellarNumericFormat 通路在位（B7-3 §2.3 先例照 groupedFormatter）----

    let formatSrc = source("Sources/CellarUI/CellarNumericFormat.swift")
    check(formatSrc.contains("@MainActor")
              && formatSrc.contains("public static func percent(_ value: Int) -> String")
              && formatSrc.contains("public static func grouped(_ value: Int) -> String")
              && formatSrc.contains("formatter.numberStyle = .percent")
              && formatSrc.contains("formatter.numberStyle = .decimal"),
          "字面量-1", "CellarNumericFormat percent/grouped 双通路在位（缓存实例 + @MainActor 隔离——groupedFormatter 先例）")

    // ---- 字面量-2：百分号 formatter 消费 + "--"→common.nodata 占位源钉----

    let panelSectionsSrc = source("App/CellarApp/PanelSections.swift")
    let calibrationSrc = source("Sources/CellarUI/CalibrationSectionView.swift")
    let controlSrc = source("App/CellarApp/ControlSectionView.swift")
    let onboardingSrc = source("App/CellarApp/OnboardingView.swift")
    let statusLineSrc = source("Sources/CellarUI/StatusLineView.swift")
    let fanSrc = source("Sources/CellarUI/FanSectionView.swift")
    let gaugeSrc = source("Sources/CellarUI/GaugeView.swift")
    // 0.23.16 B8-2：B7 评审 P3-1 登记的手拼 "%" 残留面（PowerFlowDiagramNodes）
    // 一并纳入反钉覆盖——源钉缺口随批闭。
    let powerFlowNodesSrc = source("Sources/CellarUI/PowerFlowDiagramNodes.swift")

    check(panelSectionsSrc.contains("CellarNumericFormat.percent($0)")
              && panelSectionsSrc.components(separatedBy: "CellarL10n.s(\"common.nodata\")").count - 1 >= 2
              && !panelSectionsSrc.contains("?? \"--\""),
          "字面量-2", "放电进度行百分号 formatter + 「--」占位换 common.nodata（PanelSections:130-137 两占位全换）")
    check(calibrationSrc.contains("CellarNumericFormat.percent(percent)"),
          "字面量-2", "校准 running 行百分号 formatter（CalibrationSectionView:131）")
    check(controlSrc.components(separatedBy: "CellarNumericFormat.percent(").count - 1 >= 2
              && onboardingSrc.components(separatedBy: "CellarNumericFormat.percent(").count - 1 >= 2,
          "字面量-2", "预设钮 + 上限行百分号 formatter（ControlSectionView:51/68 + OnboardingView:304/316 各两处）")
    check(statusLineSrc.contains("CellarNumericFormat.percent(health)")
              && statusLineSrc.contains("CellarNumericFormat.grouped(snapshot.cycleCount)"),
          "字面量-2", "循环·健康段数值 formatter 双通路（StatusLineView:185——分组整数 + 百分数）")
    check(fanSrc.contains("CellarNumericFormat.percent(Int(speedPercent))")
              && fanSrc.contains("CellarNumericFormat.percent(Int(stage2Percent))"),
          "字面量-2", "风扇速度/二级百分号 formatter（FanSectionView:459/476——percent 通路归类修正照方案 §2.3-3）")
    check(gaugeSrc.contains("CellarL10n.s(\"common.nodata\")")
              && !gaugeSrc.contains("?? \"--\""),
          "字面量-2", "GaugeView 中心占位 common.nodata（:155 同步——「--」手拼形态清零）")
    check(powerFlowNodesSrc.contains("CellarNumericFormat.percent($0)")
              && !powerFlowNodesSrc.contains(#""\($0)%"#),
          "字面量-2", "功率流电量文本 percent formatter（PowerFlowDiagramNodes batteryPercentText——B7 评审 P3-1 手拼残留收口，0.23.16 B8-2）")

    // ---- 字面量-3：单位 key 通路 + °C 带空格统一源钉----

    for key in ["dashboard.unit.ampere", "dashboard.unit.volt", "dashboard.unit.celsius",
                "dashboard.unit.watt", "dashboard.unit.rpm"] {
        check(statusLineSrc.contains(key),
              "字面量-3", "StatusLineView 单位 key 通路（\(key)——A/V/°C/W/rpm 手拼清零）")
    }
    check(!statusLineSrc.contains("\"%.2f A\"")
              && !statusLineSrc.contains("\"%.1f V\"")
              && !statusLineSrc.contains("\"%.1f °C\"")
              && !statusLineSrc.contains("\"%.1f W\"")
              && !statusLineSrc.contains(#"\(Int(rpm.rounded())) rpm"#),
          "字面量-3", "StatusLineView 手拼单位字面量反钉（单位 printf 双形态全数退役）")
    check(fanSrc.components(separatedBy: "dashboard.unit.celsius").count - 1 >= 2
              && !fanSrc.contains("\"%.1f°C\""),
          "字面量-3", "风扇 °C 带空格统一 + 单位 key（FanSectionView:431/487——无空格粘连形态清零）")
    let statsHoverSrc = source("App/CellarApp/StatsChartHover.swift")
    check(statsHoverSrc.components(separatedBy: "dashboard.unit.percent").count - 1 >= 2
              && statsHoverSrc.contains("dashboard.unit.celsius")
              && statsHoverSrc.contains("dashboard.unit.watt")
              && !statsHoverSrc.contains("\"%%\"")
              && !statsHoverSrc.contains("\"%.1f °C\"")
              && !statsHoverSrc.contains("\"%.1f W\""),
          "字面量-3", "统计 hover 值标签单位 key（StatsChartHover:28-34——percent×2/celsius/watt）")
    let powerFlowSrc = source("Sources/CellarUI/PowerFlowView.swift")
    check(powerFlowSrc.contains("dashboard.unit.watt") && !powerFlowSrc.contains("\"%+.0f W\""),
          "字面量-3", "功率流三角图功率数字单位 key（PowerFlowView:159）")
    let powerTextSrc = source("App/CellarApp/DashboardView+PowerFlowText.swift")
    check(powerTextSrc.contains("dashboard.unit.volt") && !powerTextSrc.contains("\"%.1f V\""),
          "字面量-3", "电池电压行单位 key（DashboardView+PowerFlowText:16）")
    do {
        let catalogURL = repoRoot
            .appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")
        if let data = try? Data(contentsOf: catalogURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = root["strings"] as? [String: Any],
           let entry = strings["dashboard.unit.rpm"] as? [String: Any],
           let localizations = entry["localizations"] as? [String: Any],
           let zh = (localizations["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any],
           let en = (localizations["en"] as? [String: Any])?["stringUnit"] as? [String: Any] {
            check((zh["value"] as? String) == "rpm" && (en["value"] as? String) == "rpm",
                  "字面量-3", "新 key dashboard.unit.rpm 双语在位（rpm 缺 key 新增——catalog 增量有意登记）")
        } else {
            check(false, "字面量-3", "catalog dashboard.unit.rpm 键结构缺席（双语源钉红）")
        }
    }

    // ---- 字面量-4：LocalizedStringKey 插值绕过反钉（CellarL10n.swift:5-9 警告形态）----

    check(statusLineSrc.components(separatedBy: "Text(verbatim:").count - 1 >= 4,
          "字面量-4", "StatusLineView 预组装 String 显式 verbatim（电流方向词/温度注词/循环健康/风扇转速——插值绕过门面消除）")
    check(!controlSrc.contains(#"Button("\(preset)%")"#)
              && !onboardingSrc.contains(#"Button("\(preset)%")"#)
              && !fanSrc.contains(#"Text("\(Int(speedPercent))%")"#)
              && !fanSrc.contains(#"Text("\(Int(stage2Percent))%")"#),
          "字面量-4", "LocalizedStringKey 手拼百分号形态反钉（ControlSectionView/OnboardingView/FanSectionView）")
}
