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
//
// 0.23.20 热修追加：方案-12..14 schedule 语义比较向量表 / applyPlan 语义免疫
// （§1 根因「byte 比较跨二进制永不收敛」回归门）/ capture 写时归一 + 源钉-10
// （public 纯函数 + 双消费点 + 归一在位 + ABORT 双原串打点 + 截断形态）；
// 既有断言联动：方案-1 归一断言改写、源钉-9 privacy 计数 31 → 33、方案-5 括注
// 语义 diff 文案。
//
// 0.23.21-alpha 整理批拆分（915 行 → 双文件 ≤800）：九个纯源码读取钉块
// （源钉-1/2/3/3b/4/5/7/8/10）迁 ProfileDomain+Pins.swift（独立 runner
// runProfileDomainPinsScenarios——Main.main 双注册，场景总数相加不减，注册行
// 反钉在其源钉-10）；本文件留守判定面（方案-1..14 + 随批-1..2）+ 源钉-9
// （行为面三断言 + capturedProfile/base fixture 不随迁）。
//
// 0.23.22-alpha 追加：随批-3 stalePinSuspected 真值表（8 行——升级后 BTM
// 签名失配精确判定五条件 + 全部降级臂与方向性臂；2026-11-11 事故回归门）；
// 留守判定面计数自此为「方案-1..14 + 随批-1..3」。

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
        // 0.23.20 联动改写（原「byte 透传不解析不归一」随 capture 归一批过期）。
        // 0.23.21-alpha 整理批再改写（登记偏差，主代理裁决批准）：平台事实实证
        // （独立探针）JSONEncoder 在 -O 优化下同进程逐次两键序漂移——双 encode
        // 字节比较在任何 -O 二进制下都无法稳定（0.23.20「基准二进制无关」设计的
        // 单二进制形态恒定假设被现实推翻）。行为面升语义域：scheduleSemantically
        // Equal(stored, fixture) + 存储串 decode 可解析检；「归一在位」强度由源钉-10
        // 的 ProfileModel 源码 contains 钉（decoded.encoded ?? scheduleJson）承载
        // ——行为语义 + 源码存在双层，强度不低于原字节比较。
        check(ProfileModel.scheduleSemanticallyEqual(profile.scheduleJson, scheduleFixture)
                  && (try? ChargeScheduleConfig.decoded(from: profile.scheduleJson ?? "")) != nil,
              "方案-1", "scheduleJson capture 归一存语义域（daemon 形态输入 → 存储串解码值 == 输入解码值 + 存储串可解析——decoded!.encoded 字节基准随 -O 逐次键序漂移退役；归一存在面由源钉-10 源码钉承载；解码失败原样存负臂见方案-14）")
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
          "方案-5", "仅日程差异 → 恰 [schedule]（语义 diff——enabled 翻转语义异仍发步；byte 异语义同的不发步面见方案-13）")
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

    // ---- 方案-10：chainGuardShouldAbort 向量表（评审收口 P1 后单语义形态——
    // nextStep 非可选：lastStep == nextStep ∨ executed ≥ 步型总数；「nextStep
    // nil 仅查守卫二」双语义入口随编排器链尾判定前置消除）----

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
          "方案-10", "守卫二边界：executed 8 ≥ 8 → 中止（步型全发仍未收敛 = 振荡；非紧邻同型形态表达——守卫二独立语义）")
    check(ProfileModel.chainGuardShouldAbort(lastStep: nil,
                                             nextStep: .setFan(FanWire()),
                                             executed: 8),
          "方案-10", "守卫二独立语义（lastStep nil 形态）：executed ≥ 8 → 中止")
    check(!ProfileModel.chainGuardShouldAbort(lastStep: nil,
                                              nextStep: .setLimits(upperLimit: 80, hysteresis: 2),
                                              executed: 0),
          "方案-10", "链首发起（lastStep nil / nextStep 首步 / executed 0）→ 放行")

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

    // ---- 方案-9：MenuProfileModel.items 判定矩阵（commit 3 模型配套直测）----

    let menuCurrent = fullStatus()
    let menuHit = ProfileModel.capture(from: menuCurrent)!
    var menuMiss = ProfileModel.capture(from: menuCurrent)!
    menuMiss.upperLimit = 60
    let menuProfiles = [menuMiss, menuHit]

    // status 直入：✓ 派生在模型内部经 activeMatch——签名无意图参数（结构性杜绝
    // 调用方误接 activeProfileID，评审 P2-3）。
    let menuNormal = MenuProfileModel.items(profiles: menuProfiles, status: menuCurrent, busy: false, actionActive: false)
    check(menuNormal.map(\.id) == [menuMiss.id, menuHit.id]
              && menuNormal.map(\.name) == [menuMiss.name, menuHit.name],
          "方案-9", "两方案全量投影（顺序 = 列表序；name 原样）")
    check(menuNormal.filter(\.isSelected).map(\.id) == [menuHit.id]
              && menuNormal.allSatisfy(\.enabled),
          "方案-9", "✓ 读回派生恰一（miss 限值漂移不点亮）+ 正常态全 enabled")
    check(MenuProfileModel.items(profiles: [], status: menuCurrent, busy: false, actionActive: false).isEmpty,
          "方案-9", "空表 → 空数组（组装层整区省略——菜单形态对无 profile 用户零变化）")
    check(MenuProfileModel.items(profiles: menuProfiles, status: nil, busy: false, actionActive: false)
              .allSatisfy { !$0.enabled && !$0.isSelected },
          "方案-9", "status nil：全禁用 + 全无 ✓（linkLost 内部派生——activeMatch 无 current 无命中）")
    check(MenuProfileModel.items(profiles: menuProfiles, status: menuCurrent, busy: true, actionActive: false)
              .allSatisfy { !$0.enabled },
          "方案-9", "busy：全禁用（整包切换不接受排队，R6）")
    check(MenuProfileModel.items(profiles: menuProfiles, status: menuCurrent, busy: false, actionActive: true)
              .allSatisfy { !$0.enabled },
          "方案-9", "actionActive：全禁用（setLimits 隐式取消在轨动作入口禁用面，R4）")
    let menuDisabledCurrent = fullStatus(mode: "disabled")
    let disabledHit = ProfileModel.capture(from: menuDisabledCurrent)!
    let menuDisabled = MenuProfileModel.items(profiles: [disabledHit], status: menuDisabledCurrent, busy: false, actionActive: false)
    check(menuDisabled.first?.enabled == true && menuDisabled.first?.isSelected == true,
          "方案-9", "mode disabled：放行 + ✓ 保留（切换到 active 方案正是从 disabled 走出的合法路径——§2.3 同理由）")

    // ---- 随批-1..2：btmAnchorDriftSuspected 真值表（3³ 组合抽样钉边界行）----

    // 全 3³ 组合逐点扫描（registration×route×connection 各三态）——命中行恰一：
    // (enabled, unknown, unreachable)。
    var driftHits: [String] = []
    for registration in [RegistrationStatus.notRegistered, .pending, .enabled] {
        for route in [DaemonRoute.appManaged, .manual, .unknown] {
            for connection in [ConnectionState.connected, .unreachable, .unknown] {
                if btmAnchorDriftSuspected(registration: registration, route: route, connection: connection) {
                    driftHits.append("\(registration)/\(route)/\(connection)")
                }
            }
        }
    }
    check(driftHits == ["enabled/unknown/unreachable"],
          "随批-1", "3³ 全组合扫描：命中行恰一（enabled ∧ route unknown ∧ connection unreachable——BTM 事故特征态）")
    // 边界行逐条（任一条件不成立即不报——防「已注册失联」常态误报为漂移）。
    check(!btmAnchorDriftSuspected(registration: .enabled, route: .unknown, connection: .connected)
              && !btmAnchorDriftSuspected(registration: .enabled, route: .unknown, connection: .unknown)
              && !btmAnchorDriftSuspected(registration: .enabled, route: .appManaged, connection: .unreachable)
              && !btmAnchorDriftSuspected(registration: .enabled, route: .manual, connection: .unreachable)
              && !btmAnchorDriftSuspected(registration: .pending, route: .unknown, connection: .unreachable)
              && !btmAnchorDriftSuspected(registration: .notRegistered, route: .unknown, connection: .unreachable),
          "随批-1", "边界负臂：连接恢复/连接未刷新/路线已判明/未注册全不报（「未注册失联 = 常态」语义不误报）")

    // ---- 随批-3：stalePinSuspected 真值表（0.23.22 §1.3，8 行——a..h 共用一标签）----

    check(stalePinSuspected(registration: .enabled, route: .appManaged, btmState: .spawnFailed,
                            parentBundleVersion: 2318, ownBundleVersion: 2321),
          "随批-3", "a：enabled ∧ appManaged ∧ spawnFailed ∧ 2318≠2321 → true（本案原形——升级后 BTM 钉扎旧 cdhash）")
    check(!stalePinSuspected(registration: .enabled, route: .appManaged, btmState: .spawnFailed,
                             parentBundleVersion: 2321, ownBundleVersion: 2321),
          "随批-3", "b：版本一致 → false（R3 dev-bundle 覆盖形态降级通用 btmCorrupted 行）")
    check(!stalePinSuspected(registration: .enabled, route: .appManaged, btmState: .running,
                             parentBundleVersion: 2318, ownBundleVersion: 2321),
          "随批-3", "c：运行中不报（speculative spawn 假愈面——daemon 在跑无故障，诚实呈现）")
    check(!stalePinSuspected(registration: .notRegistered, route: .appManaged, btmState: .spawnFailed,
                             parentBundleVersion: 2318, ownBundleVersion: 2321),
          "随批-3", "d：未注册不报（授权流过渡态非 BTM 记录有效形态）")
    check(!stalePinSuspected(registration: .enabled, route: .appManaged, btmState: .spawnFailed,
                             parentBundleVersion: nil, ownBundleVersion: 2321),
          "随批-3", "e：parent 解析降级（老格式行缺失）→ false（不误报）")
    check(!stalePinSuspected(registration: .enabled, route: .appManaged, btmState: .spawnFailed,
                             parentBundleVersion: 2318, ownBundleVersion: nil),
          "随批-3", "f：own 解析降级（异常 CFBundleVersion）→ false（不误报）")
    check(!stalePinSuspected(registration: .enabled, route: .manual, btmState: .spawnFailed,
                             parentBundleVersion: 2318, ownBundleVersion: 2321),
          "随批-3", "g：手工路线不归本形态（BTM 钉扎仅 SMAppService 托管路线）")
    check(!stalePinSuspected(registration: .enabled, route: .appManaged, btmState: nil,
                             parentBundleVersion: 2318, ownBundleVersion: 2321),
          "随批-3", "h：print 解析失败（btmState nil）不误报")

    // ---- 源钉-9：0.23.19 热修取证装具（.error 级反钉 + privacy .public 反钉 +
    // matchReport/MatchReport public 纯新增反钉〔既有 helper 零改动〕+
    // abortChain(status:) 签名 + 2s 延迟观测 + import os）----

    // 装具通道在位（import os + com.cellar/profile-chain——AppConfigStore.log
    // 先例形态；Logger Sendable 跨隔离安全）。
    let profileApplySrc3 = source("App/CellarApp/StatusController+ProfileApply.swift")
    check(profileApplySrc3.contains("import os")
              && profileApplySrc3.contains("Logger(subsystem: \"com.cellar\", category: \"profile-chain\")"),
          "源钉-9", "取证通道在位（import os + subsystem/category 双段——0.23.18 编排器文件纯观测加装具）")
    // 级别反钉（0.23.21-alpha 整理批改写——装具分级定版）：.error 恰四（ABORT
    // 双臂 + ABORT+2s 双臂——异常取证主通道，os_log error 级落盘持久化可查，
    // 0.23.13 钉扎行教训）+ .debug 恰四（chain start/advance/dispatch/finish
    // 正常链路——缺陷根治 + 方案-13 回归门兜底，事后取证放弃取舍已在装具
    // 文件头登记）+ info/notice 负钉保留（防未来引入无钉）。
    check(profileApplySrc3.components(separatedBy: "Self.log.error(").count - 1 == 4
              && profileApplySrc3.components(separatedBy: "Self.log.debug(").count - 1 == 4
              && !profileApplySrc3.contains("Self.log.info(")
              && !profileApplySrc3.contains("Self.log.notice("),
          "源钉-9", "级别反钉（装具分级）：.error 恰四（ABORT 双臂 + ABORT+2s 双臂——异常取证主通道持久化可查）+ .debug 恰四（chain start/advance/dispatch/finish 正常链路）+ info/notice 负钉保留")
    // 隐私反钉：全部插值 privacy: .public（os_log 隐私默认私有——否则 log show
    // 侧只见 <private> 取证失效；`, privacy: .public)` 恰 33 处 = 八打点行插值
    // 逐个标注的精确总数。0.23.20 联动改写：ABORT 行双原串各 +1（31 → 33）——
    // 单插值 helper（forensicTruncated 返回完整串）形态，拆三插值则为 35 由本
    // 计数钉强制对齐）。
    check(profileApplySrc3.components(separatedBy: ", privacy: .public)").count - 1 == 33,
          "源钉-9", "隐私反钉：Logger 插值恰 33 处全 privacy: .public（数值/String/面串逐个标注——八行插值总数精确断言；0.23.20 ABORT 双原串 schedRaw/expected 各 +1：31 → 33）")
    // 六打点字面在位（§2 打点面五处 + 延迟复核；plan 步型序列 String(describing:)
    // 逐元素全形重建 T1 实际步序）。
    check(profileApplySrc3.contains("chain start name=")
              && profileApplySrc3.contains("advance #executed=")
              && profileApplySrc3.contains("ABORT name=")
              && profileApplySrc3.contains("finish name=")
              && profileApplySrc3.contains("dispatch step=")
              && profileApplySrc3.contains("ABORT+2s name=")
              && profileApplySrc3.contains("Self.forensicPlan(plan)"),
          "源钉-9", "六打点字面在位（chain start / advance / ABORT / finish / dispatch / ABORT+2s + plan 数组 String(describing:) 重建）")
    // abortChain(status:) 定版签名 + 双调用点形态 + 清链前捕获（评审 P1-2）。
    check(profileApplySrc3.contains("private func abortChain(status: DaemonStatus?)")
              && !profileApplySrc3.contains("private func abortChain()"),
          "源钉-9", "abortChain(status:) 定版签名（无参形态退役——DaemonStatus? 可选承载「有/无现读回」两臂）")
    check(profileApplySrc3.contains("abortChain(status: status)")
              && profileApplySrc3.contains("abortChain(status: nil)"),
          "源钉-9", "双调用点形态（守卫臂传现读回——在作用域处；LED 非法 raw 臂传 nil——省略 match/status 段）")
    let abortSegment = profileApplySrc3.components(
        separatedBy: "private func abortChain(status: DaemonStatus?)").dropFirst().first ?? ""
    check(abortSegment.range(of: "let payload = profileChain?.payload")?.lowerBound
              ?? abortSegment.startIndex
              < abortSegment.range(of: "profileChain = nil")?.lowerBound ?? abortSegment.endIndex,
          "源钉-9", "清链前捕获 payload（2s 延迟复核的输入——清链后 profileChain 为 nil；name→捕获→清链→拒绝上屏原行序不变）")
    // 2s 延迟单发观测（P3-2 + 二轮 P3 补比较基准）：abort 2s 后 daemonStatus
    // 快照 + matchReport 八域复核布尔——收敛结论直接落日志不靠肉眼比对。
    check(profileApplySrc3.contains("Task.sleep(for: .seconds(2))")
              && profileApplySrc3.contains("StatusController.shared.daemonStatus")
              && profileApplySrc3.contains("ProfileModel.matchReport(profile: payload, current: now)"),
          "源钉-9", "2s 延迟单发观测（Task sleep 2s → 读 shared.daemonStatus → matchReport 复核——「abort 某瞬态、后收敛 ✓ 亮而横幅残留」缺陷形态的后半程取证）")
    // matchReport/MatchReport public 纯新增反钉（消费方在 App 目标跨模块——
    // 返回类型可见性须 ≥ 函数可见性；applyPlan/activeMatch 先例同 public 形态）。
    let profileModelSrc2 = source("Sources/CellarCore/Control/ProfileModel.swift")
    check(profileModelSrc2.contains("public struct MatchReport: Sendable, Equatable")
              && profileModelSrc2.contains("public static func matchReport(profile: ProfilePayload, current: DaemonStatus) -> MatchReport"),
          "源钉-9", "matchReport/MatchReport public 纯新增（Sendable/Equatable 值类型——CellarCore 纯值层纪律）")
    check(profileModelSrc2.components(separatedBy: "private static func").count - 1 == 11,
          "源钉-9", "既有比较域 helper 零改动（private static func 恰 11 个原数不变——纯新增出口复用 limitsMatch/六域 helper 单源，判定面一行不动）")
    check(profileModelSrc2.contains("mode: profile.mode == current.mode")
              && profileModelSrc2.contains("limits: limitsMatch(profile, current)")
              && profileModelSrc2.contains("fan: fanFieldMatches(profile, current)")
              && profileModelSrc2.contains("thermal: thermalFieldMatches(profile, current)")
              && profileModelSrc2.contains("schedule: scheduleFieldMatches(profile, current)")
              && profileModelSrc2.contains("calibration: calibrationFieldMatches(profile, current)")
              && profileModelSrc2.contains("ch: chFieldMatches(profile, current)")
              && profileModelSrc2.contains("led: ledFieldMatches(profile, current)")
              && profileModelSrc2.contains("fanSkipped: profile.fan == nil")
              && profileModelSrc2.contains("ledSkipped: profile.magSafeLedMode == nil"),
          "源钉-9", "MatchReport 八域映射复用既有 helper + skip 分立承载 nil 未捕获（nil 未捕获与 false 匹配不可混；八布尔全真 ⇔ readbackMatches 真同源）")
    // 行为面（评审方向之外加严——matchReport 纯函数直测：全匹配 / 单域翻转 /
    // nil 跳过三形态）。
    let reportHit = ProfileModel.matchReport(profile: capturedProfile(from: base), current: base)
    check(reportHit == MatchReport(mode: true, limits: true, fan: true, thermal: true,
                                   schedule: true, calibration: true, ch: true, led: true,
                                   fanSkipped: false, thermalSkipped: false, scheduleSkipped: false,
                                   calibrationSkipped: false, chSkipped: false, ledSkipped: false),
          "源钉-9", "行为面：全匹配报告（八域全 true + 六 skip 全 false——与 readbackMatches 全真 / applyPlan 空同判）")
    var driftedReportProfile = capturedProfile(from: base)
    driftedReportProfile.upperLimit = 65
    let reportDrift = ProfileModel.matchReport(profile: driftedReportProfile, current: base)
    check(!reportDrift.limits && reportDrift.mode && reportDrift.fan && reportDrift.led,
          "源钉-9", "行为面：限值漂移仅 limits 翻假（逐域独立——余域布尔如实保留不连坐）")
    var noFanReportProfile = capturedProfile(from: base)
    noFanReportProfile.fan = nil
    let reportSkip = ProfileModel.matchReport(profile: noFanReportProfile, current: base)
    check(reportSkip.fanSkipped && reportSkip.fan && !reportSkip.thermalSkipped && reportSkip.thermal,
          "源钉-9", "行为面：nil 未捕获域 skip 标记分立（fan 快照缺席 → fanSkipped true 且域布尔按 skip 语义不参与判——与 false 匹配失败不可混）")

    // ---- 方案-12：scheduleSemanticallyEqual 向量表（0.23.20 热修 §3——byte
    // 形态免疫的语义域逐向量钉死；函数单源 = 判定域唯一 schedule 比较面）----

    // byte 异语义同（两形态空配置字面量直构——JSONEncoder 键序跨二进制漂移的
    // 两种现场形态：daemon enabled 在前 / App entries 在前，§1 物证表）→ true。
    let daemonFormEmpty = scheduleFixture   // {"enabled":false,"entries":[]}（enabled 在前）
    let appFormEmpty = #"{"entries":[],"enabled":false}"#   // entries 在前
    check(ProfileModel.scheduleSemanticallyEqual(appFormEmpty, daemonFormEmpty)
              && ProfileModel.scheduleSemanticallyEqual(daemonFormEmpty, appFormEmpty),
          "方案-12", "byte 异语义同 → true（两形态空配置字面量直构、双向对称——键序漂移免疫主向量）")
    check(ProfileModel.scheduleSemanticallyEqual(daemonFormEmpty, daemonFormEmpty),
          "方案-12", "byte 同 → true（byte 全等平凡向量）")
    let oneEntry = #"{"enabled":false,"entries":[{"id":"e1","weekdays":[1],"startMinute":540,"endMinute":1080,"upperLimit":80}]}"#
    check(!ProfileModel.scheduleSemanticallyEqual(oneEntry, daemonFormEmpty)
              && !ProfileModel.scheduleSemanticallyEqual(daemonFormEmpty, oneEntry),
          "方案-12", "entries 数不同 → false（真漂移不误判收敛——Equatable 全字段 R1 守护面）")
    check(!ProfileModel.scheduleSemanticallyEqual(#"{"enabled":true,"entries":[]}"#, daemonFormEmpty),
          "方案-12", "enabled 不同 → false（enabled 单键翻转语义异）")
    check(!ProfileModel.scheduleSemanticallyEqual(nil, daemonFormEmpty)
              && !ProfileModel.scheduleSemanticallyEqual(daemonFormEmpty, nil),
          "方案-12", "单边 nil → false（未捕获 ≠ 空配置——双向对称）")
    check(ProfileModel.scheduleSemanticallyEqual(nil, nil),
          "方案-12", "双边 nil → true（双双未捕获——语义等平凡真）")
    check(ProfileModel.scheduleSemanticallyEqual("not-json", "not-json"),
          "方案-12", "解码失败单边 → byte 兜底：byte 相等 → true（不可解串不猜）")
    check(!ProfileModel.scheduleSemanticallyEqual("not-json", daemonFormEmpty),
          "方案-12", "解码失败单边 → byte 兜底：byte 不等 → false（诚实保守——异串不判等）")

    // ---- 方案-13：applyPlan 语义免疫（0.23.20 缺陷回归门——§1 根因「profile 串
    // App 形态 / daemon 回包串 daemon 形态 byte 恒不等 → 链入口 diff 恒不等 →
    // 每步重推导恒含同型步 → 守卫一 abortChain」的修复面）----

    var semanticProfile = capturedProfile(from: base)
    semanticProfile.scheduleJson = appFormEmpty   // App 形态（entries 在前）
    // current = base（scheduleJson = daemon 形态 fixture 原文，enabled 在前）。
    // 两字面量键序相反 → byte 恒不等（任何二进制下成立）；解码值全等 → 语义等。
    let plan13 = ProfileModel.applyPlan(profile: semanticProfile, current: base)
    check(semanticProfile.scheduleJson != base.scheduleJson,
          "方案-13", "前提钉：两形态字面量 byte 恒不等（键序相反——本场景确实行使在 byte 差异面上，二进制无关）")
    check(!kinds(plan13).contains("schedule"),
          "方案-13", "语义等 → plan 不含 setChargeSchedule（byte 异语义同不再发步——读回未收敛中止缺陷回归门）")
    check(plan13.isEmpty
              && ProfileModel.activeMatch(profiles: [semanticProfile], current: base) == semanticProfile.id,
          "方案-13", "整计划空 + activeMatch 命中（同比较域互证——✓ 标注对两形态同样免疫）")

    // ---- 方案-14：capture 写时归一（0.23.20 热修 §2——存储串稳定性加固：
    // 存量字节自洽 + 未来任何 byte 消费者稳定）----

    // daemon 形态串输入 → 存储串语义等输入 + 可解析。0.23.21-alpha 整理批改写
    // （登记偏差，主代理裁决批准）：原字节基准（== 同二进制 decoded!.encoded，
    // 评审 P2「禁硬编码键序字面量，场景自身不成为键序漂移受害者」）在 -O 逐次
    // 键序漂移下不稳定（方案-1 同款平台事实）→ 升语义域；归一存在面由源钉-10
    // 源码钉承载（decoded.encoded ?? scheduleJson）。
    var normalizeStatus = fullStatus()
    normalizeStatus.scheduleJson = daemonFormEmpty
    let normalizedCapture = ProfileModel.capture(from: normalizeStatus)
    check(ProfileModel.scheduleSemanticallyEqual(normalizedCapture?.scheduleJson, daemonFormEmpty)
              && (try? ChargeScheduleConfig.decoded(from: normalizedCapture?.scheduleJson ?? "")) != nil,
          "方案-14", "capture 归一存语义域：daemon 形态串输入 → 存储串解码值 == 输入解码值 + 可解析（decoded!.encoded 字节基准随 -O 逐次键序漂移退役——「场景自身不成为键序漂移受害者」按设计本旨落地；归一存在面由源钉-10 源码钉承载）")
    // 归一保语义：存储串解码值 == 输入串解码值（归一只收形态，不改语义）。
    check((try? ChargeScheduleConfig.decoded(from: normalizedCapture?.scheduleJson ?? ""))
              == (try? ChargeScheduleConfig.decoded(from: daemonFormEmpty)),
          "方案-14", "归一保语义：存储串解码值 == 输入串解码值（形态收敛非语义改写）")
    // 非法串输入 → 原样存（解码失败不猜——诚实兜底）。
    var invalidStatus = fullStatus()
    invalidStatus.scheduleJson = #"{"enabled":false,"entries":[]"#   // 截断非法串
    check(ProfileModel.capture(from: invalidStatus)?.scheduleJson == invalidStatus.scheduleJson,
          "方案-14", "非法串输入 → 原样存（解码失败兜底不猜）")

}
