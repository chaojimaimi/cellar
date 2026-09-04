import CellarCore
import SwiftUI
import os

// MARK: - 主题 token（规格 §2.5：Phase 3 风格系统 v1 定版；WP4 自 App target 下沉）

/// Cellar 面板色彩 token。**CellarUI 内 Color 字面量仅允许出现在本文件**
/// （执行门 G2 新落点：组件一律经 environment 读取 token；默认 .native = 系统
/// 语义色，原生极简基线，深浅色自动合规）。
///
/// 切换风格 = 组合根经 resolve(style:scheme:) 注入不同 CellarTheme 值（不上协议，
/// 评审 endorse）。组件层无条件消费全部 token，native 哑值消解——A 原生基线零
/// 视觉回归；语汇串一律经 word(_:) 读取（非可选，评审 P1-5，组件层禁止对
/// vocabulary 做可选下标/强解/兜底字面量）。⚠️ Sendable：token 值全为值类型
/// （Color/LinearGradient/AccentGlow/词典），Swift 6 全并发检查下 static let
/// 主题常量（native/amberLight/amberDark）与 EnvironmentKey 默认值要求之。
public struct CellarTheme: Sendable {
    /// 电量弧 / 充电徽标。
    public var accent: Color
    /// 限充区间弧（band 弧）。
    public var band: Color
    /// 已停充（holding）状态强调。
    public var holding: Color
    /// 告警 / 错误（横幅、失败文案、alert 图标着色）。
    public var alert: Color
    /// 告警横幅背景。
    public var bannerBackground: Color
    /// 仪表底环（quaternary 语义）。
    public var track: Color
    /// 二级文本。
    public var secondaryText: Color
    /// 三级文本。
    public var tertiaryText: Color
    /// 成功反馈。
    public var success: Color
    /// 异常警示（daemon anomaly 行等中间态）。
    public var warning: Color
    /// 面板自绘背景（nil = 不画，native 走系统容器材质）。
    public var panelBackground: Color?
    /// 面板自绘背景的边框（nil = 不画边框）。
    public var panelBorder: Color?
    /// accent 渐变（非可选；native 平坦哑值——组件无条件消费、哑值消解；
    /// 消费面 = 外观 Tab 色板预览，仪表弧保持单色 accent）。
    public var accentGradient: LinearGradient
    /// accent 光晕（native 哑值 = 透明 + radius 0——A 原生基线零光晕回归）。
    public var accentGlow: AccentGlow
    /// 已解析语汇表（组合根构建 theme 时经 CellarL10n 一次性解析；
    /// 组件经 word(_:) 读取）。
    public var vocabulary: [VocabularyWord: String]
    /// 展示字体（A/B 同值系统字体——占位字段，登记：第三风格消费时启用）。
    public var displayFont: Font

    /// 默认主题：系统语义色（原生极简基线）。vocabulary 留空——word(_:) 以内置
    /// 常量兜底（与现 UI 中文原文一字不差），environment 默认值路径永不落空。
    public static let native = CellarTheme(
        accent: .accentColor,
        band: .secondary,
        holding: .green,
        alert: .red,
        bannerBackground: Color.primary.opacity(0.08),
        track: Color.primary.opacity(0.08),
        secondaryText: .secondary,
        tertiaryText: Color.secondary.opacity(0.6),
        success: .green,
        warning: .orange,
        panelBackground: nil,
        panelBorder: nil,
        accentGradient: LinearGradient(
            colors: [.accentColor, .accentColor],
            startPoint: .leading,
            endPoint: .trailing
        ),
        accentGlow: AccentGlow(color: .clear, radius: 0),
        vocabulary: [:],
        displayFont: .body
    )

