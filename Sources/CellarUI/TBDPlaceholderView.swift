import SwiftUI

/// 占位页（Phase 5 v1.2 §4.3，照 mock tbd-card）：图标 + 标题 + 范围说明 +
/// 版本徽章。**参数驱动**——icon/标题/范围/版本全注入（CellarUICheck 可独立
/// 构造；M3 换实页后本组件退役，快照 4 张随批更新）。
///
/// 视觉：虚线边框圆角卡（mock 1.5px dashed line2）、居中排版、版本 chip
/// （mock .chip：11pt + 圆角胶囊 + 描边）。G2：色值全 token 消费，零 Color
/// 字面量（面板底走 theme.panelBackground 可选 token——native nil 不画）。
public struct TBDPlaceholderView: View {
    public let icon: String
    public let title: String
    public let scope: String
    public let version: String

    @Environment(\.cellarTheme) private var theme

    public init(icon: String, title: String, scope: String, version: String) {
        self.icon = icon
        self.title = title
        self.scope = scope
        self.version = version
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(theme.tertiaryText)
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(scope)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            versionChip
        }
        .padding(.vertical, 44)
        .padding(.horizontal, 48)
        .frame(maxWidth: 460)
        .background {
            // native 无自绘面板底（nil token 不画——系统容器材质兜底）。
            if let panelBackground = theme.panelBackground {
                RoundedRectangle(cornerRadius: 18).fill(panelBackground)
            }
        }
        .overlay(
            // line2 虚线近似：无独立 line token，取 secondaryText 降档（风格 C 留位）。
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.secondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 版本徽章（mock .chip：11pt、圆角胶囊、描边、无填充强调）。
    private var versionChip: some View {
        Text(version)
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryText)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .background {
                if let panelBackground = theme.panelBackground {
                    Capsule().fill(panelBackground)
                }
            }
            .overlay(Capsule().strokeBorder(theme.secondaryText.opacity(0.45)))
    }
}