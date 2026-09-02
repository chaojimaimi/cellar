import CellarCore
import SwiftUI

/// 告警横幅（WP4 规格 §2.7 置顶分支，条件呈现）：
/// ① transferFailed 且存在 lastAttempt → 摘要 +「重试」（重发上次动作）
/// ② daemonRejected / staleDaemon → 确定性失败，**无重试按钮**（stale 显重装指引）
/// ③ status 派生失败横幅（WP5 §2.3 P1-1 配套）：enforce:error / enforce:verifyFailed
///    → 无重试（失败来自 daemon 侧持续态，重试语义不适用；不占用 ① ② 通道）
/// ④ 轮询致 unreachable 且无控制反馈（无上次动作语义）→「重试」= 立即刷新
/// 成功反馈（下一次 .success）自动清除横幅（本视图对 success/none 不渲染）。
///
/// ⚠️ WP4 下沉接口注记：原参数 `statusFailure: StatusFailureKind?` 改注入
/// **文案** `statusFailureMessage: String?`——StatusFailureKind 迁 CellarCore 时
/// 按硬事实 3 判据剥离 `.message`（文案常量留 App/NotificationService，CellarUI
/// 不持有 App 域文案）；App 调用面传 `statusFailure?.message`，分支判定与优先级
/// （①② > ③ > ④）逐字保持，零行为变化。S3 后横幅文案与重试/AX 串全部经
/// CellarL10n（panel.banner.* / panel.ax.* / common.retry，与通知同 catalog）。
public struct AlertBanner: View {
    let feedback: ControlFeedback?
    let connection: ConnectionState
    let lastAttemptSummary: String?
    /// status 派生失败横幅文案（WP5；daemonStatus.lastAction 失败串，首次样本即
    /// 呈现——App 层自 StatusFailureKind.message 投影）。
    let statusFailureMessage: String?
    let onRetry: () -> Void
    @Environment(\.cellarTheme) private var theme

    public init(
        feedback: ControlFeedback?,
        connection: ConnectionState,
        lastAttemptSummary: String?,
        statusFailureMessage: String?,
        onRetry: @escaping () -> Void
    ) {
        self.feedback = feedback
        self.connection = connection
        self.lastAttemptSummary = lastAttemptSummary
        self.statusFailureMessage = statusFailureMessage
        self.onRetry = onRetry
    }

    public var body: some View {
        if let content = bannerContent {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.alert)
                Text(content.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let retryTitle = content.retryTitle {
                    Button(retryTitle, action: onRetry)
                        .controlSize(.small)
                        .accessibilityLabel(CellarL10n.s("panel.ax.retry", content.message))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bannerBackground, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 分支判定（优先级：控制反馈分支 ①② > status 派生失败 ③ > 轮询失联 ④）。
    /// ⚠️ 文案经 CellarL10n 解析（catalog 随组件库下沉；品牌名/数字排版不进串）。
    private var bannerContent: (message: String, retryTitle: String?)? {
        switch feedback {
        case .transferFailed:
            if let summary = lastAttemptSummary {
                return (CellarL10n.s("panel.banner.transferFailed", summary), CellarL10n.s("common.retry"))
            }
            // 理论不可达（runControl 入口必记 lastAttempt）；防 nil 直落分支 ④ 判定。
            return nil
        case .daemonRejected(let message):
            return (message, nil)
        case .staleDaemon:
            return (CellarL10n.s("panel.banner.staleDaemon"), nil)
        case .success, .none:
            break
        }
        if let statusFailureMessage {
            return (statusFailureMessage, nil)
        }
        if connection == .unreachable {
            return (CellarL10n.s("panel.banner.unreachable"), CellarL10n.s("common.retry"))
        }
        return nil
    }
}