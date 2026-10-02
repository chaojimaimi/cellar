import Foundation

// MARK: - 0.21.0 §1.3/§1.5 检查 19/20：MCL 残留检测（doctor 第 19/20 项；照
// DoctorOrchestration.swift 的 extension DoctorReportGenerator 先例拆分——
// DoctorReport.swift 行数纪律）
//
// 两项均 27 门控（MCL 读回仅在 set 路径语境有语义——26 上 Cellar 从不写 MCL，
// 读回值是系统自有状态，检测必属误报）且 info 恒不抬退出码（残留诊断非故障）。
// R3-P3-3：27 无 actionTrack——「非 fullOnce 在轨」条件恒真，**如实省略**，
// 不为此造假轨道判定（fullOnce 窗内运行 doctor 报 INFO 属已知形态，恢复指引
// 文案即处置路径）。

extension DoctorReportGenerator {
    /// 检查 19（§1.3）：fullOnce 临时放开残留——MCL 读回 100 ∧ policy < 100
    /// （判定源与面板恢复臂同式：NativeLimitSet.fullOnceRestoreAvailable，读回
    /// 驱动非轨道判定）→ INFO + 恢复指引。渲染条件：27 ∧ daemon 在线 ∧ 编排终态
    /// ∧ mode active ∧ 编排开关开（开关关时读回 100 属 §1.5 关断期望态——检查
    /// 20 承接，本项不双报）∧ MCL 读回在位。
    static func fullOnceResidual(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.mclProbeAttempted, inputs.osMajorVersion >= 27,
              let mcl = inputs.mclProbe, mcl.readable, let readback = mcl.limit,
              let status = inputs.daemonStatus,
              status.capabilities?.contains(DaemonXPC.capabilityOrchestration) == true,
              status.mode == "active",
              status.orchestration?.enabled == true
        else { return nil }
        guard NativeLimitSet.fullOnceRestoreAvailable(
            mclReadback: readback, policyUpperLimit: status.upperLimit
        ) else { return nil }
        return DoctorCheck(
            name: "临时放开残留", status: .info,
            detail: "原生限充读回 100% 而策略上限 \(status.upperLimit)%——临时放开未恢复"
                + "（若刚点击「充满一次」属预期形态）。请在 Cellar 面板点击「恢复限充」，"
                + "或调整上限/重开限充自动收敛"
        )
    }

    /// 检查 20（§1.5）：关断残留——期望值派生（NativeLimitSet.shutdownExpectation，
    /// 0.21.1 §2.2 重定版：mode 关恒 100 / 编排关 ∧ target <80 → 80（原生限充
    /// 兜底保留）/ **编排关 ∧ target ≥80 → nil（编排关不断域——域随写 target
    /// 覆盖全区间，不再渲染）**），MCL 读回 ≠ 期望 → INFO 指引。
    /// 读回缺席（探测失败/类缺席）→ 不渲染（读通道死态无对账可言——诚实缺席）；
    /// 期望 nil（正常执行态/编排关 ≥80）→ 不渲染。
    static func shutdownResidual(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.mclProbeAttempted, inputs.osMajorVersion >= 27,
              let mcl = inputs.mclProbe, mcl.readable, let readback = mcl.limit,
              let status = inputs.daemonStatus
        else { return nil }
        guard let expected = NativeLimitSet.shutdownExpectation(
            modeActive: status.mode == "active",
            orchestrationEnabled: status.orchestration?.enabled == true,
            upperLimit: status.upperLimit
        ) else { return nil }
        if readback == expected {
            return DoctorCheck(
                name: "关断残留", status: .pass,
                detail: "关断对账一致（读回 \(readback)%，期望 \(expected)%）"
            )
        }
        return DoctorCheck(
            name: "关断残留", status: .info,
            detail: "MCL 读回 \(readback)% 与关断期望值 \(expected)% 不符"
                + "（App 缺席窗残留——daemon 侧关断无法写 MCL，已登记局限）。"
                + "打开 Cellar App 将自动对账补偿，或手动在系统设置调整充电上限"
        )
    }
}
