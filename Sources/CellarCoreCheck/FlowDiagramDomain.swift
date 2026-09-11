// CellarCoreCheck —— v0.19.3 功率流向语义域（方案 §D2 判定表 + §5 十九场景）：
// FlowDiagramKind 实测符号裁决（charging/holding/assist/battery）/ 零流 ε 带
// （|BP| ≤ 50 mW → holding，边界 ==50 落 holding）/ V×I 显示阈值（|V×I| < 0.05 W
// → batteryEdgeW=nil，不得产出「−0.0 W」）/ 遥测缺席回退分层（charging=viEdge、
// holding direct=spW）/ assist 不看策略位 / SP<BP 异常 load=nil / nodata 全零
// 防御——纯函数面（FlowDiagramModel，Equatable 整体断言）。
// 0.19.4 §5：补入态词汇统一批配套——场景 20/21（flowModel(of:) 快照投影 ≡ 六参
// 直调）+ 场景 22–25（currentDirection(kind:) 四态映射），总数 578 → 584。
// v0.19.5 §3：assist 代际确认门——旧场景 3/4/5/16/20 改构造加 previous（满足
// 确认条件，.assist 断言保持不变）+ 场景 26–34（未确认窗口充电/停充两侧死角、
// 确认进入/锁存维持/锁存退出、首代保守两侧、ε 抖动序列、旧场景带前态回归），
// 总数 584 → 593。
import CellarCore
import Foundation

