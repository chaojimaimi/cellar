import CellarCore
import CellarUI
import Foundation

// MARK: - MagSafe LED 独立轻路径（v1.10 M2 外迁，方案 §0-T2 D-2b）

extension StatusController {

    /// MagSafe LED 状态（nil = 旧 daemon → 通用页 LED 节整体隐藏/升级提示，
    /// 照 fanStatus 版本门控先例；supported=false = 本机不支持或检测未决）。
    /// v1.10 M2 自 StatusController.swift 随 LED 域整段外迁（行为零变化——同一
    /// daemonStatus 派生读取）。
    var magSafeLedStatus: MagSafeLEDStatus? {
        daemonStatus?.magSafeLed
    }

    /// MagSafe LED 模式设置（自 runControl 外迁的独立路径；照 runControl 的
    /// Task.detached → MainActor.run 回包形态，主线程纪律同款）：
    /// - **不进全局 busy**：LED 往返期间通用页风扇/热保护滑杆不再随 busy 门闪灰
    ///   （本批修复目标）；LED 节自身禁用源 = busy || magSafeLedPending（OR 接法，
    ///   GeneralSections 构造点）。
    /// - **单槽隔离三条（R1 P1-3 定死）**：不写 lastAttempt（重试 = 重选 Picker，
    ///   重试槽保持「全局通道最近一次」语义不被 LED 污染）；不写全局
    ///   controlFeedback（横幅归属隔离——LED 失败提示不被后续风扇控制的
    ///   controlFeedback = nil 入口清掉，风扇控制也不覆盖 LED 提示）；错误分型走
    ///   公共 helper classifyControlFailure（不复制）。
    /// - **反馈生命周期（R2 P3 定版）**：发起即清旧提示；成功 5s 自动清（照
    ///   setSuccessFeedback 先例）；失败常驻至下次 LED 操作。
    /// 值域白名单在 daemon 臂，App 侧只发合法枚举（单键幂等，与原 runControl 路径
    /// 同一 XPC 命令——语义零变化）。
    func setMagSafeLed(_ mode: MagSafeLEDMode) {
        guard !magSafeLedPending else { return }
        magSafeLedPending = true
        magSafeLedFeedback = nil
        let rawMode = mode.rawValue
        Task.detached { [weak self] in
            let result: Result<DaemonStatus, DaemonClientError>
            do {
                result = .success(try DaemonXPCClient().setMagSafeLed(rawMode))
            } catch let error as DaemonClientError {
                result = .failure(error)
            } catch {
                // 协议域外错误（编码失败等）：按 daemon 拒绝呈现，不静默（同 runControl）。
                result = .failure(.daemonError(String(describing: error)))
            }
            await MainActor.run {
                self?.finishMagSafeLed(result: result)
            }
        }
    }

    /// LED 回包处理（主 actor）：成功 → ingest 状态更新（全节滑杆自同步通路的
    /// 数据源）+ 成功轻提示；失败 → 公共分型 helper，分型结果写 magSafeLedFeedback
    /// （daemonError 情形 stale 判定结果同样写 LED 提示而非全局横幅；
    /// timeout/connectionFailed 的 connection=.unreachable 在 helper 内置位——
    /// 语义共享），常驻至下次 LED 操作。
    private func finishMagSafeLed(result: Result<DaemonStatus, DaemonClientError>) {
        magSafeLedPending = false
        switch result {
        case .success(let status):
            ingest(status: status)
            showLedFeedback(CellarL10n.s("status.summary.setMagSafeLed"))
        case .failure(let error):
            // 失败常驻：先撤在途成功消退计时，防陈旧计时器语义混淆。
            magSafeLedFeedbackClearTask?.cancel()
            classifyControlFailure(error) { [weak self] verdict in
                guard let self else { return }
                switch verdict {
                case .staleDaemon:
                    self.magSafeLedFeedback = CellarL10n.s("panel.banner.staleDaemon")
                case .daemonRejected(let message):
                    self.magSafeLedFeedback = message
                case .transferFailed:
                    // 传输失败语义共享（connection 已被 helper 置 .unreachable）；
                    // LED 提示用无摘要版失联文案（transferFailed 全局版带
                    // lastAttempt 摘要 + 重试钮——LED 路径不占重试槽）。
                    self.magSafeLedFeedback = CellarL10n.s("panel.banner.unreachable")
                case .success:
                    break   // 分型 helper 不产出 success（穷举臂占位）
                }
            }
        }
    }

    /// LED 成功轻提示 + 5s 自动消退（照 setSuccessFeedback 先例：新成功重置计时；
    /// 失败/常驻提示不被陈旧计时器误清——消退守卫 = 当前提示仍是本条成功文案）。
    private func showLedFeedback(_ message: String) {
        magSafeLedFeedbackClearTask?.cancel()
        magSafeLedFeedback = message
        magSafeLedFeedbackClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self, self.magSafeLedFeedback == message else { return }
            self.magSafeLedFeedback = nil
        }
    }
}
