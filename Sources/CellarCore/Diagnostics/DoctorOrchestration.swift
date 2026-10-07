import Foundation

// MARK: - 检查 17：执行通道（doctor 第 17 项；照 DoctorExtended.swift 的
// extension DoctorReportGenerator 先例拆分——DoctorReport.swift 行数纪律）
//
// **0.23.1 编排退役（常规 P2-2 改判保留）**：原「编排通道」检查探测对象实为
// MCL set 可用性——W4 残余对账车道与恢复链仍在消费，**保留改文案**：探测对象
// 语义更名「执行通道（恢复/对账用）」。编排断言执行面已随批退役（daemon 域
// 承载单通道），set 通道剩余职责 = 恢复链（restoreChargeLimit 后的 App 侧
// max(target,80) 开启垫脚石写）与 W4 对账补偿。

extension DoctorReportGenerator {
    /// 检查 17（0.23.1 改文案版）。门 = `mclProbeAttempted`（MCL 读回探测与
    /// 检查 20 同源——CLI 用户会话组装，非 root 读级可用）。判定：
    /// - 27 ∧ MCL 可读 → PASS「执行通道（恢复/对账用）：App 内嵌 set 通道」；
    /// - 27 ∧ MCL 探测在位但不可读 → INFO（set 通道不可用——限充执法由域通道
    ///   承接〔域承载全区间〕，退路 = 系统设置手动设具体上限；不抬退出码）；
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
                    detail: "执行通道（恢复/对账用）：App 内嵌 set 通道——原生限充 set 路径可用\(limitText)"
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
