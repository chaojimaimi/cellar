import CellarCore
import SwiftUI

// MARK: - sub80 通道状态组件（0.20 WP2 §3.4；**参数驱动**——CellarUICheck 仅
// import CellarCore/CellarUI，App 侧 ControlSectionView 薄桥接 StatusController；
// 照参数驱动组件先例）：
// - 回落进度（sub80State == active ∧ percent > 目标）：「回落中 82%→75%」——
//   进度语义不承诺时长（§11.5.1 斜率负载强相关实测事实）；
// - 降级横幅（sub80State == degraded）：重申×3 封顶后的诚实降级告知——**0.23.0
//   §④ F7 参数化**（回退值随实际域写值 %lld；标题去「<80」偏概全——degraded
//   非 <80 专属，编排关 ≥85 域承载态同样可达）；
// - 迟滞执法横幅（0.21.0 §2.2，sub80Hysteresis == true）：备用断电保护执法中
//   （约 1 循环/天成本告知同行承载，§2.3；0.23.0 §⑤ 措辞去「实验性/CHIE」）；
// - 状态明细 + 自愈进度（0.21.0 §5，state/healProbe 参数）：功能概览页 sub80
//   明细（active/degraded/hysteresis/off + 自愈重探拍进度——参数驱动，缺省
//   参保既有 golden 零 diff，新态走快照矩阵）。
// **0.23.0 §③ 实验性摘帽**：原 experimentalTarget「实验性」徽章参数族删除
//（sub80 已非实验特性——生产连日实证；l10n 死键随批清理）。
// 全参数带缺省值：全缺省 → EmptyView（26/无 sub80 能力机器宿主不嵌入本组件，
// 天然零渲染）。显隐判定在宿主页——组件只做纯展示。

/// 回落进度行（0.21.2 §1 自 Sub80StatusView 提取的**共享子组件**——充电控制页
/// 宿主与仪表板电量卡（环形图）双宿主复用；AlDente 主界面先例 + 用户亲历痛点
/// 「盯着仪表板看不到回落」支撑 0.21.0 §5 决策反转，方案 §1）。「回落中
/// X%→Y%」进度语义不承诺时长（§11.5.1 斜率负载强相关实测事实）；caption +
/// secondaryText 信息态、monospacedDigit 数值——渲染形态与 Sub80StatusView 内
/// 嵌行逐字节同源（既有 golden 零 diff）。显示条件门控在宿主页——组件纯展示。
public struct Sub80FallingProgressRow: View {
    /// 回落进度当前电量（宿主门控传入：sub80State == .active ∧ percent > target）。
    public let from: Int
    /// 回落进度目标上限（与 from 成对）。
    public let target: Int

    @Environment(\.cellarTheme) private var theme

    public init(from: Int, target: Int) {
        self.from = from
        self.target = target
    }

    public var body: some View {
        Text(CellarL10n.s("panel.sub80.falling", "\(from)", "\(target)"))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.secondaryText)
    }
}

public struct Sub80StatusView: View {
    /// 降级横幅（daemon 回读 sub80State == .degraded）。
    public let degraded: Bool
    /// 降级横幅回退值（0.23.0 §④ F7 参数化——随实际域写值；默认 80 保既有构造
    /// 形态。数据源 = sub80WrittenLimit，fresh 缺席按 max(target,80) 同源兜底）。
    public let degradedWriteValue: Int
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
        degradedWriteValue: Int = 80,
        fallingFrom: Int? = nil,
        fallingTarget: Int? = nil,
        hysteresisEnforcing: Bool = false,
        state: Sub80State? = nil,
        hysteresisMounted: Bool = false,
        healProbeActive: Bool = false,
        healProbeTicks: Int? = nil
    ) {
        self.degraded = degraded
        self.degradedWriteValue = degradedWriteValue
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
        if degraded || hysteresisEnforcing || showsDetail
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
    /// 说明行，§3.2 降级态传播）。**0.23.0 §④ F7**：标题去「<80」偏概全（degraded
    /// 非 <80 专属）；回退值随实际写值参数化（%lld）。
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
            Text(CellarL10n.s("panel.sub80.degraded.banner", degradedWriteValue))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 0.21.0 §2.2 迟滞执法横幅（单行——备用断电保护通道挂载中；约 1 循环/天成本
    /// 告知同行承载，§2.3。warning 弱化底色语汇；0.23.0 §⑤ 措辞去「实验性/CHIE」）。
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

    /// 回落进度行（「回落中 82%→75%」——不承诺时长；monospacedDigit 数值）。
    /// 0.21.2 §1：渲染体移交共享子组件 Sub80FallingProgressRow（仪表板电量卡
    /// 双宿主复用）——本组件内渲染形态逐字节同源，既有 golden 零 diff。
    private func fallingLine(from: Int, target: Int) -> some View {
        Sub80FallingProgressRow(from: from, target: target)
    }
}
