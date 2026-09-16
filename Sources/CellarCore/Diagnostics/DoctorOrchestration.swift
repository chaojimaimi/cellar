import Foundation

// MARK: - v0.19.20 检查 17：编排通道（doctor 第 17 项；照 DoctorExtended.swift 的
// extension DoctorReportGenerator 先例拆分——DoctorReport.swift 行数纪律）

/// 检查 17 输入：编排通道探测（CLI DoctorCommand 在**用户会话**组装；S2：root 恒
/// 失败——本探测永不下放 daemon）。
public struct OrchestrationDoctorProbe: Equatable, Sendable {
    /// `shortcuts list` 是否执行成功（exit 0 = 通道可用）。
    public let listSucceeded: Bool
    /// 列表中的快捷指令总数（执行成功时；失败 nil）。
    public let shortcutCount: Int?
    /// 默认动作（NativeOrchestration.defaultShortcutName）是否在列表中
    /// （执行成功时；失败 nil）。
    public let defaultShortcutPresent: Bool?
    /// 执行失败详情（stderr 摘要；成功 nil）。
    public let failureDetail: String?

    public init(
        listSucceeded: Bool, shortcutCount: Int?,
        defaultShortcutPresent: Bool?, failureDetail: String?
    ) {
        self.listSucceeded = listSucceeded
        self.shortcutCount = shortcutCount
        self.defaultShortcutPresent = defaultShortcutPresent
        self.failureDetail = failureDetail
    }
}

extension DoctorReportGenerator {
    /// `shortcuts list` 用户上下文探测（探测组装必须在 CLI 用户会话完成——S2：
    /// root 恒失败，禁止移入 daemon）。判定：默认动作在列 → PASS（通道可用）；
    /// 列表可用但缺动作 → INFO（指引创建）；执行失败 → INFO 不抬退出码（26 及
    /// 以下机型 / 快捷指令 App 缺席属预期形态，非健康失败）。
    static func orchestrationChannel(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.orchestrationProbeAttempted else { return nil }
        guard let probe = inputs.orchestrationProbe else {
            return DoctorCheck(
                name: "编排通道", status: .info,
                detail: "编排通道未探测（输入形态缺省）"
            )
        }
        guard probe.listSucceeded else {
            return DoctorCheck(
                name: "编排通道", status: .info,
                detail: "shortcuts list 执行失败（\(probe.failureDetail ?? "未知原因")）——编排不可用"
            )
        }
        let countText = probe.shortcutCount.map(String.init) ?? "未知"
        if probe.defaultShortcutPresent == true {
            return DoctorCheck(
                name: "编排通道", status: .pass,
                detail: "编排通道可用（已找到「\(NativeOrchestration.defaultShortcutName)」，共 \(countText) 个快捷指令）"
            )
        }
        return DoctorCheck(
            name: "编排通道", status: .info,
            detail: "shortcuts list 可用，但未找到「\(NativeOrchestration.defaultShortcutName)」"
                + "——请按 Cellar 通用页「充电编排」节的指引创建（共 \(countText) 个快捷指令）"
        )
    }
}
