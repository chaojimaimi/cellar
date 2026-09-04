import CellarCore
import CellarUI
import SwiftUI

/// 充电控制页（Phase 5 v1.2 §2.2/§4.1，M3 换实页）：ControlSectionView +
/// ActionSectionView + CalibrationSection 照面板分区顺序组装（控制区 → 动作区
/// → 校准区，Divider 分隔）。页面即 StatusController 单源的第二宿主——与面板
/// 并存时各自独立 @State（滑杆本地态/防抖任务组件内持有），控制器与 daemon
/// 单真相，双宿主经 daemonStatus 自同步通路互不干扰（§4.1 R1 P1-2）。
///
/// daemonStatus 门控照面板（不可达时控制区整体隐藏——组件出现/消失即首包
/// 同步路口；失联态由侧栏 footer 状态行呈现）。
struct ControlPageView: View {
    @EnvironmentObject private var statusController: StatusController
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if statusController.daemonStatus != nil {
                    ControlSectionView()
                    Divider()
                    ActionSectionView()
                    Divider()
                    CalibrationSection()
                }
            }
            .padding(24)
            // 工单 4 页面容器纪律：maxWidth 720——宽窗下内容不无限拉伸（治截图
            // 四松散排版；表单/滑杆列宽与面板 304pt 语义解耦，走查对照）。
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        Text(CellarL10n.s("main.page.control"))
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
    }
}