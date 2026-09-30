import SwiftUI

// MARK: - sub80 通道状态组件（0.20 WP2 §3.4；**参数驱动**——CellarUICheck 仅
// import CellarCore/CellarUI，App 侧 ControlSectionView 薄桥接 StatusController；
// 照 OrchestrationSectionView 先例）：
// - 实验性徽章（目标 <80 ∧ sub80 能力）：「实验性」+ 说明文案（系统私有偏好域
//   执法 + 失效自动回退 80%——方案 §3.4 原文）；
// - 回落进度（sub80State == active ∧ percent > 目标）：「回落中 82%→75%」——
//   进度语义不承诺时长（§11.5.1 斜率负载强相关实测事实）；
// - 降级横幅（sub80State == degraded）：重申×3 封顶后的诚实降级告知。
// 全参数带缺省值：三态全缺省 → EmptyView（26/无 sub80 能力机器宿主不嵌入本组件，
// 天然零渲染）。显隐判定在宿主页——组件只做纯展示。

public struct Sub80StatusView: View {
    /// 降级横幅（daemon 回读 sub80State == .degraded）。
    public let degraded: Bool
    /// 实验性徽章目标（非 nil = 当前目标 <80——徽章 + 说明；nil = 不渲染）。
    public let experimentalTarget: Int?
    /// 回落进度当前电量（非 nil ∧ fallingTarget 非 nil → 渲染回落行）。
    public let fallingFrom: Int?
    /// 回落进度目标上限（与 fallingFrom 成对）。
    public let fallingTarget: Int?

    @Environment(\.cellarTheme) private var theme

    public init(
        degraded: Bool = false,
        experimentalTarget: Int? = nil,
        fallingFrom: Int? = nil,
        fallingTarget: Int? = nil
    ) {
        self.degraded = degraded
        self.experimentalTarget = experimentalTarget
        self.fallingFrom = fallingFrom
        self.fallingTarget = fallingTarget
    }

    public var body: some View {
        if degraded || experimentalTarget != nil || (fallingFrom != nil && fallingTarget != nil) {
            VStack(alignment: .leading, spacing: 6) {
                if degraded {
                    degradedBanner
                }
                if experimentalTarget != nil {
                    experimentalBadge
                }
                if let from = fallingFrom, let target = fallingTarget {
                    fallingLine(from: from, target: target)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// 降级横幅（warning 色块——照滑杆 minNative 标注的 warning 语汇；标题行 +
    /// 说明行，§3.2 降级态传播）。
    private var degradedBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(CellarL10n.s("panel.sub80.degraded.title"))
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(theme.warning)
            Text(CellarL10n.s("panel.sub80.degraded.banner"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 实验性徽章（Capsule 底 warning 弱化底色）+ 说明文案（方案 §3.4 原文语汇）。
    private var experimentalBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CellarL10n.s("panel.sub80.experimental"))
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(theme.warning.opacity(0.15), in: Capsule())
                .foregroundStyle(theme.warning)
            Text(CellarL10n.s("panel.sub80.experimental.desc"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 回落进度行（「回落中 82%→75%」——不承诺时长；monospacedDigit 数值）。
    private func fallingLine(from: Int, target: Int) -> some View {
        Text(CellarL10n.s("panel.sub80.falling", "\(from)", "\(target)"))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.secondaryText)
    }
}
