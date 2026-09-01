import CellarCore
import SwiftUI

/// 告警横幅（WP4 规格 §2.7 置顶三分支，条件呈现）：
/// ① transferFailed 且存在 lastAttempt → 摘要 +「重试」（重发上次动作）
/// ② daemonRejected / staleDaemon → 确定性失败，**无重试按钮**（stale 显重装指引）
/// ③ 轮询致 unreachable 且无控制反馈（无上次动作语义）→「重试」= 立即刷新
/// 成功反馈（下一次 .success）自动清除横幅（本视图对 success/none 不渲染）。
struct AlertBanner: View {
    let feedback: ControlFeedback?
    let connection: ConnectionState
    let lastAttemptSummary: String?
    let onRetry: () -> Void
    @Environment(\.cellarTheme) private var theme

    var body: some View {
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
                        .accessibilityLabel("重试：\(content.message)")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bannerBackground, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// 三分支判定（优先级：控制反馈分支 ①② > 轮询失联分支 ③）。
    private var bannerContent: (message: String, retryTitle: String?)? {
        switch feedback {
        case .transferFailed:
            if let summary = lastAttemptSummary {
                return ("上次动作未送达（\(summary)）：守护进程未运行或无响应", "重试")
            }
            // 理论不可达（runControl 入口必记 lastAttempt）；防 nil 直落分支 ③ 判定。
            return nil
        case .daemonRejected(let message):
            return (message, nil)
        case .staleDaemon:
            return ("守护进程版本过旧，请卸载后重新安装。先点下方「卸载守护进程」，再点「安装守护进程」", nil)
        case .success, .none:
            break
        }
        if connection == .unreachable {
            return ("守护进程失联，无法获取策略状态", "重试")
        }
        return nil
    }
}