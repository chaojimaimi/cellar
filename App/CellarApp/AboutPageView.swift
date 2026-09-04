import CellarCore
import CellarUI
import SwiftUI

/// 关于页（M3.5 工单 4：设置窗退役后并入主窗口，且自「外观与关于」合并页拆出
/// ——外观独立成页 AppearancePageView）：AboutSections + 页头。页面容器纪律照
/// 工单 4：ScrollView + padding 24 + maxWidth 720 alignment leading。
struct AboutPageView: View {
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(CellarL10n.s("main.page.about"))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                AboutSections()
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}