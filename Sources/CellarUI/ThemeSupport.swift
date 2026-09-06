import CellarCore
import SwiftUI

// 主题支撑面（Phase 5 v1.9 M3，D-B5：Theme.swift 394 行逼近 400 红线——仅拆
// public 支撑符号 AccentGlow / environment key / ThemeProvider，纯剪切-粘贴
// 零改写；行为漂移由 A/B golden 全量字节断言兜底 R-3）。⚠️ `Color(hex:)` 为
// file-private，40+ 消费点全在五主题色板内，留守 Theme.swift 不拆（R1 P1-3）。

// MARK: - accent 光晕

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
