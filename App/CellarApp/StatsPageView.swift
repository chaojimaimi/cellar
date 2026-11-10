import CellarCore
import CellarUI
import Charts
import SwiftUI

// MARK: - 采样器注入（组合根 → 统计页）

private struct StatsSamplerKey: EnvironmentKey {
    /// 缺省 nil：仅检查工具等未注入上下文落到空态；App 在 Window scene 注入
    /// 幸存采样器实例（CellarApp.swift），nil 不出现于生产路径。
    static let defaultValue: StatsSampler? = nil
}

extension EnvironmentValues {
    /// 统计采样器（StatsSampler actor）：统计页全部查询经此后台 actor 执行
    /// ——主线程零 SQLite（红线 4）。
    var statsSampler: StatsSampler? {
        get { self[StatsSamplerKey.self] }
        set { self[StatsSamplerKey.self] = newValue }
    }
}

// MARK: - 统计页（方案 §3）

/// 统计页（Phase 5 v1.3 §3，替换 .stats 占位）：页头（页题 + 数据起始徽章）+
/// 范围 chips（24 小时 / 7 天 / 30 天单选）+ 三张 Swift Charts 曲线卡（电量分
/// 状态分色 + MIN/MAX 波动带、窖温、功耗）+ 最大容量趋势卡（≥2 点才显示）+
/// 范围内无数据空态（照 TBD 卡形态）。曲线卡与数据投影在 StatsPageViewCards
/// .swift（本文件组装超 400 行，按分区拆文件——DashboardViewCards 先例）。
///
/// - 查询经 `StatsSampler`（actor）后台执行，结果回主线程渲染（§3.2）；
/// - 桶径映射 = 24h→120 / 7d→1800 / 30d→7200（每曲线 ≤500 点，§2.1）；
/// - 采样断档（睡眠/App 未运行）：空桶跳过 + 投影层按 bucketSeconds 断档分段，
///   曲线跨断档断笔留空不补点不跨连（UD-5，评审 P1-1）。
struct StatsPageView: View {
    @Environment(\.cellarTheme) var theme
    @Environment(\.statsSampler) private var sampler

    /// 查询范围单选（§3.1：默认 24 小时）。
    enum RangeWindow: CaseIterable, Identifiable {
        case hours24, days7, days30

        var id: Self { self }

        /// 回看时长（秒）。
        var lookbackSeconds: TimeInterval {
            switch self {
            case .hours24: return 24 * 3600
            case .days7: return 7 * 24 * 3600
            case .days30: return 30 * 24 * 3600
            }
        }

        /// 桶径（§2.1 定版映射）。
        var bucketSeconds: Int {
            switch self {
            case .hours24: return 120
            case .days7: return 1800
            case .days30: return 7200
            }
        }

        /// 能耗桶径（0.22.0 §2.2 能耗卡专属映射——24h→3600s 小时柱 / 7d、30d
        /// →86400s 日柱；与曲线卡桶径解耦）。
        var energyBucketSeconds: Int {
            switch self {
            case .hours24: return 3600
            case .days7, .days30: return 86_400
            }
        }

        var titleKey: String {
            switch self {
            case .hours24: return "stats.range.24h"
            case .days7: return "stats.range.7d"
            case .days30: return "stats.range.30d"
            }
        }
    }

    /// 最大容量趋势点（全保留窗概览查询派生）。
    struct CapacityPoint: Identifiable {
        let date: Date
        let percent: Double
        var id: Date { date }
    }

    /// 概览查询桶径（全保留窗小时桶——起始徽章 + 最大容量趋势派生；断档
    /// 分组阈值同源，StatsPageViewCards 消费）。
    static let overviewBucketSeconds = 3600