/// 功率流向语义场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
/// 0.19.4：转 throws（场景 20/21 经 BatterySnapshotParser 构造快照——
/// 与 runChargeScheduleDomainScenarios 等 throws 域同先例）。
func runFlowDiagramDomainScenarios() throws {
    // 入参工厂（默认外接 + 充电使能 + V×I 零——把注意力集中在被测判定上）。
    // v0.19.5 §D1：末位透传 previous 前态（默认 nil = 首代保守，既有场景零改动）。
    func makeModel(
        externalConnected: Bool = true,
        isCharging: Bool = true,
        systemPowerInMW: Int? = nil,
        batteryPowerMW: Int? = nil,
        batteryVoltageMV: Int = 0,
        batteryAmperageMA: Int = 0,
        previous: FlowDiagramPreviousSample? = nil
    ) -> FlowDiagramModel {
        flowDiagramModel(
            externalConnected: externalConnected,
            isCharging: isCharging,
            systemPowerInMW: systemPowerInMW,
            batteryPowerMW: batteryPowerMW,
            batteryVoltageMV: batteryVoltageMV,
            batteryAmperageMA: batteryAmperageMA,
            previous: previous
        )
    }

    // 场景 1：充电（SP=62700, BP=+18600, isCharging=true）→ .charging，edge=+18.6，
    // direct=load=44.1（直供边 = 负载：SP = 负载 + BP 同式）。
    do {
        let model = makeModel(systemPowerInMW: 62_700, batteryPowerMW: 18_600)
        expectEqual(model, FlowDiagramModel(kind: .charging, batteryEdgeW: 18.6, directEdgeW: 44.1, systemLoadW: 44.1),
                    "流向-1", "充电（遥测齐全）→ .charging 且三边同快照守恒")
    }

    // 场景 2：零流（BP=0）→ .holding，edge=nil，direct=load=SP。
    do {
        let model = makeModel(systemPowerInMW: 62_700, batteryPowerMW: 0)
        expectEqual(model, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 62.7, systemLoadW: 62.7),
                    "流向-2", "零流 → .holding（无电池边，直供=SP）")
    }

    // 场景 3：补入（SP=29900, BP=−6500, isCharging=true）→ .assist，edge=−6.5，
    // direct=29.9（min(SP, 负载)），load=36.4（直供 + 补入 = 系统节点）。
    // v0.19.5 改构造：加 previous 满足确认条件（prevBP<−ε + SP 换代 → 换代进入
    // 路径），.assist 断言保持不变（改写不改语义）。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 28_000, batteryPowerMW: -6_500, kind: nil)
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -6_500, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-3", "补入（弱适配器，换代确认）→ .assist 且 direct+edge=load")
    }

    // 场景 4：大补入（SP=29900, BP=−23000, isCharging=true）→ .assist，edge=−23.0，
    // direct=29.9，load=52.9（截图②形态——BP 幅值超过 SP 仍取 SP）。
    // v0.19.5 改构造：加 previous 走**锁存维持**路径（prev.kind == .assist、同值
    // 未换代也保持），.assist 断言保持不变。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: -23_000, kind: .assist)
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -23_000, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -23.0, directEdgeW: 29.9, systemLoadW: 52.9),
                    "流向-4", "大补入（锁存维持）→ .assist（directEdgeW 恒取 SP）")
    }

    // 场景 5：补入但 !isCharging（放电动作/适配器被禁）→ .assist（assist 不看策略位）。
    // v0.19.5 改构造：加 previous 满足确认条件（prevBP<−ε + BP 换代——SP 同值、
    // 仅 BP 变化也算换代），.assist 断言保持不变。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: -5_000, kind: nil)
        let model = makeModel(isCharging: false, systemPowerInMW: 29_900, batteryPowerMW: -6_500, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-5", "补入与策略位无关（!isCharging 仍 .assist，换代确认）")
    }

    // 场景 6：ε 内负（BP=−40 mW > −50）→ .holding。IEEE 注记：29.9−(−0.04) 的
    // double 为 29.939999999999998 ≠ 字面量 29.94，负载按 1e-9 容差断言。
    do {
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -40)
        let loadOK = model.systemLoadW.map { abs($0 - 29.94) < 1e-9 } ?? false
        check(model.kind == .holding && model.batteryEdgeW == nil && model.directEdgeW == 29.9 && loadOK,
              "流向-6", "ε 内负流 → .holding（不误判 assist），load≈29.94")
    }

    // 场景 7：ε 内正（BP=+40, !isCharging 停充尾态族）→ .holding，edge=nil，
    // direct=SP，load=29.86（29.9−0.04 double 精确）。
    do {
        let model = makeModel(isCharging: false, systemPowerInMW: 29_900, batteryPowerMW: 40)
        expectEqual(model, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 29.9, systemLoadW: 29.86),
                    "流向-7", "ε 内正流 → .holding（直供=SP）")
    }

    // 场景 8：ε 边界（BP=±50）→ .holding（边界 ==50 落 holding，不落 charging/assist）；
    // 零流阈值常量钉死 50 mW。
    do {
        let plus = makeModel(systemPowerInMW: 29_900, batteryPowerMW: 50)
        let minus = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -50)
        check(plus.kind == .holding && plus.batteryEdgeW == nil
                && minus.kind == .holding && minus.batteryEdgeW == nil,
              "流向-8", "BP=±50（|BP| == ε）→ .holding（边界归属钉死）")
        expectEqual(flowDiagramZeroFlowEpsilonMW, 50, "流向-8", "零流阈值 = 50 mW")
    }

    // 场景 9：isCharging=true && |BP|≤ε → .holding（徽章「充电中」而图形 holding
    // = 已知分叉形态，§7.7——ε 带内不画假流）。
    do {
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: 40)
        check(model.kind == .holding && model.batteryEdgeW == nil,
              "流向-9", "isCharging=true 且 |BP|≤ε → .holding（徽章/图形分叉已知形态）")
    }

    // 场景 10：遥测缺席 + isCharging → 回退 .charging，edge=|V×I|（11.67×1.8=21.006），
    // direct/load=nil（旧 derivedSystemLoadW 需双在场）。
    do {
        let model = makeModel(systemPowerInMW: nil, batteryPowerMW: nil, batteryVoltageMV: 11_670, batteryAmperageMA: 1_800)
        expectEqual(model, FlowDiagramModel(kind: .charging, batteryEdgeW: 21.006, directEdgeW: nil, systemLoadW: nil),
                    "流向-10", "遥测缺席 + isCharging → 回退 charging（edge=|V×I|）")
    }

    // 场景 11：遥测缺席 + !isCharging + SP 在场 → .holding，direct=SP（仅需 SP 在场
    // ——supplyLine holding 分支，R1 P2-1），load=nil。
    do {
        let model = makeModel(isCharging: false, systemPowerInMW: 62_700, batteryPowerMW: nil, batteryVoltageMV: 11_670, batteryAmperageMA: 1_800)
        expectEqual(model, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 62.7, systemLoadW: nil),
                    "流向-11", "回退 holding：direct=SP（SP 单在场即取）")
    }

    // 场景 12：遥测缺席 + !isCharging + SP 缺席 → .holding 全 nil（App 显「直供」纯词）。
    do {
        let model = makeModel(isCharging: false, systemPowerInMW: nil, batteryPowerMW: nil, batteryVoltageMV: 11_670, batteryAmperageMA: 1_800)
        expectEqual(model, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: nil, systemLoadW: nil),
                    "流向-12", "回退 holding：SP 缺席 → 全 nil 不造数")
    }

    // 场景 13：SP 在位 / BP 缺席 → 回退（同 10/11 双面）：isCharging → .charging
    // （edge=|V×I|）；!isCharging → .holding（direct=SP）。
    do {
        let charging = makeModel(isCharging: true, systemPowerInMW: 62_700, batteryPowerMW: nil, batteryVoltageMV: 11_670, batteryAmperageMA: 1_800)
        expectEqual(charging, FlowDiagramModel(kind: .charging, batteryEdgeW: 21.006, directEdgeW: nil, systemLoadW: nil),
                    "流向-13", "SP 在位/BP 缺席 + isCharging → 回退 charging")
        let holding = makeModel(isCharging: false, systemPowerInMW: 62_700, batteryPowerMW: nil, batteryVoltageMV: 11_670, batteryAmperageMA: 1_800)
        expectEqual(holding, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 62.7, systemLoadW: nil),
                    "流向-13", "SP 在位/BP 缺席 + !isCharging → 回退 holding（direct=SP）")
    }

    // 场景 14：电池态（!ext）→ .battery，edge=load=|V×I|（21.006），direct=nil
    // （系统节点无阈值——现状口径）。
    do {
        let model = makeModel(externalConnected: false, isCharging: false, batteryVoltageMV: 11_670, batteryAmperageMA: -1_800)
        expectEqual(model, FlowDiagramModel(kind: .battery, batteryEdgeW: 21.006, directEdgeW: nil, systemLoadW: 21.006),
                    "流向-14", "电池供电 → .battery（edge/load 同取 |V×I|）")
    }

    // 场景 15：V×I 幅值 <0.05 W → batteryEdgeW=nil（不得产出「−0.0 W」）；系统节点
    // 无阈值照旧（load=0.04668）；显示阈值常量钉死 0.05。
    do {
        let model = makeModel(externalConnected: false, isCharging: false, batteryVoltageMV: 11_670, batteryAmperageMA: -4)
        expectEqual(model, FlowDiagramModel(kind: .battery, batteryEdgeW: nil, directEdgeW: nil, systemLoadW: 0.04668),
                    "流向-15", "|V×I|<0.05 → batteryEdgeW=nil（load 无阈值照旧）")
        expectEqual(flowDiagramEdgeDisplayThresholdW, 0.05, "流向-15", "显示阈值 = 0.05 W")
    }

    // 场景 16：BP 回绕负值（UInt64 还原后的 Int 负值——v1.11 B-4 parser 纪律下游）
    // → .assist 幅值正确。v0.19.5 改构造：加 previous 双路满足（prevBP<−ε +
    // SP 换代 + prev.kind == .assist），.assist 断言保持不变。
    do {
        let wrapped = Int(Int64(bitPattern: UInt64(bitPattern: Int64(-6_500))))
        expectEqual(wrapped, -6_500, "流向-16", "回绕还原自检：bitPattern 往返 = −6500")
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 30_000, batteryPowerMW: -6_000, kind: .assist)
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: wrapped, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-16", "回绕负值 BP → .assist 幅值正确（换代+锁存双路确认）")
    }

    // 场景 17：SP < BP 异常（SP=10000, BP=+18600, isCharging=true）→ loadW<0 →
    // systemLoadW=nil、directEdgeW=nil，kind=.charging（仍由 BP+策略位裁决，负值不造数）。
    do {
        let model = makeModel(systemPowerInMW: 10_000, batteryPowerMW: 18_600)
        expectEqual(model, FlowDiagramModel(kind: .charging, batteryEdgeW: 18.6, directEdgeW: nil, systemLoadW: nil),
                    "流向-17", "SP<BP 异常 → load/direct=nil 不造数，kind 仍 .charging")
    }

    // 场景 18：nodata 防御——externalConnected=false + 全零入参 → .battery 且
    // batteryEdgeW=nil（不产出「0.0 W」电池边）。
    do {
        let model = makeModel(externalConnected: false, isCharging: false, systemPowerInMW: nil, batteryPowerMW: nil, batteryVoltageMV: 0, batteryAmperageMA: 0)
        check(model.kind == .battery && model.batteryEdgeW == nil && model.directEdgeW == nil,
              "流向-18", "nodata 全零 → edge=nil（不产出「0.0 W」）")
    }

    // 场景 19：BP 在位 / SP 缺席 → 回退（R2 P2）：isCharging=true → .charging，
    // edge=|V×I|，direct/load=nil（值仍 V×I——App 侧功率行标签不得误标「遥测」）。
    do {
        let model = makeModel(isCharging: true, systemPowerInMW: nil, batteryPowerMW: 6_500, batteryVoltageMV: 11_670, batteryAmperageMA: 1_800)
        expectEqual(model, FlowDiagramModel(kind: .charging, batteryEdgeW: 21.006, directEdgeW: nil, systemLoadW: nil),
                    "流向-19", "BP 在场/SP 缺席 → 回退 charging（edge=|V×I|）")
    }

    // 场景 20：flowModel(of:) 快照便捷投影 ≡ 六参直调（0.19.4 §1.1/§5-1）——
    // 遥测在场 assist：复刻真机截图现场（SP=29800, BP=−22600, isCharging=true）。
    // 快照经 BatterySnapshotParser 真实解析路径构造（batteryProps + 遥测键）。
    // v0.19.5 改构造：两侧同传 previous（prevBP<−ε + SP 换代 → 换代确认），
    // .assist 断言保持不变（改写不改语义）。
    do {
        var props = batteryProps()
        props["PowerTelemetryData"] = ["SystemPowerIn": 29_800, "BatteryPower": -22_600]
        let snapshot = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 0))
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 28_000, batteryPowerMW: -20_000, kind: nil)
        let projected = flowModel(of: snapshot, previous: previous)
        let direct = makeModel(
            externalConnected: snapshot.externalConnected, isCharging: snapshot.isCharging,
            systemPowerInMW: 29_800, batteryPowerMW: -22_600,
            batteryVoltageMV: snapshot.voltageMV, batteryAmperageMA: snapshot.amperageMA,
            previous: previous
        )
        expectEqual(projected, direct, "流向-20", "flowModel(of:) ≡ 六参直调（遥测在场 assist，同传前态）")
        check(projected.kind == .assist && projected.batteryEdgeW == -22.6 && projected.directEdgeW == 29.8,
              "流向-20", "投影 kind == .assist，edge=−22.6 / direct=29.8（真机现场复刻）")
    }

    // 场景 21：flowModel(of:) ≡ 六参直调（遥测缺席 → ② 回退 charging，
    // edge=|V×I|=9.048351，batteryProps 12211 mV × −741 mA）。
    do {
        let snapshot = try BatterySnapshotParser.parse(batteryProps(), timestamp: Date(timeIntervalSince1970: 0))
        let projected = flowModel(of: snapshot)
        let direct = makeModel(
            externalConnected: snapshot.externalConnected, isCharging: snapshot.isCharging,
            systemPowerInMW: nil, batteryPowerMW: nil,
            batteryVoltageMV: snapshot.voltageMV, batteryAmperageMA: snapshot.amperageMA
        )
        expectEqual(projected, direct, "流向-21", "flowModel(of:) ≡ 六参直调（遥测缺席回退 charging）")
        check(projected.kind == .charging && projected.batteryEdgeW == 9.048351
                && projected.directEdgeW == nil && projected.systemLoadW == nil,
              "流向-21", "投影 kind == .charging，edge=|V×I|，direct/load=nil")
    }

    // 场景 22–25：currentDirection(kind:) 四态映射（0.19.4 §1.1——charging →
    // .charging；assist / battery → .discharging；holding → nil 只显幅值）。
    do {
        expectEqual(currentDirection(kind: .charging), .charging,
                    "流向-22", "currentDirection(.charging) → .charging")
    }
    do {
        expectEqual(currentDirection(kind: .assist), .discharging,
                    "流向-23", "currentDirection(.assist) → .discharging（补入 = 放电向）")
    }
    do {
        expectEqual(currentDirection(kind: .battery), .discharging,
                    "流向-24", "currentDirection(.battery) → .discharging")
    }
    do {
        check(currentDirection(kind: .holding) == nil,
              "流向-25", "currentDirection(.holding) → nil（方向词隐藏、幅值照显）")
    }

    // MARK: v0.19.5 §3 assist 代际确认门（场景 26–34；21–25 已被 0.19.4 占用顺延）

    // 场景 26：未确认-充电侧（复刻事故现场，方案 §1.1：SP=64000, BP=−25300,
    // isCharging=true，上一帧同值未换代）→ kind 跟随 isCharging 落 .charging，
    // 数字侧全 nil 不造数、直供边照显 SP——方向永不因陈旧数据反转。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 64_000, batteryPowerMW: -25_300, kind: nil)
        let model = makeModel(systemPowerInMW: 64_000, batteryPowerMW: -25_300, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .charging, batteryEdgeW: nil, directEdgeW: 64.0, systemLoadW: nil),
                    "流向-26", "未确认-充电侧（旧代负 BP 未换代）→ .charging + edge/load=nil（不显 assist 假数）")
    }

    // 场景 27：未确认-停充侧死角（R1 P0-2 同构封堵）：isCharging=false、BP=−25300、
    // prev 未换代 → .holding + edge/load=nil。**不得落 load=SP+|BP|=89.3 虚高
    // 形态**（ Equatable 整体断言把 systemLoadW=nil 一并钉死）。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 64_000, batteryPowerMW: -25_300, kind: nil)
        let model = makeModel(isCharging: false, systemPowerInMW: 64_000, batteryPowerMW: -25_300, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 64.0, systemLoadW: nil),
                    "流向-27", "未确认-停充侧死角 → .holding + load=nil（不得为 SP+|BP| 虚高）")
    }

    // 场景 28：确认进入（连续两帧 BP<−ε 且确已换代）：isCharging=true、BP=−6500、
    // prevSP≠SP（换代）、prevBP=−6500 → .assist 数值齐全。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 30_000, batteryPowerMW: -6_500, kind: nil)
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -6_500, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-28", "确认进入（换代 + 连续两帧负 BP）→ .assist")
    }

    // 场景 29：锁存维持：prevKind=.assist、BP=−6500、同值未换代 → 仍 .assist
    // （稳态字典不动也保持——原始持久补差场景不被回退；退出 = BP ≥ −ε 或 !ext）。
    do {
        let previous = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: -6_500, kind: .assist)
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -6_500, previous: previous)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-29", "锁存维持（未换代）→ .assist（字典停更不回退）")
    }

    // 场景 30：锁存退出：prevKind=.assist、BP=0 → 常规 ③。BP=0（|BP|≤ε）→
    // .holding；BP=+18600 → .charging（两退出方向同帧验证）。
    do {
        let assistPrev = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: -6_500, kind: .assist)
        let hold = makeModel(systemPowerInMW: 29_900, batteryPowerMW: 0, previous: assistPrev)
        expectEqual(hold, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 29.9, systemLoadW: 29.9),
                    "流向-30", "锁存退出：BP=0 → 常规 .holding（assist 不锁死）")
        let charge = makeModel(systemPowerInMW: 62_700, batteryPowerMW: 18_600, previous: assistPrev)
        expectEqual(charge, FlowDiagramModel(kind: .charging, batteryEdgeW: 18.6, directEdgeW: 44.1, systemLoadW: 44.1),
                    "流向-30", "锁存退出：BP>ε → 常规 .charging")
    }

    // 场景 31：首代保守（previous == nil——App 启动首帧/断代后首帧）：isCharging=
    // true、BP=−6500 → 未确认窗口（宁显无数字，不显可能陈旧的 assist；进入代价
    // ≤ 一个字典代际）。
    do {
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -6_500)
        expectEqual(model, FlowDiagramModel(kind: .charging, batteryEdgeW: nil, directEdgeW: 29.9, systemLoadW: nil),
                    "流向-31", "首代保守（prev=nil）充电侧 → .charging + 数字 nil")
    }

    // 场景 32：首代保守-停充侧：prev=nil、isCharging=false、BP=−6500 → .holding
    // + 数字 nil（死角同构，不落 load 虚高）。
    do {
        let model = makeModel(isCharging: false, systemPowerInMW: 29_900, batteryPowerMW: -6_500)
        expectEqual(model, FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: 29.9, systemLoadW: nil),
                    "流向-32", "首代保守（prev=nil）停充侧 → .holding + 数字 nil")
    }

    // 场景 33：ε 抖动序列（BP −60/−40 交替 + 每帧 BP 值变化 = 换代）→ 各帧独立
    // 判定：−60 帧未确认（prev.kind 恒非 assist、prevBP 恒 ≥ −ε——−40 帧打破
    // 「连续两帧负」链）/ −40 帧落 ε 带 holding。钉「每帧诚实、可接受闪烁」。
    do {
        // 帧 1：BP=−60（prev0 同 SP、BP=0、kind=.holding）→ 未确认充电侧。
        let prev0 = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: 0, kind: .holding)
        let frame1 = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -60, previous: prev0)
        check(frame1.kind == .charging && frame1.batteryEdgeW == nil
                && frame1.systemLoadW == nil && frame1.directEdgeW == 29.9,
              "流向-33", "ε 抖动帧 1（BP=−60，prevBP=0）→ 未确认 .charging 无数字")
        // 帧 2：BP=−40（prev=帧 1 三元组）→ |BP|≤ε → .holding（edge=nil，
        // load=SP−BP=29.94，IEEE 容差断言同场景 6）。
        let prev1 = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: -60, kind: frame1.kind)
        let frame2 = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -40, previous: prev1)
        let load2OK = frame2.systemLoadW.map { abs($0 - 29.94) < 1e-9 } ?? false
        check(frame2.kind == .holding && frame2.batteryEdgeW == nil && load2OK,
              "流向-33", "ε 抖动帧 2（BP=−40）→ .holding（ε 带照旧，数字诚实）")
        // 帧 3：BP=−60（prev=帧 2 三元组：prevBP=−40 ≥ −ε 打破连续负链）→
        // 仍未确认——单帧 ε 内抖动不触发确认门。
        let prev2 = FlowDiagramPreviousSample(systemPowerInMW: 29_900, batteryPowerMW: -40, kind: frame2.kind)
        let frame3 = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -60, previous: prev2)
        check(frame3.kind == .charging && frame3.batteryEdgeW == nil && frame3.systemLoadW == nil,
              "流向-33", "ε 抖动帧 3（BP=−60，prevBP=−40 打破连续负链）→ 仍未确认")
    }

    // 场景 34：旧场景带前态回归（改写不改语义的集中钉）：场景 3/4/5/16 的原始
    // 入参各加 previous（prevBP<−ε + 换代）→ 仍 .assist 且数值与原断言一致。
    do {
        let wrapped = Int(Int64(bitPattern: UInt64(bitPattern: Int64(-6_500))))
        let legacyCases: [(bp: Int, charging: Bool, expected: FlowDiagramModel)] = [
            // 场景 3 原入参（SP=29900, BP=−6500, isCharging=true）。
            (-6_500, true, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4)),
            // 场景 4 原入参（BP=−23000）。
            (-23_000, true, FlowDiagramModel(kind: .assist, batteryEdgeW: -23.0, directEdgeW: 29.9, systemLoadW: 52.9)),
            // 场景 5 原入参（!isCharging）。
            (-6_500, false, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4)),
            // 场景 16 原入参（回绕负值）。
            (wrapped, true, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4)),
        ]
        for legacy in legacyCases {
            // previous：SP 少 100（换代）+ prevBP 再负 100（恒 < −ε，bp ≤ −6500
            // → prevBP ≤ −6600）+ kind nil（纯走「换代 + 连续两帧负」进入路径）。
            let previous = FlowDiagramPreviousSample(
                systemPowerInMW: 29_800, batteryPowerMW: legacy.bp - 100, kind: nil)
            let model = makeModel(
                isCharging: legacy.charging, systemPowerInMW: 29_900,
                batteryPowerMW: legacy.bp, previous: previous)
            expectEqual(model, legacy.expected, "流向-34",
                        "旧场景带前态回归（BP=\(legacy.bp), charging=\(legacy.charging)）→ .assist 语义不变")
        }
    }
}
