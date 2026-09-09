// CellarCoreCheck —— v0.19.3 功率流向语义域（方案 §D2 判定表 + §5 十九场景）：
// FlowDiagramKind 实测符号裁决（charging/holding/assist/battery）/ 零流 ε 带
// （|BP| ≤ 50 mW → holding，边界 ==50 落 holding）/ V×I 显示阈值（|V×I| < 0.05 W
// → batteryEdgeW=nil，不得产出「−0.0 W」）/ 遥测缺席回退分层（charging=viEdge、
// holding direct=spW）/ assist 不看策略位 / SP<BP 异常 load=nil / nodata 全零
// 防御——纯函数面（FlowDiagramModel，Equatable 整体断言）。
import CellarCore
import Foundation

/// 功率流向语义场景域入口（Main.main 调用；断言经 MainEntry.swift 的 internal 助手）。
func runFlowDiagramDomainScenarios() {
    // 入参工厂（默认外接 + 充电使能 + V×I 零——把注意力集中在被测判定上）。
    func makeModel(
        externalConnected: Bool = true,
        isCharging: Bool = true,
        systemPowerInMW: Int? = nil,
        batteryPowerMW: Int? = nil,
        batteryVoltageMV: Int = 0,
        batteryAmperageMA: Int = 0
    ) -> FlowDiagramModel {
        flowDiagramModel(
            externalConnected: externalConnected,
            isCharging: isCharging,
            systemPowerInMW: systemPowerInMW,
            batteryPowerMW: batteryPowerMW,
            batteryVoltageMV: batteryVoltageMV,
            batteryAmperageMA: batteryAmperageMA
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
    do {
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -6_500)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-3", "补入（弱适配器）→ .assist 且 direct+edge=load")
    }

    // 场景 4：大补入（SP=29900, BP=−23000, isCharging=true）→ .assist，edge=−23.0，
    // direct=29.9，load=52.9（截图②形态——BP 幅值超过 SP 仍取 SP）。
    do {
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: -23_000)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -23.0, directEdgeW: 29.9, systemLoadW: 52.9),
                    "流向-4", "大补入 → .assist（directEdgeW 恒取 SP）")
    }

    // 场景 5：补入但 !isCharging（放电动作/适配器被禁）→ .assist（assist 不看策略位）。
    do {
        let model = makeModel(isCharging: false, systemPowerInMW: 29_900, batteryPowerMW: -6_500)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-5", "补入与策略位无关（!isCharging 仍 .assist）")
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
    // → .assist 幅值正确。
    do {
        let wrapped = Int(Int64(bitPattern: UInt64(bitPattern: Int64(-6_500))))
        expectEqual(wrapped, -6_500, "流向-16", "回绕还原自检：bitPattern 往返 = −6500")
        let model = makeModel(systemPowerInMW: 29_900, batteryPowerMW: wrapped)
        expectEqual(model, FlowDiagramModel(kind: .assist, batteryEdgeW: -6.5, directEdgeW: 29.9, systemLoadW: 36.4),
                    "流向-16", "回绕负值 BP → .assist 幅值正确")
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
}
