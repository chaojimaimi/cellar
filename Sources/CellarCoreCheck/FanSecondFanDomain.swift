// CellarCoreCheck —— Phase 5 v1.12 双风扇同步接管场景域（方案 §4 M1；与
// FanDoctorDomain 同款「FanDomain 限 800 行」拆分先例）：
// ① FanKey 键名钉 5：F0/F1 十键逐字断言——键名是写硬件寄存器的唯一字符串真相
//   源（FanKey WHY 注记；spike U5' 实证 F1 键族在位，docs/SMC-NOTES.md §10）
// ② FanStatus 第二扇四字段兼容 3：roundtrip 保真 / 旧 daemon JSON 缺键 → nil /
//   缺省 encodeIfPresent 省写（线上形态对 v1.11 旧客户端字节兼容，D5）
import CellarCore
import Foundation

/// v1.12 双风扇场景域入口（runFanDomainScenarios 调用；断言经 MainEntry 的
/// internal 助手）。
func runSecondFanDomainScenarios() throws {
    runFanKeyNamingScenarios()
    try runSecondFanStatusCompatibilityScenarios()
    try runSecondFanDoctorScenarios()
}

/// 通用 DoctorInputs 组装捷径（照 FanDoctorDomain 医生风-2 形态）。
private func secondFanDoctorInputs(fanProbe: FanDoctorProbe) -> DoctorInputs {
    DoctorInputs(
        isRoot: true, smcConnected: true,
        probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
        chargingEnabled: false, chargingError: nil,
        snapshot: nil, snapshotError: nil,
        conflict: ConflictScanResult(exact: [], generic: []),
        fanProbe: fanProbe
    )
}

// MARK: - ③ doctor 检查 12 F1 扩面（v1.12 D6；4 场景）
private func runSecondFanDoctorScenarios() throws {
    let f0Probe = FanDoctorProbe(
        keysPresent: ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"],
        mdValue: 0, tgRPM: 1350, config: nil
    )
    // 医生双扇-1：F1 键在位 + F1Md=0 → PASS 形态，F1 段可见化（双扇接管可用）。
    do {
        let probe = FanDoctorProbe(keysPresent: f0Probe.keysPresent, mdValue: 0, tgRPM: 1350,
                                   config: nil,
                                   keys1Present: ["F1Tg", "F1Md", "F1Ac", "F1Mn", "F1Mx"],
                                   md1Value: 0, tg1RPM: 1522)
        let item = DoctorReportGenerator.generate(secondFanDoctorInputs(fanProbe: probe))
            .checks.first { $0.name == "风扇控制" }
        check(item?.status == .pass && item?.detail.contains("F1 键在位") == true
              && item?.detail.contains("F1Md=0") == true,
              "医生双扇-1", "F1 键在位 + F1Md=0 → 双扇接管可用（Tg≈1522rpm 可见化）")
    }
    // 医生双扇-2：F1Md=1 ∧ 配置关闭 → WARN 残留嫌疑（同 F0 分流语义——异常现态
    // 可见化，§6.5 残留窗口；双扇接管后 F1 也有自己的残留面）。
    do {
        let probe = FanDoctorProbe(keysPresent: f0Probe.keysPresent, mdValue: 0, tgRPM: 1350,
                                   config: nil,
                                   keys1Present: ["F1Tg", "F1Md", "F1Ac", "F1Mn", "F1Mx"],
                                   md1Value: 1, tg1RPM: 3650)
        let item = DoctorReportGenerator.generate(secondFanDoctorInputs(fanProbe: probe))
            .checks.first { $0.name == "风扇控制" }
        check(item?.status == .warn && item?.detail.contains("疑似残留") == true,
              "医生双扇-2", "F1Md=1（配置关闭）→ WARN 残留嫌疑（不静默）")
    }
    // 医生双扇-3：F1Md=1 ∧ 配置开启 → INFO 合法介入态（P3-6 同款——boost 两步写
    // 解锁步行进中，避免硬件验收并发项误报）。
    do {
        let probe = FanDoctorProbe(
            keysPresent: f0Probe.keysPresent, mdValue: 0, tgRPM: 1350,
            config: FanStatus(enabled: true, strategy: .constantSpeed, state: .boost,
                              targetRPM: 3200, currentRPM: 3185, thresholdCentiC: 3700,
                              conflictFlag: false),
            keys1Present: ["F1Tg", "F1Md", "F1Ac", "F1Mn", "F1Mx"],
            md1Value: 1, tg1RPM: 3466)
        let item = DoctorReportGenerator.generate(secondFanDoctorInputs(fanProbe: probe))
            .checks.first { $0.name == "风扇控制" }
        check(item?.detail.contains("策略介入中——第二扇加速运行") == true
              && item?.status != .warn,
              "医生双扇-3", "F1Md=1（配置开启）→ INFO 介入态措辞（不误报残留）")
    }
    // 医生双扇-4：F1 键缺席（空数组=单风扇机型事实）→ INFO 属预期，不抬退出码；
    // keys1Present=nil（旧 CLI 形态）→ F1 段不渲染零回归。
    do {
        let absent = FanDoctorProbe(keysPresent: f0Probe.keysPresent, mdValue: 0, tgRPM: 1350,
                                    config: nil, keys1Present: [], md1Value: nil, tg1RPM: nil)
        let absentItem = DoctorReportGenerator.generate(secondFanDoctorInputs(fanProbe: absent))
            .checks.first { $0.name == "风扇控制" }
        check(absentItem?.detail.contains("F1 键缺席") == true && absentItem?.status == .pass,
              "医生双扇-4", "F1 键缺席 → 单风扇属预期 INFO 段（不抬退出码）")
        let legacy = DoctorReportGenerator.generate(
            secondFanDoctorInputs(fanProbe: FanDoctorProbe(
                keysPresent: f0Probe.keysPresent, mdValue: 0, tgRPM: 1350, config: nil)))
            .checks.first { $0.name == "风扇控制" }
        check(legacy?.detail.contains("F1") == false,
              "医生双扇-4", "keys1Present=nil（旧 CLI）→ F1 段不渲染（行形态零回归）")
    }
}

