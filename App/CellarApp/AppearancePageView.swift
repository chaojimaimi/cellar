import CellarCore
import CellarUI
import SwiftUI

/// 外观页（M3.5 工单 4：设置窗退役后并入主窗口）：AppearanceSections + 页头
/// （设置窗「外观」Tab 内容经共享子视图随迁，风格切换链路零变化）。页面容器
/// 纪律照工单 4：ScrollView + padding 24 + maxWidth 720 alignment leading。
struct AppearancePageView: View {
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(CellarL10n.s("main.page.appearance"))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                AppearanceSections()
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}