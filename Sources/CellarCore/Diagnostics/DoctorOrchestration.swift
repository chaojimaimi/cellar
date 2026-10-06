import Foundation

// MARK: - 检查 17：编排通道（doctor 第 17 项；照 DoctorExtended.swift 的
// extension DoctorReportGenerator 先例拆分——DoctorReport.swift 行数纪律）
//
// **0.23.0 §② Shortcuts 备用通道退役（红队 F2 语义真空修复）**：执行通道收敛为
// 「App 内嵌 set 通道（唯一）」——原 shortcuts 探测三分支（OrchestrationDoctorProbe
// `shortcuts list`）随批退役（快捷指令无消费者，不再指引创建）；判定门 = MCL 读回
// 探测（检查 19/20 同源输入，CLI 用户会话组装）。

extension DoctorReportGenerator {
    /// 检查 17（判定收敛版）。门 = `mclProbeAttempted`（MCL 读回探测与检查 19/20
    /// 同源——CLI 用户会话组装，非 root 读级可用）。判定：
    /// - 27 ∧ MCL 可读 → PASS「执行通道：App 内嵌 set 通道（唯一）」；
    /// - 27 ∧ MCL 探测在位但不可读 → INFO（set 通道不可用——限充执法由域通道承接
    ///   〔<80 / 编排关域承载〕，退路 = 系统设置手动设具体上限；不抬退出码）；
    /// - 27 ∧ MCL 探测缺席（输入形态缺省）→ INFO 未探测；
    /// - 26（<27）→ INFO（26 无 App 内嵌 set 面——daemon CHTE 直控执法，本检查
    ///   不适用；诚实呈现，不抬退出码）。
    static func orchestrationChannel(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.mclProbeAttempted else { return nil }
        if inputs.osMajorVersion >= 27 {
            guard let mcl = inputs.mclProbe else {
                return DoctorCheck(
                    name: "编排通道", status: .info,
                    detail: "App 内嵌 set 通道未探测（输入形态缺省）"
                )
            }
            if mcl.readable {
                let limitText = mcl.limit.map { "（读回 \($0)%）" } ?? ""
                return DoctorCheck(
                    name: "编排通道", status: .pass,
                    detail: "执行通道：App 内嵌 set 通道（唯一）——原生限充 set 路径可用\(limitText)"
                )
            }
            return DoctorCheck(
                name: "编排通道", status: .info,
                detail: "App 内嵌 set 通道不可用（\(mcl.failureDetail ?? "未知原因")）——限充执法由域通道承接；如需即时调整可在系统设置手动设置上限"
            )
        }
        return DoctorCheck(
            name: "编排通道", status: .info,
            detail: "App 内嵌 set 通道仅 macOS 27+ 可用——本机由 daemon 直控执法，本检查不适用"
        )
    }
}