// MARK: - ① FanKey 键名钉（v1.12 M1；5 场景）
private func runFanKeyNamingScenarios() {
    // WHY 逐函数独立钉：帮助函数任何一个拼错（如 "F\(index)Tt"）都会静默生成
    // 非法键 → SMC keyNotFound → 能力误判不可用；此处逐字断言让拼写回归在
    // 单测层即红，不等到真机。值形态依据：SMC-NOTES §8.1 U5（F0）/ §10 U5'
    //（F1 五键全在位，F1Mn=1522/F1Mx=5777 flt、F1Md ui8）。
    check(FanKey.md(0) == "F0Md" && FanKey.md(1) == "F1Md",
          "风扇键-1", "FanKey.md 十键之 Md 逐字钉死（0=系统自动 1=手动直写）")
    check(FanKey.tg(0) == "F0Tg" && FanKey.tg(1) == "F1Tg",
          "风扇键-2", "FanKey.tg 逐字钉死（目标转速 flt LE，Md=1 手动态驻留可写）")
    check(FanKey.ac(0) == "F0Ac" && FanKey.ac(1) == "F1Ac",
          "风扇键-3", "FanKey.ac 逐字钉死（实际转速 flt LE——写跟随证据源）")
    check(FanKey.mn(0) == "F0Mn" && FanKey.mn(1) == "F1Mn",
          "风扇键-4", "FanKey.mn 逐字钉死（下界只读——U6 写必被拒 result=134）")
    check(FanKey.mx(0) == "F0Mx" && FanKey.mx(1) == "F1Mx",
          "风扇键-5", "FanKey.mx 逐字钉死（上界只读 clamp——绝不硬编码机型数值）")
}

// MARK: - ② FanStatus 第二扇四字段兼容（v1.12 D5；3 场景）
private func runSecondFanStatusCompatibilityScenarios() throws {
    // 第二扇-1：四新字段赋值 JSON roundtrip 保真（双槽 boost/hold 并存形态——
    // 两扇独立状态机下词可以不同，D3）。
    do {
        let fan = FanStatus(
            enabled: true, strategy: .constantSpeed, state: .boost,
            targetRPM: 3200, currentRPM: 3185, thresholdCentiC: 3700, conflictFlag: false,
            secondFanPresent: true, secondFanState: .hold,
            secondFanTargetRPM: 3466, secondFanCurrentRPM: 3450
        )
        let data = try JSONEncoder().encode(fan)
        let decoded = try JSONDecoder().decode(FanStatus.self, from: data)
        check(decoded == fan, "第二扇-1",
              "secondFan 四字段 roundtrip 保真（合成 Codable；双槽异词并存形态）")
    }
    // 第二扇-2：v1.11 形态旧 daemon JSON（无 second* 键）decode → 新四字段全
    // nil 且既有字段保真——新 App + 旧 daemon 的降级判定依据（nil → App 隐藏
    // 第二行，不弹升级提示：纯增强非必需字段，D5）。
    do {
        let oldJSON = #"{"enabled":true,"strategy":"constantSpeed","state":"boost","targetRPM":3200,"currentRPM":3185,"thresholdCentiC":3700,"conflictFlag":false,"speedPercent":50,"stage2Percent":80,"stage2RiseCentiC":300,"temperatureSource":1,"cpuSkinTempC":55.5,"cpuSkinSupported":true,"cpuSkinThresholdCentiC":5500,"cpuSkinHysteresisCentiC":400}"#
        let fan = try JSONDecoder().decode(FanStatus.self, from: Data(oldJSON.utf8))
        check(fan.secondFanPresent == nil && fan.secondFanState == nil
              && fan.secondFanTargetRPM == nil && fan.secondFanCurrentRPM == nil
              && fan.state == .boost && fan.targetRPM == 3200 && fan.temperatureSource == 1,
              "第二扇-2", "旧 daemon JSON（无 second* 键）→ 新四字段全 nil，既有字段保真")
    }
    // 第二扇-3：缺省形态（单风扇/未探测）encode 不写 second* 键——新 daemon 对
    // 旧客户端的线上字节形态与 v1.11 完全一致（未知键双向兼容的另一半：不写）。
    do {
        let fan = FanStatus(
            enabled: true, strategy: .constantSpeed, state: .automatic,
            targetRPM: nil, currentRPM: nil, thresholdCentiC: 3700, conflictFlag: false
        )
        let data = try JSONEncoder().encode(fan)
        let text = String(data: data, encoding: .utf8) ?? ""
        let decoded = try JSONDecoder().decode(FanStatus.self, from: data)
        check(decoded == fan && !text.contains("secondFan"),
              "第二扇-3", "缺省第二扇字段 encodeIfPresent 省写（线上零新增键形态）")
    }
}
