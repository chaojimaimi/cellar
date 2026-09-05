// CellarCoreCheck —— Phase 5 v1.5 doctor 热暂停配置检查项场景域（方案 §2.2 doctor
// 检查 13 / §2.4 组装项；与 ThermalPolicyDomain.swift 同域拆分——FanDoctorDomain
// 先例，使各文件保持在 400 行内）

import CellarCore
import Foundation

/// doctor 检查 13 fixture（照 FanDoctorDomain 基准输入形态）。
private func thermalDoctorInputs(
    thermal: ThermalStatus?, daemonStatus: DaemonStatus? = nil, attempted: Bool = true
) -> DoctorInputs {
    DoctorInputs(
        isRoot: true, smcConnected: true,
        probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
        chargingEnabled: false, chargingError: nil,
        snapshot: nil, snapshotError: nil,
        conflict: ConflictScanResult(exact: [], generic: []),
        daemonStatus: daemonStatus,
        thermal: thermal,
        thermalProbeAttempted: attempted
    )
}

// MARK: - doctor thermalConfig 组装（方案 §2.4；5 场景）
/// doctor 热配置场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runThermalDoctorDomainScenarios() throws {
    // 医生热-1：thermalProbeAttempted=false → 检查不渲染（既有十二项断言零回归）。
    do {
        let report = DoctorReportGenerator.generate(
            thermalDoctorInputs(thermal: nil, attempted: false)
        )
        check(!report.checks.contains { $0.name == "热暂停配置" },
              "医生热-1", "未探测 → 不渲染（条件渲染兼容，照检查 9-12 先例）")
    }
    // 医生热-2：默认配置 → PASS「≥40.0°C 暂停 / 滞回 3.0°C（默认…）」。
    do {
        let report = DoctorReportGenerator.generate(thermalDoctorInputs(thermal: ThermalStatus()))
        let item = report.checks.first { $0.name == "热暂停配置" }
        check(item?.status == .pass && item?.detail.contains("≥40.0°C 暂停 / 滞回 3.0°C") == true
                && item?.detail.contains("（默认") == true,
              "医生热-2", "默认配置 → PASS + 默认标注（验收判据字面）")
        check(item?.detail.contains("与风扇阈值相互独立") == true,
              "医生热-2", "文案明示两套配置独立（UD-6）")
    }
    // 医生热-3：自定义配置 →「（自定义」标注（38.0/5.0）。
    do {
        let report = DoctorReportGenerator.generate(
            thermalDoctorInputs(thermal: ThermalStatus(pauseCentiC: 3800, hysteresisCentiC: 500))
        )
        let item = report.checks.first { $0.name == "热暂停配置" }
        check(item?.status == .pass && item?.detail.contains("≥38.0°C 暂停 / 滞回 5.0°C") == true
                && item?.detail.contains("（自定义") == true,
              "医生热-3", "自定义配置 → PASS + 自定义标注（阈值平移可见化）")
    }
    // 医生热-4：daemon 未运行（thermal nil ∧ daemonStatus nil）→ INFO。
    do {
        let report = DoctorReportGenerator.generate(thermalDoctorInputs(thermal: nil))
        let item = report.checks.first { $0.name == "热暂停配置" }
        check(item?.status == .info && item?.detail.contains("未运行，无法读取热配置") == true,
              "医生热-4", "daemon 缺席 → INFO「未运行，无法读取热配置」（info 不抬退出码——该性质由既有用例 66 钉死）")
    }
    // 医生热-5：在线但未上报两键 = 旧 daemon（R-4）→ INFO 升级提示。
    do {
        let oldDaemon = DaemonStatus(version: "0.9.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2)
        let report = DoctorReportGenerator.generate(thermalDoctorInputs(thermal: nil, daemonStatus: oldDaemon))
        let item = report.checks.first { $0.name == "热暂停配置" }
        check(item?.status == .info && item?.detail.contains("旧版本 daemon") == true,
              "医生热-5", "旧 daemon 在线 → INFO 升级提示（与「未运行」措辞区分）")
    }
}
