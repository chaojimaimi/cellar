// CellarCoreCheck —— Phase 5 v1.1 风扇 doctor 检查项场景域（方案 §8 CLI 段 /
// §11 验收可见化；与 FanDomain.swift 同域拆分——DoctorExtendedDomain 先例，
// 使 FanDomain.swift 保持在 800 行硬上限内）
//
import CellarCore
import Foundation

// MARK: - ⑦ doctor 风扇检查项（方案 §8 CLI 段 / §11 验收可见化；5 场景）
func runFanDoctorScenarios() {
    // 医生风-1：fanProbe 缺省 → 检查不渲染（既有到十二项断言零回归）。
    do {
        let inputs = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: [])
        )
        let report = DoctorReportGenerator.generate(inputs)
        check(!report.checks.contains { $0.name == "风扇控制" }, "医生风-1", "fanProbe 缺省 → 不渲染（条件渲染兼容）")
    }
    // 医生风-2：键全在位 + F0Md=0（系统自动）→ PASS。
    do {
        let inputs = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            fanProbe: FanDoctorProbe(
                keysPresent: ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"],
                mdValue: 0, tgRPM: 1350,
                config: FanStatus(
                    enabled: false, strategy: .constantSpeed, state: .off,
                    targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700, conflictFlag: false
                )
            )
        )
        let report = DoctorReportGenerator.generate(inputs)
        let checkItem = report.checks.first { $0.name == "风扇控制" }
        check(checkItem?.status == .pass && checkItem?.detail.contains("F0Md=0") == true,
              "医生风-2", "键在位 + F0Md=0 → PASS（现态可见化：Tg≈1350rpm）")
    }
    // 医生风-3：F0Md≠0（疑似残留）→ WARN（异常现态可见化——§6.5 残留窗口收口佐证）。
    do {
        let inputs = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            fanProbe: FanDoctorProbe(
                keysPresent: ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"],
                mdValue: 1, tgRPM: 3350, config: nil
            )
        )
        let report = DoctorReportGenerator.generate(inputs)
        let checkItem = report.checks.first { $0.name == "风扇控制" }
        check(checkItem?.status == .warn && checkItem?.detail.contains("F0Md=1") == true,
              "医生风-3", "F0Md=1（非系统自动）→ WARN（显式提示，不静默）")
    }
    // 医生风-4：核心键缺失 → INFO（本机不支持属预期，非健康失败）。
    do {
        let inputs = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            fanProbe: FanDoctorProbe(keysPresent: ["F0Mn"], mdValue: nil, tgRPM: nil, config: nil)
        )
        let report = DoctorReportGenerator.generate(inputs)
        let checkItem = report.checks.first { $0.name == "风扇控制" }
        check(checkItem?.status == .info, "医生风-4", "F0Tg/F0Md 缺失 → INFO（无风扇控制键 = 不支持，不抬退出码）")
    }
    // 医生风-5（P3-6）：风扇配置开启（enabled）时的 F0Md=1 是合法介入态（boost
    // 两步写的第一步行进中）——降级 INFO 措辞，避免硬件验收并发项（§11 项 2/6）
    // 误报 WARN；关闭/无配置态才按残留嫌疑 WARN。
    do {
        let inputs = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            fanProbe: FanDoctorProbe(
                keysPresent: ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"],
                mdValue: 1, tgRPM: 3350,
                config: FanStatus(
                    enabled: true, strategy: .constantSpeed, state: .boost,
                    targetRPM: 3350, currentRPM: 3300, thresholdCentiC: 3700, conflictFlag: false
                )
            )
        )
        let report = DoctorReportGenerator.generate(inputs)
        let checkItem = report.checks.first { $0.name == "风扇控制" }
        check(checkItem?.status == .info && checkItem?.detail.contains("策略介入中") == true,
              "医生风-5", "配置开启 + F0Md=1 → INFO（合法介入态，非残留）")
    }
}