    // 曲线数据 @State 跨文件消费（StatsPageViewCards 同 target 扩展）——DashboardView
    // 控制器 internal 同款先例；写入只在下方 refresh（@MainActor）。
    @State var buckets: [StatsBucket] = []
    /// 数据起始（保留窗内首桶时刻，数据累积空区提示口径；nil = 库空）。
    @State private var firstSampleDate: Date?
    /// 最大容量趋势序列（≥2 点才显示卡片——数据积累如实，R-5）。
    @State var capacityPoints: [CapacityPoint] = []
    /// 能耗聚合摘要（0.22.0 §3.2 能耗卡数据源；nil = 尚未查询）。
    @State var energy: EnergySummary?
    /// 最新采样（0.22.0 §3.3 今日 SOC 区间行——dailyMin/MaxSoc 系统键消费源；
    /// 跨文件 internal 同 buckets 先例，StatsPageViewCards 消费）。
    @State var latestSample: StatsSample?
    /// 每日健康行（0.23.17 §2.4 趋势卡数据源——daily_health 全表 day ≤ 今天；
    /// 跨文件 internal 同 buckets 先例，StatsTrendCard 消费）。
    @State var dailyHealthRows: [DailyHealthRow] = []
    /// 当前范围（断档判定需读 bucketSeconds——StatsPageViewCards 投影消费）。
    @State var rangeWindow: RangeWindow = .hours24
    @State private var isLoading = true
    // 0.18 T2 D-2a：四卡 hover 游标态原页级 @State（0.23.8 B3-2 已随卡下沉为
    // StatsPageViewCards.swift 四个卡 struct 的卡级 @State——「各卡独立——共享
    // 会跨卡串显」语义随迁；hover 写入不再触发页级 body 重求值）。

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                rangeChips
                if buckets.isEmpty {
                    if isLoading {
                        loadingCard
                    } else {
                        emptyCard
                    }
                } else {
                    // 四曲线卡（0.23.8 B3-2 hover 下沉为卡 struct——hover 写入
                    // 只重求值所在卡，页级零求值；定义在 StatsPageViewCards.swift）。
                    StatsBatteryCard(theme: theme, buckets: buckets, rangeWindow: rangeWindow,
                                     accumulatingNoteText: accumulatingNoteText)
                    StatsTemperatureCard(theme: theme, buckets: buckets, rangeWindow: rangeWindow,
                                         accumulatingNoteText: accumulatingNoteText)
                    StatsPowerCard(theme: theme, buckets: buckets, rangeWindow: rangeWindow,
                                   accumulatingNoteText: accumulatingNoteText)
                    // energyCard 留页级（无 hover，迁移零收益）。
                    if energyShowsCard {
                        energyCard
                    }
                    if capacityPoints.count >= 2 {
                        StatsCapacityCard(theme: theme, capacityPoints: capacityPoints)
                    }
                    // 健康趋势卡（0.23.17 §2.4，容量卡之后——既有 ≥2 点门控同位置
                    // 模式；三态门槛 .insufficient 卡不渲染——决策点 1 锁定）。
                    if trendShowsCard {
                        StatsTrendCard(theme: theme, dailyRows: dailyHealthRows)
                    }
                }
            }
            .padding(24)
            // 页面容器纪律：照充电控制页（maxWidth 720，宽窗不无限拉伸）。
            .frame(maxWidth: 720, alignment: .leading)
            // 内容列 720 居中：外层撑满窗口宽，宽窗两侧均分留白（滚动条仍贴窗口右缘=macOS 惯例）。
            .frame(maxWidth: .infinity)
        }
        .task(id: rangeWindow) { await refresh() }
    }

    // MARK: - 数据加载（actor 异步 → 回主线程写态）

    /// 刷新（范围切换 / 首次出现）：范围查询 + 全保留窗概览查询各一跳。
    @MainActor
    private func refresh() async {
        isLoading = true
        let now = Date()
        // 上界 +60s：把刚入库的当跳采样圈进 ts < 上界的半开区间。
        let range = now.addingTimeInterval(-rangeWindow.lookbackSeconds)..<now.addingTimeInterval(60)
        let rangeBuckets = await sampler?.query(
            range: range, bucketSeconds: rangeWindow.bucketSeconds
        ) ?? []
        // 概览查询（全保留窗，小时桶）：派生起始徽章（首桶时刻 ≈ 首样本，小时
        // 对齐——日粒度展示无损）与最大容量趋势序列，一跳两得。
        let overviewBuckets = await sampler?.query(
            range: now.addingTimeInterval(-StatsStore.retentionInterval)..<now.addingTimeInterval(60),
            bucketSeconds: Self.overviewBucketSeconds
        ) ?? []
        // 能耗差分聚合（0.22.0 §3.2 第三查询：能耗卡专属桶径）+ 最新采样
        // （今日 SOC 区间行的系统键消费源）。
        let energySummary = await sampler?.energyBuckets(
            range: range, bucketSeconds: rangeWindow.energyBucketSeconds
        )
        let latest = await sampler?.latestSample()
        // 每日健康行（0.23.17 §2.4 趋势卡——daily_health 全表读经 actor 透传）。
        let dailyRows = await sampler?.queryDailyHealth() ?? []
        // 范围快速切换：被取消的旧任务在恢复主线程后放弃写态，防旧结果覆盖新范围。
        if Task.isCancelled { return }
        energy = energySummary
        latestSample = latest
        dailyHealthRows = dailyRows
        firstSampleDate = overviewBuckets.first?.start
        // 口径（v1.8 走查批 F5）：健康度 = 标称满充容量 / 设计容量——MaxCapacity
        // 键在部分 macOS 版本恒 100（语义漂移，BatterySnapshot 注记），旧口径已
        // 失真。新样本走 avgHealthPercent，旧样本（容量列缺席 → nil）回落
        // avgMaxCapacityPercent 兜底；两口径全缺席的桶不产点（空态照旧）。
        capacityPoints = overviewBuckets.compactMap { bucket in
            (bucket.avgHealthPercent ?? bucket.avgMaxCapacityPercent)
                .map { CapacityPoint(date: bucket.start, percent: $0) }
        }
        buckets = rangeBuckets
        isLoading = false
    }

    // MARK: - 页头（照 DashboardView 页头形态）

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(CellarL10n.s("stats.title"))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer()
        }
    }

    /// 范围 chips（照 DashboardView chip 形态：选中态 accent 微底 + accent 字）。
    private var rangeChips: some View {
        HStack(spacing: 8) {
            ForEach(RangeWindow.allCases) { window in
                Button {
                    rangeWindow = window
                } label: {
                    Text(CellarL10n.s(String.LocalizationValue(window.titleKey)))
                        .font(.system(size: 11))
                        .foregroundStyle(rangeWindow == window ? theme.accent : theme.secondaryText)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .background {
                            if rangeWindow == window {
                                Capsule().fill(theme.accent.opacity(0.12))
                            }
                        }
                        .overlay(
                            Capsule().strokeBorder(
                                rangeWindow == window
                                    ? theme.accent.opacity(0.35)
                                    : theme.secondaryText.opacity(0.45)
                            )
                        )
                }
                .buttonStyle(.plain)
                // B7-1 a11y：选中态纯颜色无 trait——读屏用户拿不到选中语义
                // （元数据零像素；ChargeScheduleEntryEditor 星期 chip /
                // MainWindowView 导航行同批三处）。
                .accessibilityAddTraits(rangeWindow == window ? .isSelected : [])
            }
        }
    }

    // MARK: - 数据累积空区提示（0.18 T2 D-2d：「记录自」徽章退役后的信息下沉）

    /// 数据量 < 所选窗 → 「数据累积中（N 天）」提示文本：N = 数据起始到现在的
    /// 天数（向上取整，首日也记 1 天）；数据已填满所选窗 → nil 不渲染；库空 →
    /// nil（空态卡已另呈「采样累积中」，键保留复用）。
    var accumulatingNoteText: String? {
        guard let start = firstSampleDate else { return nil }
        let span = Date().timeIntervalSince(start)
        guard span < rangeWindow.lookbackSeconds else { return nil }
        return CellarL10n.s("stats.accumulating", max(1, Int(ceil(span / 86_400))))
    }

    /// 卡内空区注记（0.23.8 B3-2 后唯一消费点 = 能耗卡——三张 range 卡的注记
    /// 渲染形态已随卡内联等价视图（caption2 + tertiaryText），卡仅持
    /// accumulatingNoteText 文本参数不回读页；容量卡不接——其 X 域恒全保留窗，
    /// 与所选窗口径无关，方案 D-2d「曲线卡」语汇 = 三张 range 卡）。
    var accumulatingNote: some View {
        Group {
            if let accumulatingNoteText {
                Text(accumulatingNoteText)
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    // MARK: - 加载态 / 空态

    /// 加载占位（透明占位 + 居中 ProgressView；查询在后台 actor，仅毫秒级）。
    private var loadingCard: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    /// 空态卡（照 TBDPlaceholder 形态：虚线边框圆角卡 + 图标 + 标题 + 说明）。
    private var emptyCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(theme.tertiaryText)
            Text(CellarL10n.s("stats.empty.title"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Text(CellarL10n.s("stats.empty.hint"))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 44)
        .padding(.horizontal, 48)
        .frame(maxWidth: 460)
        .background {
            if let panelBackground = theme.panelBackground {
                RoundedRectangle(cornerRadius: 18).fill(panelBackground)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.secondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
