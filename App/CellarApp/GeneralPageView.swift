import CellarCore
import CellarUI
import SwiftUI

/// 通用页（M3.5 工单 4：设置窗退役后并入主窗口）：GeneralSections（自设置窗
/// 通用 Tab 提取的共享内容——登录项/注册态/通知授权/自动放电/风扇组）+
/// DaemonSectionView（面板的 daemon 安装/卸载区块直接实例化复用，App 层组件
/// 同宿主可用）。页头样式照 DashboardView（页题 26pt secondaryText）。
///
/// 页面容器纪律（工单 4）：ScrollView + padding 24 + 内容 maxWidth 720
/// alignment leading——宽窗下内容不无限拉伸（治截图四松散排版）。
struct GeneralPageView: View {
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(CellarL10n.s("main.page.general"))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                GeneralSections()
                DaemonSectionView()
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}