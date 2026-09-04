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
    /// 数据起始（保留窗内首桶时刻，页头「记录自」徽章；nil = 库空）。
    @State private var firstSampleDate: Date?
    /// 最大容量趋势序列（≥2 点才显示卡片——数据积累如实，R-5）。
    @State var capacityPoints: [CapacityPoint] = []
    /// 当前范围（断档判定需读 bucketSeconds——StatsPageViewCards 投影消费）。
    @State var rangeWindow: RangeWindow = .hours24
    @State private var isLoading = true

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
                    batteryCard
                    temperatureCard
                    powerCard
                    if capacityPoints.count >= 2 {
                        capacityCard
                    }
                }
            }
            .padding(24)
            // 页面容器纪律：照充电控制页（maxWidth 720，宽窗不无限拉伸）。
            .frame(maxWidth: 720, alignment: .leading)
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
        // 范围快速切换：被取消的旧任务在恢复主线程后放弃写态，防旧结果覆盖新范围。
        if Task.isCancelled { return }
        firstSampleDate = overviewBuckets.first?.start
        capacityPoints = overviewBuckets.compactMap { bucket in
            bucket.avgMaxCapacityPercent.map { CapacityPoint(date: bucket.start, percent: $0) }
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
            sinceBadge
            Spacer()
        }
    }

    /// 数据起始徽章（「记录自 M月d日」chip；库空 → 「采样累积中」）。
    private var sinceBadge: some View {
        chip(sinceBadgeText)
    }

    private var sinceBadgeText: String {
        guard let firstSampleDate else { return CellarL10n.s("stats.empty.title") }
        return CellarL10n.s("stats.since", firstSampleDate.formatted(.dateTime.month().day()))
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
            }
        }
    }

    /// 普通 chip（secondaryText 字 + 描边胶囊，照 DashboardView lowPowerChip）。
    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryText)
            .padding(.vertical, 3)
            .padding(.horizontal, 10)
            .overlay(Capsule().strokeBorder(theme.secondaryText.opacity(0.45)))
    }

    // MARK: - 面板容器（照仪表板 panel 形态；曲线卡消费，StatsPageViewCards）

    /// 面板卡（DashboardView.panel 同款：surface 底 + 描边 + 圆角 18 + 小标题行；
    /// 高度 220 适配单曲线卡）。
    func panel(title: String, subtitle: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(theme.secondaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background {
            if let panelBackground = theme.panelBackground { panelBackground }
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.secondaryText.opacity(0.25)))
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
