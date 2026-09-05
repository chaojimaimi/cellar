import CellarCore
import SwiftUI

/// 上次校准卡内容（Phase 5 v1.4 §3.1；**参数驱动**——CellarUICheck 仅 import
/// CellarCore/CellarUI，App 侧薄包装桥接 StatusController，照 FanSectionView 先例）：
/// - 有记录 → 时间行 + 终态词行（五 outcome 词，与 CalibrationOutcome 五词一一对齐，
///   方案 §7-M3-4）+ 耗时行（startedAt→endedAt，小时分钟粒度）；
/// - 无记录 → 「尚未校准」占位行。
///
/// 墙钟时间文案由 App 侧组装（本地时区钟面语义不进组件——快照注入钉死字面量，
/// golden 跨时区逐字节确定，TBDPlaceholder_stats 先例）；耗时为纯间隔值
/// （Int 秒），组件内格式化跨机确定。个别值缺席 → 「—」（common.nodata）降级，
/// 不猜测语义（照 calibrationPhase 未知串显式 nil 同纪律）。
public struct LastCalibrationView: View {
    /// 上次校准起始墙钟时间行（App 组装；nil = 无记录 → 占位行）。
    public let timeText: String?
    /// 终态词（App 侧 outcome 词 → l10n key 映射；nil → 「—」）。
    public let outcomeText: String?
    /// 耗时秒数（startedAt→endedAt；nil → 「—」）。
    public let durationSeconds: Int?
    /// 首行标题开关（照 CalibrationSectionView showsTitle 先例）：校准页由卡片头
    /// 承担标题时传 false，防同文重复；默认 true——快照矩阵不传此参。
    public let showsTitle: Bool

    @Environment(\.cellarTheme) private var theme

    public init(
        timeText: String? = nil,
        outcomeText: String? = nil,
        durationSeconds: Int? = nil,
        showsTitle: Bool = true
    ) {
        self.timeText = timeText
        self.outcomeText = outcomeText
        self.durationSeconds = durationSeconds
        self.showsTitle = showsTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(CellarL10n.s("calibration.last.title"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
            if timeText == nil {
                // 无记录占位行（如实呈现——校准记录非宝贵资产，首跑前恒空）。
                Text(CellarL10n.s("calibration.last.never"))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else {
                row(CellarL10n.s("calibration.last.time"), timeText)
                row(CellarL10n.s("calibration.last.outcome"), outcomeText)
                row(CellarL10n.s("calibration.last.cost"), durationText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 耗时（小时分钟粒度——6h10m 呈「6 小时 10 分」；不足 1 小时如实呈 0 小时）。
    private var durationText: String? {
        durationSeconds.map {
            CellarL10n.s("calibration.last.duration", $0 / 3600, ($0 % 3600) / 60)
        }
    }

    /// 标签行（标签 secondaryText 弱化 + 值默认前景；值缺席 → 「—」降级）。
    private func row(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            Text(value ?? CellarL10n.s("common.nodata"))
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }
}
