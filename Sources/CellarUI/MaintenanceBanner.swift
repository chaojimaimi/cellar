import SwiftUI

// MARK: - 0.23.25 §2.3 charge-to-full 系统维护充满退让横幅（**参数驱动**——
// CellarUICheck 仅 import CellarCore/CellarUI，App 侧 PanelView 薄桥接
// StatusController，照 CalibrationBanner 先例）：
// - daemon 回读 maintenanceFullChargeActive == true → 信息态横幅（macOS 检测到
//   电池约 21 天未充满正在主动充满校准电量计——期间 Cellar 三臂退让配合〔strike/
//   轻量重申/域随写暂停，不与 PowerUIAgent 抢域写〕，充满后自动恢复执法；
//   §2.3 并存面登记：退让期 sub80MechanismSuppressed 通用页警示行同期在场，
//   横幅文案「期间充电上限由系统临时接管」即同源消歧，不遮蔽）；
// - 缺省 visible=false → EmptyView（26/旧 daemon 宿主不嵌入或恒 false，天然零渲染
// ——26 红线）。
public struct MaintenanceBanner: View {
    /// 退让态（daemon 回读 maintenanceFullChargeActive；缺省 false = 既有构造零 diff）。
    public let visible: Bool

    /// 引导阈值天数（横幅单参 %lld——实证触发阈值 20.9 天判 too recent / 21.0 天判
    /// charge to full，任务书 §0/§2.5，取整 21；last-full-date 读位未立项前为常量，
    /// %lld 形态预留读位跟进后动态化）。
    private static let approxThresholdDays = 21

    @Environment(\.cellarTheme) private var theme

    public init(visible: Bool = false) {
        self.visible = visible
    }

    public var body: some View {
        if visible {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text(CellarL10n.s("panel.maintenance.banner", Self.approxThresholdDays))
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