    /// B 风格浅色（暖纸）。色值全部提取自设计 demo 双色板/光晕/渐变（WP3 §1.6
    /// 提取面；demo 为唯一视觉事实源，代码不引用其私有路径）。demo 无独立值 的
    /// token（banner 底/success/warning/tertiary）从同族色推导，不引入新色相。
    public static let amberLight = CellarTheme(
        accent: Color(hex: 0xB4793B),                          // demo 琥珀 accent（浅）
        band: Color(hex: 0xB4793B).opacity(0.27),              // demo band 弧 = accent @ 0x44
        holding: Color(hex: 0x8A5B1E),                         // demo badge/chip 文本色（浅）
        alert: Color(hex: 0xC0392B),                           // demo 告警红（浅）
        bannerBackground: Color(hex: 0xD9A441).opacity(0.12),  // 暖警示底（badge 底同族）
        track: Color(hex: 0x7F7F8C).opacity(0.22),             // demo 仪表底环（浅）
        secondaryText: Color(hex: 0x8A7A66),                   // demo 暖调次级文本
        tertiaryText: Color(hex: 0x8A7A66).opacity(0.6),       // 次级文本降档
        success: Color(hex: 0xB4793B),                         // demo 无独立成功色 → 随品牌 accent
        warning: Color(hex: 0xC98A45),                         // demo 预设渐变中点（暖警示）
        panelBackground: Color(hex: 0xFFFDF8).opacity(0.93),   // demo 暖纸面板底
        panelBorder: Color(hex: 0x604018).opacity(0.14),       // demo 面板边框（浅）
        accentGradient: LinearGradient(                        // demo 135° 渐变（浅）
            colors: [amberGradientColors(scheme: .light).start, amberGradientColors(scheme: .light).end],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        accentGlow: AccentGlow(color: Color(hex: 0xD9A441).opacity(0.35), radius: 5),  // demo 光晕
        vocabulary: [:],
        displayFont: .body
    )

    /// B 风格深色（暖夜）。告警红取 demo 复审 WCAG 修正值 #E05252。
    public static let amberDark = CellarTheme(
        accent: Color(hex: 0xE3A94F),                          // demo 琥珀 accent（深）
        band: Color(hex: 0xE3A94F).opacity(0.27),
        holding: Color(hex: 0xEAC98D),                         // demo badge 文本色（深）
        alert: Color(hex: 0xE05252),                           // demo 复审 WCAG 修正（深色告警红）
        bannerBackground: Color(hex: 0xE3A94F).opacity(0.10),
        track: Color(hex: 0x7F7F8C).opacity(0.32),             // demo 仪表底环（深）
        secondaryText: Color(hex: 0xA08D74),                   // demo 暖调次级文本（深）
        tertiaryText: Color(hex: 0xA08D74).opacity(0.6),
        success: Color(hex: 0xE3A94F),
        warning: Color(hex: 0xEAB765),
        panelBackground: Color(hex: 0x211A13).opacity(0.92),   // demo 暖夜面板底
        panelBorder: Color(hex: 0xE3A94F).opacity(0.17),       // demo 面板边框（深）
        accentGradient: LinearGradient(                        // demo 135° 渐变（深）
            colors: [amberGradientColors(scheme: .dark).start, amberGradientColors(scheme: .dark).end],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ),
        accentGlow: AccentGlow(color: Color(hex: 0xE3A94F).opacity(0.4), radius: 7),  // demo 光晕（深 7px .4）
        vocabulary: [:],
        displayFont: .body
    )

    /// demo 135° 渐变端点（浅 #D9A441→#B4793B / 深 #EAB765→#D99B46）。独立成对
    /// 存放：LinearGradient 无公开端点访问器，外观 Tab 色板行须展示起止色。
    private static func amberGradientColors(scheme: ColorScheme) -> (start: Color, end: Color) {
        scheme == .dark
            ? (Color(hex: 0xEAB765), Color(hex: 0xD99B46))
            : (Color(hex: 0xD9A441), Color(hex: 0xB4793B))
    }

    /// 组合根唯一解析入口：native 与系统色深浅无关（语汇仍按词条表解析）；amber
    /// 按 scheme 二选一。switch 穷举两 case、无 default——新增风格漏实现 = 编译错。
    public static func resolve(style: PanelStyle, scheme: ColorScheme) -> CellarTheme {
        switch style {
        case .native:
            var theme = CellarTheme.native
            theme.vocabulary = vocabularyTable(style: .native)
            return theme
        case .amber:
            var theme = scheme == .dark ? amberDark : amberLight
            theme.vocabulary = vocabularyTable(style: .amber)
            return theme
        }
    }

    /// 外观 Tab 色板行（4 色块：accent / 渐变起 / 渐变止 / 面板底）。值全部出自
    /// 本文件 token（G2 不新增字面量落点）；native 渐变为平坦哑值（起止同
    /// accent），面板底 = 系统窗口底色示意（native 不自绘面板底）。
    public static func swatchColors(style: PanelStyle, scheme: ColorScheme) -> [Color] {
        switch style {
        case .native:
            return [
                .accentColor, .accentColor, .accentColor,
                Color(nsColor: .windowBackgroundColor),
            ]
        case .amber:
            let theme = scheme == .dark ? amberDark : amberLight
            let gradient = amberGradientColors(scheme: scheme)
            return [theme.accent, gradient.start, gradient.end, theme.panelBackground ?? .clear]
        }
    }

    // MARK: 语汇解析（§3.2 完整性校验 + §3.6 本地化衔接）

    /// 语汇完整性日志（缺词条回退可见化，不静默）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "theme")

    /// 语汇表构建：CellarL10n 逐词条解析（缺翻译的完整性校验在 resolvedWord 内）。
    private static func vocabularyTable(style: PanelStyle) -> [VocabularyWord: String] {
        var table: [VocabularyWord: String] = [:]
        for word in VocabularyWord.allCases {
            table[word] = resolvedWord(word, style: style)
        }
        return table
    }

    /// 单词条解析（回退链，评审 NP2 定版）：本风格词条查得值 == key（xcstrings
    /// 缺翻译）或为空 → 回退 native 词条 + error 日志；native 值复检再失败 →
    /// 终值兜底 = 内置常量（nativeConstant，与迁移前 UI 原文一字不差）。任何
    /// 回退路径都留日志，不静默。⚠️ WP4：解析固定经 CellarL10n 查 Bundle.module
    /// （catalog 随组件库下沉，App target 侧不再有词条表）。
    private static func resolvedWord(_ word: VocabularyWord, style: PanelStyle) -> String {
        let key = PanelStyle.vocabularyKey(style: style, word: word)
        let value = CellarL10n.s(String.LocalizationValue(key))
        if value != key && !value.isEmpty { return value }
        log.error("语汇词条缺失「\(key, privacy: .public)」，回退原生词条")
        let nativeKey = PanelStyle.vocabularyKey(style: .native, word: word)
        let nativeValue = CellarL10n.s(String.LocalizationValue(nativeKey))
        if nativeValue != nativeKey && !nativeValue.isEmpty { return nativeValue }
        log.error("语汇原生词条缺失「\(nativeKey, privacy: .public)」，兜底内置常量")
        return nativeConstant(word)
    }

    /// native 现词内置常量（S6 迁移时现 UI 原文即成为常量）——回退链终点 +
    /// word(_:) 最后安全网。
    private static func nativeConstant(_ word: VocabularyWord) -> String {
        switch word {
        case .statusChargingExternal: return "外接 · 充电中"
        case .statusHoldingExternal: return "外接 · 已停充"
        case .statusBattery: return "电池供电"
        case .actionFullOnce: return "充满一次：充电到 100% 后自动恢复限充"
        case .quit: return "退出 Cellar"
        case .tempLabel: return "温度"
        case .limitLabel: return "充电上限"
        case .powerFlowCharging: return "充电中"
        case .powerFlowFloating: return "已停充"
        case .powerFlowOnBattery: return "电池供电"
        case .healthLabel: return "健康"
        case .dashboardGaugeTitle: return "电量"
        case .dashboardTileTemp: return "温度"
        case .dashboardStateCharging: return "充电中"
        case .dashboardStateHolding: return "已停充"
        case .dashboardStateBattery: return "电池供电"
        }
    }

    /// 语汇访问器（非可选）：表由 resolve 构建时已兜底，此处常量仅最后安全网
    /// （environment 默认值路径 vocabulary 为空表时同样落在本方法）。
    public func word(_ w: VocabularyWord) -> String {
        vocabulary[w] ?? Self.nativeConstant(w)
    }
}

/// accent 光晕（color + radius 小 struct，非可选 token 的值类型；Equatable 供
/// 组件比对；Sendable 随 CellarTheme 传递跨隔离界）。
public struct AccentGlow: Equatable, Sendable {
    public var color: Color
    public var radius: CGFloat

