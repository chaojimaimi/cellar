import CellarCore
import SwiftUI

// MARK: - sub80 通道状态组件（0.20 WP2 §3.4；**参数驱动**——CellarUICheck 仅
// import CellarCore/CellarUI，App 侧 ControlSectionView 薄桥接 StatusController；
// 照 OrchestrationSectionView 先例）：
// - 实验性徽章（目标 <80 ∧ sub80 能力）：「实验性」+ 说明文案（系统私有偏好域
//   执法 + 失效自动回退 80%——方案 §3.4 原文）；
// - 回落进度（sub80State == active ∧ percent > 目标）：「回落中 82%→75%」——
//   进度语义不承诺时长（§11.5.1 斜率负载强相关实测事实）；
// - 降级横幅（sub80State == degraded）：重申×3 封顶后的诚实降级告知；
// - 迟滞执法横幅（0.21.0 §2.2，sub80Hysteresis == true）：CHIE 备用通道执法中
//   （约 1 循环/天成本告知同行承载，§2.3）；
// - 状态明细 + 自愈进度（0.21.0 §5，state/healProbe 参数）：功能概览页 sub80
//   明细（active/degraded/hysteresis/off + 自愈重探拍进度——参数驱动，缺省
//   参保既有 golden 零 diff，新态走快照矩阵）。
// 全参数带缺省值：全缺省 → EmptyView（26/无 sub80 能力机器宿主不嵌入本组件，
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
    /// 0.21.0 §2.2 迟滞执法横幅（daemon 回读 sub80Hysteresis == true——「实验性
    /// 备用通道执法中（约 1 循环/天）」；缺省 false = 既有构造零 diff）。
    public let hysteresisEnforcing: Bool
    /// 0.21.0 §5 状态明细（daemon 回读 sub80State 四态；nil = 不渲染明细行——
    /// 缺省形态既有 golden 零 diff）。功能概览页宿主消费（控制页横幅语汇保持）。
    public let state: Sub80State?
    /// 明细行迟滞覆盖（daemon 回读 sub80Hysteresis == true → 明细词切迟滞执法——
    /// 挂载是 degraded 的执法形态，横幅与明细词分立：横幅=警示态，明细=状态事实）。
    public let hysteresisMounted: Bool
    /// 自愈探针观察窗进行中（daemon 回读 sub80HealProbeActive；缺省 false）。
    public let healProbeActive: Bool
    /// 自愈探针拍计数（healProbeActive ∧ 非 nil → 渲染进度行；窗总长
    /// `Topoff.verificationTicks` 同源引用）。
    public let healProbeTicks: Int?

    @Environment(\.cellarTheme) private var theme

    public init(
        degraded: Bool = false,
        experimentalTarget: Int? = nil,
        fallingFrom: Int? = nil,
        fallingTarget: Int? = nil,
        hysteresisEnforcing: Bool = false,
        state: Sub80State? = nil,
        hysteresisMounted: Bool = false,
        healProbeActive: Bool = false,
        healProbeTicks: Int? = nil
    ) {
        self.degraded = degraded
        self.experimentalTarget = experimentalTarget
        self.fallingFrom = fallingFrom
        self.fallingTarget = fallingTarget
        self.hysteresisEnforcing = hysteresisEnforcing
        self.state = state
        self.hysteresisMounted = hysteresisMounted
        self.healProbeActive = healProbeActive
        self.healProbeTicks = healProbeTicks
    }

    /// 明细区可见性（0.21.0 §5 新形态——明细行或进度行任一在场）。
    private var showsDetail: Bool {
        state != nil || (healProbeActive && healProbeTicks != nil)
    }

    public var body: some View {
        if degraded || experimentalTarget != nil || hysteresisEnforcing || showsDetail
            || (fallingFrom != nil && fallingTarget != nil) {
            VStack(alignment: .leading, spacing: 6) {
                if degraded {
                    degradedBanner
                }
                if hysteresisEnforcing {
                    hysteresisBanner
                }
                if let state {
                    stateDetailLine(state)
                }
                if healProbeActive, let ticks = healProbeTicks {
                    healProgressLine(ticks)
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

    /// 0.21.0 §5 状态明细行（「通道状态：执法承载中（topoff 通道）」——四态词 +
    /// 迟滞覆盖；复用 Sub80StatusView 词汇域，degraded/hysteresis 与既有横幅语汇
    /// 同源措辞。caption + secondaryText 信息态——状态事实呈现，非警示）。
    private func stateDetailLine(_ state: Sub80State) -> some View {
        let stateWord: String
        if hysteresisMounted {
            stateWord = CellarL10n.s("panel.sub80.state.hysteresis")
        } else {
            switch state {
            case .active: stateWord = CellarL10n.s("panel.sub80.state.active")
            case .degraded: stateWord = CellarL10n.s("panel.sub80.state.degraded")
            case .off: stateWord = CellarL10n.s("panel.sub80.state.off")
            }
        }
        return Text(CellarL10n.s("panel.sub80.detail", stateWord))
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 0.21.0 §5 自愈进度行（「自愈重探中（第 i/N 拍）」——进度语义不承诺时长，
    /// 照回落行 §11.5.1 斜率负载强相关纪律；N = Topoff.verificationTicks 同源）。
    private func healProgressLine(_ ticks: Int) -> some View {
        Text(CellarL10n.s(
            "panel.sub80.healProgress", "\(ticks)", "\(Topoff.verificationTicks)"))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 0.21.0 §2.2 迟滞执法横幅（单行——CHIE 备用通道挂载中；约 1 循环/天成本告知
    /// 同行承载，§2.3。warning 弱化底色语汇照实验性徽章——同为实验性通道语义）。
    private var hysteresisBanner: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.badge.checkmark")
                .font(.caption)
            Text(CellarL10n.s("panel.sub80.hysteresis.banner"))
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(theme.warning)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(theme.warning.opacity(0.12), in: Capsule())
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
