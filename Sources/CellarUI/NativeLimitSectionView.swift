import CellarCore
import SwiftUI

// MARK: - 原生限充呈现（Phase 5 v1.7 M3 方案 §4.1；**参数驱动**——CellarUICheck
// 仅 import CellarCore/CellarUI，App 侧薄桥接 StatusController；照 AlertBanner/
// FanSectionView 先例）：
// - 注记行：nativeLimit.active == true 且 manualSocLimit 非 nil 时展示「系统限充
//   N% 生效中」（N = daemon 注册态 manualSocLimit，§4.1 消费口径分工）——注记行
//   不抢主状态（仪表板状态徽章/停充语义零改动，并存不互斥）；
// - 冲突横幅：manualSocLimit > Cellar 上限时展示轻提示 + 「打开系统电池设置」
//   深链按钮（视觉语言照 AlertBanner：bannerBackground + 圆角 6 轻横幅）。
// 呈现与否的判定全在 App 侧（三态 known=false 不渲染由调用方守门）——组件只做
// 纯展示，快照矩阵可直接构造（§4.3 新增 2 态 × 3 风格 × 2 方案）。

/// 原生限充注记行（仪表板电源段状态区）。
///
/// N 串经词汇表格式占位填充：theme.word(.nativeLimitNote) 值含 `%lld%%` 占位
/// （catalog 与 nativeConstant 兜底同形），消费侧 String(format:) 填充——动态 N
/// 不进 LocalizationValue 插值（先取词再格式化，bb6eb0d 同类陷阱规避）。
/// residual（v0.19.20 WP-6）：27 上 plist = 「任务注册残留」非「现行上限」（S4
/// 实证）→ 渲染「注册残留 N%（非现行上限）」INFO 形态（l10n 承载——不走风格
/// 词汇表，避免三风格词条表扩面）。
public struct NativeLimitNoteRow: View {
    /// 手动策略限充值（daemon 注册态 manualSocLimit；仅作展示参数，判定在调用方）。
    public let socLimit: Int
    /// 27 残留形态（osMajorVersion >= 27 时由调用方传入；默认 false = 26- 现行
    /// 语义零变化）。
    public let residual: Bool

    @Environment(\.cellarTheme) private var theme

    public init(socLimit: Int, residual: Bool = false) {
        self.socLimit = socLimit
        self.residual = residual
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: residual ? "clock.arrow.circlepath" : "bolt.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.accent)
            // 残留形态走 l10n 单源（%lld 占位与词汇表同形消费）；现行形态保持
            // 词汇表通路（三风格差异化语汇保留）。
            Text(residual
                 ? CellarL10n.s("dashboard.nativeLimit.residualNote", socLimit)
                 : String(format: theme.word(.nativeLimitNote), socLimit))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 原生限充冲突横幅（仪表板横幅区轻提示行 + 深链按钮）。
///
/// 文案组件内自持（dashboard.nativeLimit.conflict，双 N/M 占位）；深链动作由
/// App 注入（NSWorkspace.open x-apple.systemsettings:com.apple.settings.battery，
/// URL 判空降级在 App 侧）——组件零 AppKit 依赖。
public struct NativeLimitConflictBanner: View {
    /// 原生手动限充值（N；仅展示参数）。
    public let nativeSocLimit: Int
    /// Cellar 上限（M；仅展示参数）。
    public let cellarLimit: Int
    /// 深链回调（App 侧 NSWorkspace.open）。
    public let onOpenSettings: () -> Void

    @Environment(\.cellarTheme) private var theme

    public init(
        nativeSocLimit: Int,
        cellarLimit: Int,
        onOpenSettings: @escaping () -> Void
    ) {
        self.nativeSocLimit = nativeSocLimit
        self.cellarLimit = cellarLimit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HStack(spacing: 8) {
            // 轻提示（非告警级）：描边三角 + warning 色——与 AlertBanner 的
            // 填充红三角（失败语义）区隔。
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.warning)
            Text(CellarL10n.s("dashboard.nativeLimit.conflict", nativeSocLimit, cellarLimit))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(theme.word(.nativeLimitOpenSettings), action: onOpenSettings)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bannerBackground, in: RoundedRectangle(cornerRadius: 6))
    }
}
