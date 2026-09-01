import SwiftUI

// MARK: - 主题 token（规格 §2.5：Phase 3 风格系统预留）

/// Cellar 面板色彩 token。**App/CellarApp 内 Color 字面量仅允许出现在本文件**
/// （执行门：组件一律经 environment 读取 token；默认 .native = 系统语义色，
/// 原生极简基线，深浅色自动合规）。
///
/// Phase 3 切换风格 = 组合根注入不同 CellarTheme 值（不上协议，评审 endorse）。
struct CellarTheme {
    /// 电量弧 / 充电徽标。
    var accent: Color
    /// 限充区间弧（band 弧）。
    var band: Color
    /// 已停充（holding）状态强调。
    var holding: Color
    /// 告警 / 错误（横幅、失败文案、alert 图标着色）。
    var alert: Color
    /// 告警横幅背景。
    var bannerBackground: Color
    /// 仪表底环（quaternary 语义）。
    var track: Color
    /// 二级文本。
    var secondaryText: Color
    /// 三级文本。
    var tertiaryText: Color
    /// 成功反馈。
    var success: Color
    /// 异常警示（daemon anomaly 行等中间态）。
    var warning: Color

    /// 默认主题：系统语义色（原生极简基线）。
    static let native = CellarTheme(
        accent: .accentColor,
        band: .secondary,
        holding: .green,
        alert: .red,
        bannerBackground: Color.primary.opacity(0.08),
        track: Color.primary.opacity(0.08),
        secondaryText: .secondary,
        tertiaryText: Color.secondary.opacity(0.6),
        success: .green,
        warning: .orange
    )
}

// MARK: - environment 注入

private struct CellarThemeKey: EnvironmentKey {
    static let defaultValue = CellarTheme.native
}

extension EnvironmentValues {
    var cellarTheme: CellarTheme {
        get { self[CellarThemeKey.self] }
        set { self[CellarThemeKey.self] = newValue }
    }
}