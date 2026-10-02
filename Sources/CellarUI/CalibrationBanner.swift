import SwiftUI

// MARK: - 校准抑制横幅（0.21.0 §3.2；**参数驱动**——CellarUICheck 仅 import
// CellarCore/CellarUI，App 侧 PanelView 薄桥接 StatusController，照 Sub80StatusView
// 先例）：
// - daemon 回读 calibrationSuspected == true → 「系统校准中（限充暂缓——校准结束
//   自动恢复）」信息态横幅（模式指纹识别——非系统公开信号，识别有误报/漏报可能，
//   方案 §3.2 诚实边界；横幅随识别态自动进出，无用户操作面）；
// - 缺省 visible=false → EmptyView（26/旧 daemon 宿主不嵌入或恒 false，天然零渲染
// ——26 红线）。
public struct CalibrationBanner: View {
    /// 识别抑制态（daemon 回读 calibrationSuspected；缺省 false = 既有构造零 diff）。
    public let visible: Bool

    @Environment(\.cellarTheme) private var theme

    public init(visible: Bool = false) {
        self.visible = visible
    }

    public var body: some View {
        if visible {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text(CellarL10n.s("panel.calibration.suspected.banner"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
