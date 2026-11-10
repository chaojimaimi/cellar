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
}
