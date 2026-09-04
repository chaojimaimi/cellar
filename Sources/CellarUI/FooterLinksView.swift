import CellarCore
import SwiftUI

/// 面板页脚链接行（Phase 5 v1.2 §2.1/§2.2；**参数驱动**——CellarUICheck 仅
/// import CellarCore/CellarUI，App 层 openSettings/terminate 不可达，照
/// CalibrationSectionView 先例由 App 侧薄包装桥接回调）：
/// - 布局 = HStack 两端 + Spacer（demo 低角两边形态：设置… | 退出 Cellar）；
/// - 纯文字轻量钮（plain 样式、callout、无图标/底色/描边——「不突出」诉求，
///   无图标同时删去原 gearshape（SR-2））；
/// - 常态 secondaryText、hover 强调 accent（两风格共有 token，SR-3）；
/// - 命中区 padding(4) + contentShape(Rectangle())——纯文字钮的点击/hover 命中
///   保障（「退出」是 terminate 级不可逆动作，命中区不可吝啬）；
/// - 交互语义零变化：设置/退出的真机修正逻辑在 App 侧薄包装（§2.1 保留）。
///
/// 组件内不画 Divider——分隔线由消费方 PanelView 提供（防双重分隔线进 golden）。
public struct FooterLinksView: View {
    /// 快照注入口：hover 是运行时鼠标态，矩阵无法自发生成——golden 以注入钉死
    /// 形态（照 FanSectionView.initialConfirmVisible 先例）；生产恒默认 nil。
    public let initialHoveredLink: FooterLink?

    /// 设置回调（App 侧薄包装注入：activate → openSettings 真机修正）。
    public let onSettings: () -> Void
    /// 退出回调（App 侧薄包装注入：terminate）。
    public let onQuit: () -> Void

    /// 当前 hover 钮（逐钮语义——页脚两枚独立钮，单 Bool 有歧义；鼠标离开置 nil）。
    @State private var hoveredLink: FooterLink?

    @Environment(\.cellarTheme) private var theme

    public init(
        onSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        initialHoveredLink: FooterLink? = nil
    ) {
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.initialHoveredLink = initialHoveredLink
        _hoveredLink = State(initialValue: initialHoveredLink)
    }

    public var body: some View {
        HStack {
            footerButton(label: CellarL10n.s("panel.footerSettings"), link: .settings, action: onSettings)
            Spacer()
            footerButton(label: theme.word(.quit), link: .quit, action: onQuit)
        }
        .buttonStyle(.plain)
    }

    /// 单钮（hover 钮经 hoveredLink 比对强调——单钮强调、余钮常态）。
    private func footerButton(
        label: String, link: FooterLink, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                // G2：token 消费（secondaryText/accent），零 Color 字面量。
                .foregroundStyle(hoveredLink == link ? theme.accent : theme.secondaryText)
                .padding(4)
                .contentShape(Rectangle())
        }
        .onHover { hovering in
            hoveredLink = hovering ? link : nil
        }
    }
}

/// 页脚链接标识（设置 / 退出；逐钮 hover 与注入口的判别依据）。
public enum FooterLink {
    case settings
    case quit
}