// MARK: - 功率流向显示模型（v0.19.3 §D2——单一真相规则 D1 的纯函数落点）
//
// 落点：`Daemon/`（AppSide.swift 同族 App 侧纯函数）而非 `Monitor/`——
// Tools/coverage.sh 的门禁文件集排除 Monitor/，放错目录即逃逸覆盖率门禁。
//
// 单一真相规则（D1）：外接态的功率数字（适配器贡献、电池侧、系统负载）一律
// 取自同一遥测快照 → 三边恒守恒（构造恒等）；遥测缺席回退现状 `V×I` + 策略位。
// 电池供电态维持 `V×I`（App 侧 1s 采样新鲜度更优，无跨源矛盾）。

/// 功率流向形态：外接态由**实测功率符号**裁决（v0.19.3），不再由 isCharging 策略位派生。
public enum FlowDiagramKind: Equatable, Sendable {
    /// 外接 + 电池实际受电（BP > +ε）
    case charging
    /// 外接 + 电池零流（|BP| ≤ ε）
    case holding
    /// 外接 + 电池实际放电补差（BP < −ε）
    case assist
    /// 电池供电（!ext）
    case battery
}

/// 功率流向显示模型（App 层组装的唯一判据来源）。
public struct FlowDiagramModel: Equatable, Sendable {
    public let kind: FlowDiagramKind
    /// 电池边功率 W（带符号：受电 + / 放电 −）。holding / 幅值低于显示阈值 → nil。
    public let batteryEdgeW: Double?
    /// 直供边（适配器→系统）功率 W = 适配器对系统的实际贡献。
    public let directEdgeW: Double?
    /// 系统节点功率 W = 总负载。
    public let systemLoadW: Double?

    public init(kind: FlowDiagramKind, batteryEdgeW: Double?, directEdgeW: Double?, systemLoadW: Double?) {
        self.kind = kind
        self.batteryEdgeW = batteryEdgeW
        self.directEdgeW = directEdgeW
        self.systemLoadW = systemLoadW
    }
}

/// 零流阈值：|BP| ≤ 50 mW 视为零流（与既有标签显示阈值 0.05W 同值）。
public let flowDiagramZeroFlowEpsilonMW = 50

/// 电池边显示阈值：|V×I| < 0.05 W → batteryEdgeW = nil（**不得产出「−0.0 W」**，
/// 沿用既有 `abs(batteryPowerW) >= 0.05` 标签 guard 纪律，R1 P1-2）。
public let flowDiagramEdgeDisplayThresholdW = 0.05

/// 功率流向判定（判定表，实现与方案 §D2 逐字对齐；`BP`/`SP` 单位 mW）：
///
///     viW  = voltageMV × amperageMA / 1e6
///     viEdge = |viW| >= 0.05 ? |viW| : nil          // 显示阈值（P1-2）
///     spW  = systemPowerInMW.map { Double($0)/1000 }
///
///     ① !externalConnected
///        → .battery, batteryEdgeW = viEdge, directEdgeW = nil, systemLoadW = |viW|
///        （系统节点无阈值——现状）
///
///     ② externalConnected && (systemPowerInMW == nil || batteryPowerMW == nil)
///        → isCharging ? (.charging, batteryEdgeW = viEdge, directEdgeW = nil,
///                        systemLoadW = nil)
///                     : (.holding,  batteryEdgeW = nil, directEdgeW = spW,
///                        systemLoadW = nil)
///        （holding 的 directEdgeW 取 spW——仅需 SP 在场，supplyLineText 的
///        holding 分支 R1 P2-1；charging 的 direct 保持 nil——旧
///        derivedSystemLoadW 需 SP+BP 双在场）
///
///     ③ externalConnected && 遥测齐全
///        bpW = BP/1000;  loadW = spW − bpW;  load = loadW >= 0 ? loadW : nil
///        - BP < −50 mW → .assist,  batteryEdgeW = bpW(负), directEdgeW = spW,
///                        systemLoadW = load
///          （assist 的 directEdgeW = SP：该边真实流量 = min(SP, 负载)，补入态
///          负载 = SP + |BP| > SP → 取 SP。于是 直供边 + 电池边 = 系统节点）
///        - isCharging && BP > +50 mW → .charging, batteryEdgeW = bpW(正),
///          directEdgeW = load, systemLoadW = load
///          （charging 要求 isCharging——徽章与图形一致；仅 assist 一处**故意**
///          分叉。已知副作用：isCharging=true && |BP| ≤ ε 时徽章「充电中」而
///          图形 holding，验收列为已知形态）
///        - 其余（含 !isCharging && BP>0 的停充尾态）→ .holding, batteryEdgeW = nil,
///          directEdgeW = spW, systemLoadW = load
///
/// ε = 50 mW：与既有 `abs(batteryPowerW) >= 0.05` 同值；边界 |BP| == 50 落 holding。
public func flowDiagramModel(
    externalConnected: Bool,
    isCharging: Bool,
    systemPowerInMW: Int?,
    batteryPowerMW: Int?,
    batteryVoltageMV: Int,
    batteryAmperageMA: Int
) -> FlowDiagramModel {
    let viW = Double(batteryVoltageMV) * Double(batteryAmperageMA) / 1_000_000
    let viEdge: Double? = abs(viW) >= flowDiagramEdgeDisplayThresholdW ? abs(viW) : nil
    let spW = systemPowerInMW.map { Double($0) / 1000 }

    // ① 电池供电：边有 0.05 显示阈值、系统节点无阈值（现状口径）。
    guard externalConnected else {
        return FlowDiagramModel(kind: .battery, batteryEdgeW: viEdge, directEdgeW: nil, systemLoadW: abs(viW))
    }

    // ② 遥测缺席 → 回退现状（isCharging 分层；负值/缺席一律不造数）。
    guard let spW, let batteryPowerMW else {
        return isCharging
            ? FlowDiagramModel(kind: .charging, batteryEdgeW: viEdge, directEdgeW: nil, systemLoadW: nil)
            : FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: spW, systemLoadW: nil)
    }

    // ③ 遥测齐全 → 实测符号裁决（Int mW 精确比较，边界 |BP| == 50 落 holding）。
    let bpW = Double(batteryPowerMW) / 1000
    let loadW = spW - bpW
    let load: Double? = loadW >= 0 ? loadW : nil
    if batteryPowerMW < -flowDiagramZeroFlowEpsilonMW {
        // 电池放电补差：直供边取 SP（min(SP, 负载)，补入态负载恒 > SP）。
        return FlowDiagramModel(kind: .assist, batteryEdgeW: bpW, directEdgeW: spW, systemLoadW: load)
    }
    if isCharging && batteryPowerMW > flowDiagramZeroFlowEpsilonMW {
        // 实际受电：直供边 = 负载（min(SP, 负载) = 负载，与 assist 同一规则解释）。
        return FlowDiagramModel(kind: .charging, batteryEdgeW: bpW, directEdgeW: load, systemLoadW: load)
    }
    return FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: spW, systemLoadW: load)
}