    public init(color: Color, radius: CGFloat) {
        self.color = color
        self.radius = radius
    }
}

// 本地化解析门面 CellarL10n 独立于本文件（CellarL10n.swift）——含 bundle 资源
// 双形态兜底（xcodebuild 编译 lproj / swift build 拷贝原始 xcstrings）。

// MARK: - environment 注入

private struct CellarThemeKey: EnvironmentKey {
    public static let defaultValue = CellarTheme.native
}

public extension EnvironmentValues {
    var cellarTheme: CellarTheme {
        get { self[CellarThemeKey.self] }
        set { self[CellarThemeKey.self] = newValue }
    }
}

// MARK: - 十六进制色便捷构造

/// demo 提取色值唯一落点（执行门 G2：Color 字面量仅 CellarUI/Theme.swift）。
private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - 风格注入包装（§3.3）

/// 组合根包装 View：在 **View 上下文**读取 colorScheme（App 结构体层级取值不可靠
/// ——评审 P1-1；取值路径按 spike S3 结论定版 environment，无 KVO 降级），resolve
/// 后注入 cellarTheme；MenuBarExtra 与 Settings 内容各自包裹一层。
public struct ThemeProvider<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let style: PanelStyle
    @ViewBuilder let content: () -> Content

    public init(style: PanelStyle, @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.content = content
    }

    public var body: some View {
        let theme = CellarTheme.resolve(style: style, scheme: scheme)
        return content()
            .environment(\.cellarTheme, theme)
            // 系统控件（滑杆/开关/选择器/按钮）跟随主题 accent——琥珀风格下不再
            // 泄漏系统蓝（走查 2026-09-04）；native 的 accent token = 系统色，零变化。
            .tint(theme.accent)
    }
}
