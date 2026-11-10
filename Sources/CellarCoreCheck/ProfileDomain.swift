// CellarCoreCheck —— 0.23.18 多 Profile 批场景域（方案 §4；独立文件照
// MenuPresetDomain 先例，MainEntry.main 注册）。
//
// 判定面（直测，随 commit 1 先落；源钉面随 commit 2/3 递增）：
// - 方案-1..2 capture 全投影 / 完备性门（UD-7 恒填字段任一缺席 → nil，不造半份
//   快照；fan v1.11 三键缺席同门）；
// - 方案-3..5 applyPlan 矩阵向量表（§2.2 八行矩阵逐行 + 旋钮步序固定 + diff-skip
//   全同 → 空）；
// - 方案-6 FanSnapshot ↔ FanWire 映射往返（FanWire.wireValue 同源）+ 回读对比九
//   字段逐一翻转；
// - 方案-7 activeMatch 首匹配确定性 / 无匹配 nil / 空表 nil；
// - 方案-8 isValidName 边界（trim/长度/空）。
//
// 后续（本文件追加注册）：方案-9 MenuProfileModel（commit 3）、方案-10/11 收敛守卫
// 向量表与 applyPlan/activeMatch 互证（commit 2）、随批-1..2 btmAnchorDriftSuspected
// 真值表（commit 4）、源钉-1..7（commit 2/3/4 递增）。

import CellarCore
import Foundation

/// 0.23.18 多 Profile 批场景域入口（Main.main 调用）。
func runProfileDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            check(false, "Profile-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    // ---- fixture：全旋钮读回完备的 DaemonStatus（UD-7 恒填形态）----
    // FanStatus 字段全 let → 扰动经工厂参数重建（零共享可变面）。

    func fanStatus(
        enabled: Bool = true,
        strategy: FanStrategy = .twoStage,
        thresholdCentiC: Int = 3700,
        speedPercent: Int = 40,
        stage2Percent: Int = 70,
        stage2RiseCentiC: Int = 300,
        temperatureSource: Int? = 1,
        cpuSkinThresholdCentiC: Int? = 5500,
        cpuSkinHysteresisCentiC: Int? = 400
    ) -> FanStatus {
        FanStatus(
            enabled: enabled, strategy: strategy, state: .automatic,
            targetRPM: nil, currentRPM: 2400,
            thresholdCentiC: thresholdCentiC, conflictFlag: false,
            speedPercent: speedPercent, stage2Percent: stage2Percent,
            stage2RiseCentiC: stage2RiseCentiC,
            temperatureSource: temperatureSource, cpuSkinTempC: 55.2,
            cpuSkinSupported: true,
            cpuSkinThresholdCentiC: cpuSkinThresholdCentiC,
            cpuSkinHysteresisCentiC: cpuSkinHysteresisCentiC
        )
    }
    let fullFan = fanStatus()
    let scheduleFixture = #"{"enabled":false,"entries":[]}"#
    func fullStatus(mode: String = "active", upperLimit: Int = 80, hysteresis: Int = 2) -> DaemonStatus {
        var status = DaemonStatus(
            version: "0.23.16-alpha", mode: mode,
            upperLimit: upperLimit, hysteresis: hysteresis,
            fan: fullFan,
            calSchedEnabled: false, calSchedIntervalDays: 30, calSchedStartHour: 1,
            thermPauseCentiC: 4000, thermHysteresisCentiC: 300,
            scheduleJson: scheduleFixture,
            chHysteresisEnabled: true
        )
        // DaemonStatus 手写 init 未收 magSafeLed 参数（字段 var）——构造后赋值，
        // 与 wire decode 路径同形态（decodeIfPresent 缺席 → nil 同语义）。
        status.magSafeLed = MagSafeLEDStatus(mode: .off, supported: true, readbackRaw: 1, conflict: false)
        return status
    }

    // ---- 方案-1：capture 全投影（九类旋钮逐字段对账）----

    let captured = ProfileModel.capture(from: fullStatus())
    check(captured != nil, "方案-1", "完备读回 → capture 非 nil（UD-7 恒填形态全门通过）")
    if let profile = captured {
        check(profile.id.split(separator: "-").count == 5 && !profile.id.isEmpty,
              "方案-1", "id 为 UUID 形态（uuidString 五段）")
        check(profile.name.isEmpty, "方案-1", "name 留空（调用方命名后落库——capture 不造名）")
        check(profile.mode == "active" && profile.upperLimit == 80 && profile.hysteresis == 2,
              "方案-1", "mode/upperLimit/hysteresis 直投影（wire 字面量口径）")
        if let fan = profile.fan {
            check(fan.enabled == true && fan.strategy == .twoStage
                      && fan.thresholdCentiC == 3700 && fan.speedPercent == 40
                      && fan.stage2Percent == 70 && fan.stage2RiseCentiC == 300
                      && fan.temperatureSourceRaw == 1
                      && fan.cpuSkinThresholdCentiC == 5500 && fan.cpuSkinHysteresisCentiC == 400,
                  "方案-1", "fan 九字段全投影（enabled/strategy/threshold/speed/stage2/stage2Rise/source/cpu 阈值/滞回）")
        } else {
            check(false, "方案-1", "fan 快照缺席（应全投影）")
        }
        check(profile.thermal == ThermalSnapshot(pauseCentiC: 4000, hysteresisCentiC: 300),
              "方案-1", "therm 两键投影（4000/300）")
        check(profile.scheduleJson == scheduleFixture, "方案-1", "scheduleJson byte 透传（不解析不归一）")
        check(profile.calibration == CalibrationSnapshot(enabled: false, intervalDays: 30, startHour: 1),
              "方案-1", "calSched 三键投影")
        check(profile.chHysteresisEnabled == true, "方案-1", "chHysteresisEnabled 投影")
        check(profile.magSafeLedMode == MagSafeLEDMode.off.rawValue,
              "方案-1", "magSafeLedMode = MagSafeLEDMode.rawValue（off = 0x01）")
    }

    // ---- 方案-2：完备性门（恒填字段任一缺席 → 整体 nil，不造半份快照）----

    func captureNil(_ mutate: (inout DaemonStatus) -> Void, _ what: String) {
        var status = fullStatus()
        mutate(&status)
        check(ProfileModel.capture(from: status) == nil, "方案-2", "nil 门：\(what) 缺席 → capture nil")
    }
    var noFan = fullStatus()
    noFan.fan = nil
    check(ProfileModel.capture(from: noFan) == nil, "方案-2", "nil 门：fan 载荷缺席 → capture nil")
    // fan v1.11 三键（FanStatus 字段全 let → 经工厂重建缺席形态）。
    noFan.fan = fanStatus(temperatureSource: nil)
    check(ProfileModel.capture(from: noFan) == nil, "方案-2", "nil 门：fan v1.11 temperatureSource 缺席 → capture nil")
    noFan.fan = fanStatus(cpuSkinThresholdCentiC: nil)
    check(ProfileModel.capture(from: noFan) == nil, "方案-2", "nil 门：fan v1.11 cpuSkinThresholdCentiC 缺席 → capture nil")
    noFan.fan = fanStatus(cpuSkinHysteresisCentiC: nil)
    check(ProfileModel.capture(from: noFan) == nil, "方案-2", "nil 门：fan v1.11 cpuSkinHysteresisCentiC 缺席 → capture nil")
    captureNil({ $0.thermPauseCentiC = nil }, "thermPauseCentiC")
    captureNil({ $0.thermHysteresisCentiC = nil }, "thermHysteresisCentiC")
    captureNil({ $0.calSchedEnabled = nil }, "calSchedEnabled")
    captureNil({ $0.calSchedIntervalDays = nil }, "calSchedIntervalDays")
    captureNil({ $0.calSchedStartHour = nil }, "calSchedStartHour")
    captureNil({ $0.scheduleJson = nil }, "scheduleJson")
    captureNil({ $0.chHysteresisEnabled = nil }, "chHysteresisEnabled")
    captureNil({ $0.magSafeLed = nil }, "magSafeLed 载荷")
    // magSafeLed.mode nil = system 未设 opt-in 形态——**载荷在位即放行**，mode 原样
    // nil 透传（非完备性门项；与 nil 门逐项分立防「未设」被误判「旧 daemon」）。
    var systemLed = fullStatus()
    systemLed.magSafeLed?.mode = nil
    check(ProfileModel.capture(from: systemLed)?.magSafeLedMode == nil,
          "方案-2", "magSafeLed.mode nil（opt-in 形态）→ capture 放行且 magSafeLedMode nil")

    // ---- 方案-3：applyPlan 模式转移矩阵八行逐行（§2.2 钉死表）----
    // 旋钮全部同值（profile = capture(current) 改 mode/limits），计划只剩模式步。

    func capturedProfile(from status: DaemonStatus) -> ProfilePayload {
        ProfileModel.capture(from: status)!
    }
    func kind(_ step: ProfileApplyStep) -> String {
        switch step {
        case .setLimits: return "limits"
        case .setFan: return "fan"
        case .setThermal: return "thermal"
        case .setChargeSchedule: return "schedule"
        case .setCalibrationSchedule: return "calSched"
        case .setChHysteresisEnabled: return "ch"
        case .disable: return "disable"
        case .setMagSafeLed: return "led"
        }
    }
    func kinds(_ plan: [ProfileApplyStep]) -> [String] { plan.map(kind) }

    let base = fullStatus()
    // 行 1/2：active → active（同值无步 / 异值仅 setLimits）。
    check(ProfileModel.applyPlan(profile: capturedProfile(from: base), current: base).isEmpty,
          "方案-3", "行 1 active→active 同值：空计划（全旋钮 diff-skip 全同）")
    check(kinds(ProfileModel.applyPlan(
        profile: capturedProfile(from: fullStatus(upperLimit: 70)), current: base)) == ["limits"],
          "方案-3", "行 2 active→active 异值：恰 [setLimits]")
    // 行 3/4：active → disabled（同值也 setLimits——恒切 active = 隐式启用）。
    let disabledCurrent = fullStatus(mode: "disabled")
    check(kinds(ProfileModel.applyPlan(profile: capturedProfile(from: base), current: disabledCurrent)) == ["limits"],
          "方案-3", "行 3 active→disabled 同值：[setLimits]（隐式启用，无显式 enable case）")
    check(kinds(ProfileModel.applyPlan(profile: capturedProfile(from: fullStatus(upperLimit: 70)), current: disabledCurrent)) == ["limits"],
          "方案-3", "行 4 active→disabled 异值：[setLimits]（单步覆盖两义）")
    // 行 5/6：disabled → active。
    let disabledProfile = capturedProfile(from: disabledCurrent)
    check(kinds(ProfileModel.applyPlan(profile: disabledProfile, current: base)) == ["disable"],
          "方案-3", "行 5 disabled→active 同值：[disable]（disable 不动限值）")
    check(kinds(ProfileModel.applyPlan(profile: capturedProfile(from: fullStatus(mode: "disabled", upperLimit: 70)), current: base)) == ["limits", "disable"],
          "方案-3", "行 6 disabled→active 异值：[setLimits, disable]")
    // 行 7/8：disabled → disabled（同值无步 / 异值 setLimits→disable 拉回）。
    check(ProfileModel.applyPlan(profile: disabledProfile, current: disabledCurrent).isEmpty,
          "方案-3", "行 7 disabled→disabled 同值：空计划")
    check(kinds(ProfileModel.applyPlan(profile: capturedProfile(from: fullStatus(mode: "disabled", upperLimit: 70)), current: disabledCurrent)) == ["limits", "disable"],
          "方案-3", "行 8 disabled→disabled 异值：[setLimits, disable]（setLimits 会强制 active 须拉回——亚秒级瞬态执法窗 R14）")

    // ---- 方案-4：旋钮步序固定（全差异计划的完整形态与顺序）----

    var divergent = fullStatus(upperLimit: 60, hysteresis: 5)
    divergent.mode = "active"
    let otherFan = fanStatus(
        enabled: false, strategy: .constantSpeed, speedPercent: 30
    )
    var profile = ProfileModel.capture(from: divergent)!
    profile.upperLimit = 70   // 与 current（60/5）拉开——全差异含 limits 步
    profile.hysteresis = 3
    profile.fan = FanSnapshot.make(from: otherFan)
    profile.thermal = ThermalSnapshot(pauseCentiC: 3900, hysteresisCentiC: 250)
    profile.scheduleJson = #"{"enabled":true,"entries":[]}"#
    profile.calibration = CalibrationSnapshot(enabled: true, intervalDays: 14, startHour: 2)
    profile.chHysteresisEnabled = false
    profile.magSafeLedMode = MagSafeLEDMode.green.rawValue
    let fullPlan = ProfileModel.applyPlan(profile: profile, current: divergent)
    check(kinds(fullPlan) == ["limits", "fan", "thermal", "schedule", "calSched", "ch", "led"],
          "方案-4", "全差异（active→active）：七旋钮步序固定 limits→fan→thermal→schedule→calSched→ch→led（LED 最后）")
    if case .setLimits(let upper, let hys) = fullPlan[0] {
        check(upper == 70 && hys == 3, "方案-4", "setLimits 载荷 = profile 快照值（70/3）")
    } else {
        check(false, "方案-4", "首步非 setLimits")
    }
    if case .setFan(let wire) = fullPlan[1] {
        check(wire == profile.fan?.fanWire(), "方案-4", "setFan 载荷 = fanWire()（全键形态单一来源）")
    } else {
        check(false, "方案-4", "第二步非 setFan")
    }
    if case .setThermal(let wire) = fullPlan[2] {
        check(wire == ThermalWire(ThermalPolicy(pauseCentiC: 3900, hysteresisCentiC: 250)),
              "方案-4", "setThermal 全键 wire（ThermalWire(policy) 便捷构造）")
    } else {
        check(false, "方案-4", "第三步非 setThermal")
    }
    if case .setChargeSchedule(let json) = fullPlan[3] {
        check(json == #"{"enabled":true,"entries":[]}"#, "方案-4", "setChargeSchedule byte 透传")
    } else {
        check(false, "方案-4", "第四步非 setChargeSchedule")
    }
    if case .setCalibrationSchedule(let wire) = fullPlan[4] {
        check(wire == CalibrationScheduleWire(CalibrationSchedulePolicy(enabled: true, intervalDays: 14, startHour: 2)),
              "方案-4", "setCalibrationSchedule 全键 wire")
    } else {
        check(false, "方案-4", "第五步非 setCalibrationSchedule")
    }
    if case .setChHysteresisEnabled(let enabled) = fullPlan[5] {
        check(enabled == false, "方案-4", "setChHysteresisEnabled 载荷 = 快照值")
    } else {
        check(false, "方案-4", "第六步非 setChHysteresisEnabled")
    }
    if case .setMagSafeLed(let raw) = fullPlan[6] {
        check(raw == MagSafeLEDMode.green.rawValue, "方案-4", "setMagSafeLed 载荷 = rawValue（收尾 LED）")
    } else {
        check(false, "方案-4", "第七步非 setMagSafeLed")
    }
    // disabled 方案全差异：disable 步插在 ch 与 led 之间（收尾位）。
    profile.mode = "disabled"
    check(kinds(ProfileModel.applyPlan(profile: profile, current: divergent))
              == ["limits", "fan", "thermal", "schedule", "calSched", "ch", "disable", "led"],
          "方案-4", "disabled 方案全差异：八步满序（disable 居 led 前——矩阵收尾位）")

    // ---- 方案-5：diff-skip 单旋钮（逐旋钮差异只发该步）----

    func singleKnobPlan(_ mutate: (inout ProfilePayload) -> Void) -> [String] {
        var payload = capturedProfile(from: base)
        mutate(&payload)
        return kinds(ProfileModel.applyPlan(profile: payload, current: base))
    }
    check(singleKnobPlan({ $0.fan?.enabled = false }) == ["fan"], "方案-5", "仅 fan 差异 → 恰 [fan]")
    check(singleKnobPlan({ $0.thermal?.pauseCentiC = 4200 }) == ["thermal"], "方案-5", "仅 therm 差异 → 恰 [thermal]")
    check(singleKnobPlan({ $0.scheduleJson = #"{"enabled":true,"entries":[]}"# }) == ["schedule"],
          "方案-5", "仅日程差异 → 恰 [schedule]（JSON 字符串全等 diff）")
    check(singleKnobPlan({ $0.calibration?.intervalDays = 60 }) == ["calSched"], "方案-5", "仅校准调度差异 → 恰 [calSched]")
    check(singleKnobPlan({ $0.chHysteresisEnabled = false }) == ["ch"], "方案-5", "仅 CHIE 开关差异 → 恰 [ch]")
    check(singleKnobPlan({ $0.magSafeLedMode = MagSafeLEDMode.system.rawValue }) == ["led"], "方案-5", "仅 LED 差异 → 恰 [led]")
    check(singleKnobPlan({ $0.upperLimit = 75; $0.hysteresis = 2 }) == ["limits"], "方案-5", "仅上限差异 → 恰 [limits]（滞回同值不连坐）")

    // ---- 方案-6：FanSnapshot ↔ FanWire 映射往返（wireValue 同源）+ matches 翻转 ----

    if let snapshot = FanSnapshot.make(from: fullFan) {
        let wire = snapshot.fanWire()
        check(wire.enabled == 1 && wire.strategy == FanWire.wireValue(.twoStage)
                  && wire.threshold == UInt64(3700) && wire.speed == UInt64(40)
                  && wire.stage2 == UInt64(70) && wire.stage2Rise == UInt64(300)
                  && wire.source == FanWire.wireValue(.cpuSkin)
                  && wire.cpuThreshold == UInt64(5500) && wire.cpuHysteresis == UInt64(400),
              "方案-6", "九键线值映射（enabled 1 / strategy·source 经 FanWire.wireValue 同源函数）")
        check(wire.hysteresis == nil, "方案-6", "battery 源释放滞回键恒 nil 不发（FanStatus 无读回面——缺席保持，旋钮不归 profile 管）")
        check(snapshot.matches(fullFan), "方案-6", "matches(原读回) == true")
        check(!snapshot.matches(fanStatus(enabled: false)), "方案-6", "matches 翻转：enabled")
        check(!snapshot.matches(fanStatus(strategy: .emergency)), "方案-6", "matches 翻转：strategy")
        check(!snapshot.matches(fanStatus(thresholdCentiC: 3600)), "方案-6", "matches 翻转：thresholdCentiC")
        check(!snapshot.matches(fanStatus(speedPercent: 50)), "方案-6", "matches 翻转：speedPercent")
        check(!snapshot.matches(fanStatus(stage2Percent: 60)), "方案-6", "matches 翻转：stage2Percent")
        check(!snapshot.matches(fanStatus(stage2RiseCentiC: 400)), "方案-6", "matches 翻转：stage2RiseCentiC")
        check(!snapshot.matches(fanStatus(temperatureSource: 0)), "方案-6", "matches 翻转：temperatureSourceRaw")
        check(!snapshot.matches(fanStatus(cpuSkinThresholdCentiC: 5600)), "方案-6", "matches 翻转：cpuSkinThresholdCentiC")
        check(!snapshot.matches(fanStatus(cpuSkinHysteresisCentiC: 500)), "方案-6", "matches 翻转：cpuSkinHysteresisCentiC")
    } else {
        check(false, "方案-6", "FanSnapshot.make(完备读回) 应非 nil")
    }

    // ---- 方案-7：activeMatch（首匹配确定性 / 无匹配 nil / 空表 nil）----

    let matchA = capturedProfile(from: base)
    var matchB = capturedProfile(from: fullStatus(upperLimit: 70))
    check(ProfileModel.activeMatch(profiles: [], current: base) == nil,
          "方案-7", "空表 → nil")
    check(ProfileModel.activeMatch(profiles: [matchA, matchB], current: base) == matchA.id,
          "方案-7", "首个匹配 id（列表序确定性——matchA 在前返回 matchA）")
    check(ProfileModel.activeMatch(profiles: [matchB, matchA], current: base) == matchA.id,
          "方案-7", "首匹配确定性（matchB 不匹配时跳过，命中 matchA）")
    matchB.upperLimit = base.upperLimit
    check(ProfileModel.activeMatch(profiles: [matchB, matchA], current: base) == matchB.id,
          "方案-7", "matchB 改同值后命中 matchB（列表序首个）")
    var drifted = capturedProfile(from: base)
    drifted.upperLimit = 65
    check(ProfileModel.activeMatch(profiles: [drifted], current: base) == nil,
          "方案-7", "全不匹配 → nil（✓ 不显示——本地意图 ≠ daemon 现值如实呈现，防意图漂移）")
    // 意图镜像不参与判定（结构性杜绝——方案 §2.4）：本函数签名只收
    // profiles/current 两参，无 activeProfileID 入口；✓ 派生单源在读回。

    // ---- 方案-8：isValidName 边界（trim/长度/空）----

    check(ProfileModel.isValidName("工作") == true, "方案-8", "普通名合法")
    check(ProfileModel.isValidName("") == false, "方案-8", "空串非法")
    check(ProfileModel.isValidName("   ") == false, "方案-8", "纯空白非法（trim 后非空门）")
    check(ProfileModel.isValidName(" \t 夜间 \n ") == true, "方案-8", "首尾空白 trim 后合法")
    check(ProfileModel.isValidName(String(repeating: "甲", count: 40)) == true, "方案-8", "恰 40 字符合法（上限含）")
    check(ProfileModel.isValidName(String(repeating: "甲", count: 41)) == false, "方案-8", "41 字符非法（上限 40）")
    check(ProfileModel.isValidName("  " + String(repeating: "甲", count: 40)) == true,
          "方案-8", "trim 后恰 40 字符合法（计数对 trim 后生效）")

    // ---- 方案-10：chainGuardShouldAbort 向量表（commit 2 源码面配套直测）----

    let steps: [ProfileApplyStep] = [
        .setLimits(upperLimit: 80, hysteresis: 2), .setFan(FanWire()), .setThermal(ThermalWire()),
        .setChargeSchedule(json: "{}"), .setCalibrationSchedule(CalibrationScheduleWire()),
        .setChHysteresisEnabled(true), .disable, .setMagSafeLed(1),
    ]
    check(steps.map { ProfileModel.applyStepCaseCount(of: $0) } == [Int](repeating: 8, count: 8),
          "方案-10", "applyStepCaseCount 穷举计数恒 8（八 case 全实例驱动——新增 case 编译期强制同步点）")
    check(ProfileModel.chainGuardShouldAbort(lastStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                             nextStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                             executed: 1),
          "方案-10", "守卫一：紧邻同型步（lastStep == nextStep）→ 中止（重推导未收敛）")
    check(!ProfileModel.chainGuardShouldAbort(lastStep: .setFan(FanWire()),
                                              nextStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                              executed: 2),
          "方案-10", "守卫一：非紧邻同型（lastStep .setFan / nextStep .setLimits——计划内 setLimits 二次出现）→ 放行")
    check(!ProfileModel.chainGuardShouldAbort(lastStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                              nextStep: .setFan(FanWire()),
                                              executed: 7),
          "方案-10", "守卫二边界：executed 7 < 8 → 放行（七发后仍有第八步合法）")
    check(ProfileModel.chainGuardShouldAbort(lastStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                             nextStep: .setFan(FanWire()),
                                             executed: 8),
          "方案-10", "守卫二边界：executed 8 ≥ 8 → 中止（步型全发仍未收敛 = 振荡）")
    check(!ProfileModel.chainGuardShouldAbort(lastStep: nil, nextStep: nil, executed: 0)
              && !ProfileModel.chainGuardShouldAbort(lastStep: .disable, nextStep: nil, executed: 1),
          "方案-10", "nextStep nil（发起前判定语境）仅查守卫二：executed 0/1 → 放行")
    check(ProfileModel.chainGuardShouldAbort(lastStep: nil, nextStep: nil, executed: 8),
          "方案-10", "nextStep nil ∧ executed ≥ 8 → 中止（守卫二单查语义）")
    check(!ProfileModel.chainGuardShouldAbort(lastStep: nil,
                                              nextStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                              executed: 0),
          "方案-10", "链首发起（lastStep nil / nextStep 首步）→ 放行")

    // ---- 方案-11：applyPlan 空 ⇔ activeMatch 命中互证（同一比较域结构性证明——
    // 评审 P3；wire 契约域 mode ∈ "active"|"disabled" 上成立，比较 helper 单源）----

    let pairs: [(profile: ProfilePayload, current: DaemonStatus)] = {
        var result: [(ProfilePayload, DaemonStatus)] = []
        for mode in ["active", "disabled"] {
            for upper in [80, 70] {
                let current = fullStatus(mode: mode, upperLimit: upper)
                let identical = ProfileModel.capture(from: current)!
                result.append((identical, current))   // 全同 → 空 ⇔ 命中
                var limits = ProfileModel.capture(from: current)!
                limits.upperLimit = 60
                result.append((limits, current))      // 限值异 → 非空 ⇔ 不命中
                var schedule = ProfileModel.capture(from: current)!
                schedule.scheduleJson = #"{"enabled":true,"entries":[]}"#
                result.append((schedule, current))    // 日程异 → 非空 ⇔ 不命中
                var modeFlip = ProfileModel.capture(from: current)!
                modeFlip.mode = mode == "active" ? "disabled" : "active"
                result.append((modeFlip, current))    // 模式异 → 非空 ⇔ 不命中（四组合全覆盖）
                var fan = ProfileModel.capture(from: current)!
                fan.fan?.enabled = false
                result.append((fan, current))         // fan 异 → 非空 ⇔ 不命中
                var led = ProfileModel.capture(from: current)!
                led.magSafeLedMode = MagSafeLEDMode.system.rawValue
                result.append((led, current))         // LED 异 → 非空 ⇔ 不命中
            }
        }
        return result.map { (profile: $0.0, current: $0.1) }
    }()
    var mutual = true
    for (payload, current) in pairs {
        let planEmpty = ProfileModel.applyPlan(profile: payload, current: current).isEmpty
        let matched = ProfileModel.activeMatch(profiles: [payload], current: current) == payload.id
        if planEmpty != matched { mutual = false }
    }
    check(mutual && pairs.count == 24,
          "方案-11", "24 对（mode²×limits²×六类扰动——全同/限值/日程/模式翻转/fan/LED）：applyPlan 空 ⇔ activeMatch 命中（同比较域互证）")
    // 双方案列表形态：匹配者居后仍命中（与方案-7 首匹配语义一致）。
    let listCurrent = fullStatus()
    let miss = ProfileModel.capture(from: listCurrent)!
    var driftedMiss = miss
    driftedMiss.upperLimit = 60
    let hit = ProfileModel.capture(from: listCurrent)!
    check(ProfileModel.activeMatch(profiles: [driftedMiss, hit], current: listCurrent) == hit.id
              && ProfileModel.applyPlan(profile: hit, current: listCurrent).isEmpty
              && !ProfileModel.applyPlan(profile: driftedMiss, current: listCurrent).isEmpty,
          "方案-11", "列表形态互证：miss 非空不命中 / hit 空且命中（两函数同判）")

    // ---- 源钉（源文件读取——照 MenuPresetDomain source() 先例）----

    // 源钉-1：AppConfig 双字段 decode/encodeIfPresent 在位。
    let appSideSrc = source("Sources/CellarCore/Daemon/AppSide.swift")
    check(appSideSrc.contains("case profiles")
              && appSideSrc.contains("case activeProfileID")
              && appSideSrc.contains("profiles = try container.decodeIfPresent([ProfilePayload].self, forKey: .profiles)")
              && appSideSrc.contains("activeProfileID = try container.decodeIfPresent(String.self, forKey: .activeProfileID)")
              && appSideSrc.contains("try container.encodeIfPresent(profiles, forKey: .profiles)")
              && appSideSrc.contains("try container.encodeIfPresent(activeProfileID, forKey: .activeProfileID)"),
          "源钉-1", "AppConfig 双字段四位同步（CodingKeys + decodeIfPresent ×2 + encodeIfPresent ×2——nil 缺席零键增量）")

    // 源钉-2：runControl 三改造（internal widening + String? 反馈 + onFailure 钩子）。
    let statusControllerSrc = source("App/CellarApp/StatusController.swift")
    check(statusControllerSrc.contains("    func runControl(")
              && !statusControllerSrc.contains("private func runControl("),
          "源钉-2", "runControl private → internal（链扩展文件驱动单槽通道——R2 P1-A widening 先例）")
    check(statusControllerSrc.contains("let successFeedback: String?")
              && statusControllerSrc.contains("successFeedback: String?,")
              && statusControllerSrc.contains("if let feedback = successFeedback {"),
          "源钉-2", "successFeedback String?（QueuedControlCall + runControl 形参 + finishControl nil 分支单点 if let——链步静默仅链尾聚合）")
    check(statusControllerSrc.contains("onFailure: (@MainActor (DaemonClientError) -> Void)? = nil")
              && statusControllerSrc.contains("onFailure: (@MainActor (DaemonClientError) -> Void)?,")
              && statusControllerSrc.contains("onFailure?(error)")
              && statusControllerSrc.contains("onFailure: queued.onFailure,"),
          "源钉-2", "onFailure 钩子（默认 nil 参数 + finishControl 形参 + 失败分支 classifyControlFailure 之后调用 + 队列补发透传）")
    check(statusControllerSrc.contains("profile 链扩展文件")
              && statusControllerSrc.contains("横幅串击")
              && statusControllerSrc.contains("失败链残留非 nil 状态"),
          "源钉-2", "WHY 三条齐（internal widening / String? 串击 / onFailure 清链落点——评审 P1-2）")
    check(statusControllerSrc.contains("ProfileController.shared.maybeCaptureDefault(status)"),
          "源钉-2", "ingest 尾部迁移挂点（首启静默捕获——幂等单发守卫在 ProfileController）")
    check(statusControllerSrc.contains("var profileChain: ProfileChainState?"),
          "源钉-2", "链状态存储槽在主类（extension 无存储属性——LED internal setter 同款先例）")

    // 源钉-3：编排器面（链存续守卫/守卫二发起前/每步重推导/穷举映射/补偿/nil 反馈/清链/fan 注记）。
    let profileApplySrc = source("App/CellarApp/StatusController+ProfileApply.swift")
    let advanceSegment = profileApplySrc.components(
        separatedBy: "private func advanceProfileChain").dropFirst().first ?? ""
    check(advanceSegment.contains("guard let chain = profileChain else { return }")
              && advanceSegment.range(of: "guard let chain = profileChain")?.lowerBound
                  ?? advanceSegment.startIndex
                  < advanceSegment.range(of: "chainGuardShouldAbort")?.lowerBound ?? advanceSegment.endIndex,
          "源钉-3", "链存续守卫入口判定（guard let chain 先于一切链状态访问——评审 P1 时序防御）")
    check(advanceSegment.contains("nextStep: nil, executed: chain.executed")
              && advanceSegment.range(of: "nextStep: nil")?.lowerBound
                  ?? advanceSegment.startIndex
                  < advanceSegment.range(of: "ProfileModel.applyPlan")?.lowerBound ?? advanceSegment.endIndex,
          "源钉-3", "收敛守卫二发起前判定（nextStep nil 形态先于 applyPlan 重推导——严禁 defer 出口，评审 P1）")
    check(advanceSegment.contains("ProfileModel.applyPlan(profile: chain.payload, current: status)")
              && advanceSegment.contains("ProfileModel.chainGuardShouldAbort("),
          "源钉-3", "每步重推导（applyPlan 在 advance 内——评审 P2-2）+ 守卫经 ProfileModel.chainGuardShouldAbort 纯函数")
    check(profileApplySrc.contains("case .setLimits(let upperLimit, let hysteresis):")
              && profileApplySrc.contains("case .setFan(let wire):")
              && profileApplySrc.contains("case .setThermal(let wire):")
              && profileApplySrc.contains("case .setChargeSchedule(let json):")
              && profileApplySrc.contains("case .setCalibrationSchedule(let wire):")
              && profileApplySrc.contains("case .setChHysteresisEnabled(let enabled):")
              && profileApplySrc.contains("case .disable:")
              && profileApplySrc.contains("case .setMagSafeLed(let raw):"),
          "源钉-3", "编排器 exhaustive switch 八 case（新增 case 编译期强制同步）")
    check(profileApplySrc.components(separatedBy: "successFeedback: nil,").count - 1 == 8,
          "源钉-3", "链步成功反馈 nil 恰八处（横幅串击根除——B3-4，仅链尾 control.profile.applied 聚合）")
    check(profileApplySrc.components(separatedBy: "onFailure: { _ in self.profileChain = nil }").count - 1 == 8,
          "源钉-3", "onFailure 清链恰八处（失败即停——评审 P1-2）")
    check(profileApplySrc.contains("self.reconcileShutdownResidualNow()")
              && profileApplySrc.contains("advanceProfileChain(from: status)"),
          "源钉-3", ".disable 步补偿（toggleCharging(false) 同款 reconcileShutdownResidualNow——LimitExecution:56 internal 零改动）+ onSuccess 续链")
    check(profileApplySrc.contains("field: .strategy 取形注记")
              && profileApplySrc.contains(".setFan(wire, .strategy)")
              && profileApplySrc.contains("guard let mode = MagSafeLEDMode(rawValue: raw)"),
          "源钉-3", "fan 步 field 取形注记 + .strategy 取值 + LED raw 白名单防御（非法 raw 永不收敛 → abortChain）")

    // 源钉-3b：ControlModels `.setMagSafeLed` case 恢复（双臂 + 隔离偏离登记）。
    let controlModelsSrc = source("App/CellarApp/ControlModels.swift")
    check(controlModelsSrc.contains("case setMagSafeLed(MagSafeLEDMode)")
              && controlModelsSrc.contains("status.summary.setMagSafeLed")
              && controlModelsSrc.contains("两通道并存、互不渗透"),
          "源钉-3b", "ControlAttempt .setMagSafeLed case 恢复 + summary 臂（status.summary.setMagSafeLed 键已在 catalog 零增量）+ 轻路径隔离偏离登记注记")
    check(statusControllerSrc.contains("applyLedStepDirect(mode)")
              && profileApplySrc.contains("func applyLedStepDirect(_ mode: MagSafeLEDMode)")
              && profileApplySrc.contains("attempt: .setMagSafeLed(mode)"),
          "源钉-3b", "retryLastAttempt 臂经 applyLedStepDirect 单步重发（回 runControl 同一通道——不照抄旧轻路径臂；成功反馈复用 status.summary.setMagSafeLed 键）")

    // 源钉-7：catalog 新键逐字直读 + 键数精确断言（commit 2 后 491+16=507）。
    let catalogURL = repoRoot.appendingPathComponent("Sources/CellarUI/Resources/Localizable.xcstrings")
    if let data = try? Data(contentsOf: catalogURL),
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let strings = root["strings"] as? [String: Any] {
        check(strings.count == 507,
              "源钉-7", "catalog 键数精确断言 507（491 + 16：control.profile.* 15 + panel.menu.profiles）")
        let expectations: [String: String] = [
            "control.profile.title": "充电方案",
            "control.profile.empty": "暂无方案。从当前设置创建第一个方案。",
            "control.profile.duplicateSuffix": "%@ 副本",
            "control.profile.defaultName": "默认",
            "control.profile.deleteConfirm": "确认删除「%@」？",
            "control.profile.nameInvalid": "名称不能为空且不超过 40 个字符",
            "control.profile.captureUnavailable": "无法捕获当前设置（守护进程版本过旧）",
            "control.profile.limitReached": "方案数已达上限（%lld）",
            "control.profile.applied": "已应用方案「%@」",
            "control.profile.notConverged": "方案「%@」中止：守护进程读回未收敛，已停止切换",
            "panel.menu.profiles": "充电方案",
        ]
        var allPresent = true
        for (key, zh) in expectations {
            func localized(_ locale: String) -> String? {
                if let entry = strings[key] as? [String: Any],
                   let localizations = entry["localizations"] as? [String: Any],
                   let unit = (localizations[locale] as? [String: Any])?["stringUnit"] as? [String: Any] {
                    return unit["value"] as? String
                }
                return nil
            }
            if localized("zh-Hans") != zh || localized("en") == nil || localized("en")?.isEmpty == true {
                allPresent = false
            }
        }
        check(allPresent, "源钉-7", "catalog 新键逐字直读（zh-Hans 抽样 11 键逐字 + en 双语齐——extractionState manual 单一门面）")
    } else {
        check(false, "源钉-7", "catalog 键结构缺席（双语源钉红）")
    }
}
