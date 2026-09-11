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

/// 上一帧采样三元组（v0.19.5 §D1/§D3——双槽时序的前态载体）。
///
/// WHY（恒等式论据，方案 §1.3）：遥测字典内恒等式 `SP = SL + BP` 在所有样本中
/// 精确成立 → 字典是单代相干样本 → 刷新后的 BP 必然反映刷新时刻的真实充放状态。
/// App 1s 采样读到的是同一代字典的重复拷贝，与上一帧快照做**值相等比对**即可
/// 检测代际更替（SP 或 BP 任一变化 = 换代）；「上一帧」语义由 App 宿主双槽
/// 时序承载（§D3：每帧先用旧前态判定本帧，再把本帧三元组写回），本结构体自身
/// 只是无状态数据载体。
public struct FlowDiagramPreviousSample: Equatable, Sendable {
    public let systemPowerInMW: Int?
    public let batteryPowerMW: Int?
    /// 上一帧判定出的形态（assist 锁存的锁存态来源；nil = 上一帧未判/回退前）。
    public let kind: FlowDiagramKind?

    public init(systemPowerInMW: Int?, batteryPowerMW: Int?, kind: FlowDiagramKind?) {
        self.systemPowerInMW = systemPowerInMW
        self.batteryPowerMW = batteryPowerMW
        self.kind = kind
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
///     ③ externalConnected && 遥测齐全（v0.19.5 §D1 修订——assist 代际确认门）
///        bpW = BP/1000;  loadW = spW − bpW;  load = loadW >= 0 ? loadW : nil
///        generationChanged = previous != nil && (SP != prev.SP || BP != prev.BP)
///        bpNegative        = BP < −50 mW
///        assistConfirmed   = bpNegative && (prev.kind == .assist        // 锁存维持
///            || (generationChanged && prev.BP != nil && prev.BP < −50)) // 换代进入
///
///        六组合（按判定顺序，互斥穷举有归宿）：
///        - assistConfirmed                        → .assist, batteryEdgeW = bpW(负),
///          directEdgeW = spW, systemLoadW = load
///          （assist 的 directEdgeW = SP：该边真实流量 = min(SP, 负载)，补入态
///          负载 = SP + |BP| > SP → 取 SP。于是 直供边 + 电池边 = 系统节点）
///        - isCharging && BP > +50 mW              → .charging, batteryEdgeW = bpW(正),
///          directEdgeW = load, systemLoadW = load
///          （charging 要求 isCharging——徽章与图形一致；仅 assist 一处**故意**
///          分叉。已知副作用：isCharging=true && |BP| ≤ ε 时徽章「充电中」而
///          图形 holding，验收列为已知形态）
///        - BP < −50 mW 且未确认（**不分支 isCharging**——冲突未确认窗口：
///          isCharging（1s 策略态）先翻转、BP（~30s 节流遥测）滞后一个字典代际的
///          充电起步瞬态，充电侧与停充侧死角同构，方案 §1.2 事故定因）
///                                          → kind 按 isCharging 映射
///          （true→.charging / false→.holding），但 batteryEdgeW = nil、
///          systemLoadW = nil、directEdgeW = spW
///          （方向词/徽章按最新策略态，数字置 nil 不造数；直供边照显。
///          停充侧若兜底旧 holding（load=SP−BP）会复现事故现场的负载虚高
///          64+25.3=89.3，故显式 nil）
///        - !isCharging && BP > +50 mW（停充尾态） → .holding, batteryEdgeW = nil,
///          directEdgeW = spW, systemLoadW = load
///        - |BP| ≤ 50 mW（含 ±50 边界，**不进**未确认窗口）→ .holding 同上行
///
///        WHY 判定顺序：assistConfirmed 最先（锁存维持要求稳态字典不动
///        （未换代）也保持 assist——原始 bug 场景（持久补差）不被回退；退出 =
///        BP ≥ −ε 或 !ext）；`|BP| ≤ ε` 的边界帧两条比较（> +50 与 < −50）均
///        不命中，自然落到末行 holding return，维持「边界 ==50 落 holding」
///        的既有归属。
///
///        WHY 双槽时序依赖（「上一帧」语义）：previous 必须是**上一帧**的三元组，
///        不能传本帧当前态——否则 generationChanged 恒 false、确认门/锁存整体
///        失效（§D3 契约：先判定后写回，宿主 StatusController 双槽承载）。
///        保守方向：previous == nil（首帧/断代后首帧）一律未确认——启动于过渡中
///        时宁显无数字，不显可能陈旧的 assist（进入代价 ≤ 一个字典代际 ~30s）。
///        值相等假阴性（SP、BP 恰同值两代）→ 晚一代确认，自愈无害。
///
/// ε = 50 mW：与既有 `abs(batteryPowerW) >= 0.05` 同值；边界 |BP| == 50 落 holding。
public func flowDiagramModel(
    externalConnected: Bool,
    isCharging: Bool,
    systemPowerInMW: Int?,
    batteryPowerMW: Int?,
    batteryVoltageMV: Int,
    batteryAmperageMA: Int,
    previous: FlowDiagramPreviousSample? = nil
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

    // ③ 遥测齐全 → 实测符号裁决 + 代际确认门（v0.19.5 §D1；Int mW 精确比较，
    // 边界 |BP| == 50 落 holding——±50 不进未确认窗口）。
    let bpW = Double(batteryPowerMW) / 1000
    let loadW = spW - bpW
    let load: Double? = loadW >= 0 ? loadW : nil

    // 代际确认门：assist 需「连续两帧 BP<−ε 且确认换代」进入，或锁存维持。
    let bpNegative = batteryPowerMW < -flowDiagramZeroFlowEpsilonMW
    let generationChanged: Bool
    if let previous {
        generationChanged = systemPowerInMW != previous.systemPowerInMW
            || batteryPowerMW != previous.batteryPowerMW
    } else {
        generationChanged = false
    }
    let assistConfirmed = bpNegative
        && (previous?.kind == .assist
            || (generationChanged
                && previous?.batteryPowerMW != nil
                && previous!.batteryPowerMW! < -flowDiagramZeroFlowEpsilonMW))

    if assistConfirmed {
        // 已确认补入：直供边取 SP（min(SP, 负载)，补入态负载恒 > SP）。
        return FlowDiagramModel(kind: .assist, batteryEdgeW: bpW, directEdgeW: spW, systemLoadW: load)
    }
    if isCharging && batteryPowerMW > flowDiagramZeroFlowEpsilonMW {
        // 实际受电：直供边 = 负载（min(SP, 负载) = 负载，与 assist 同一规则解释）。
        return FlowDiagramModel(kind: .charging, batteryEdgeW: bpW, directEdgeW: load, systemLoadW: load)
    }
    if bpNegative {
        // 未确认窗口（不分支 isCharging）：kind 跟随 1s 新鲜的 isCharging，
        // 数字置 nil 不造数、直供边照显（§D1 语义要点 1/2——方向永不因陈旧
        // 数据反转，停充侧死角不落 load=SP+|BP| 虚高形态）。
        return FlowDiagramModel(
            kind: isCharging ? .charging : .holding,
            batteryEdgeW: nil, directEdgeW: spW, systemLoadW: nil)
    }
    return FlowDiagramModel(kind: .holding, batteryEdgeW: nil, directEdgeW: spW, systemLoadW: load)
}

/// 快照 → 流向显示模型便捷投影（0.19.4 §1.1——flowDiagramModel 的 BatterySnapshot
/// 入口；面板/状态行/徽章共用，防各消费点重写六参调用；消费方按需取 .kind /
/// .batteryEdgeW）。全模型变体定版（R2 P2-③）：PanelView 同点需取 batteryEdgeW，
/// 只返 kind 会留六参重写的缝。v0.19.5 §D2：透传 `previous` 前态（默认 nil 零
/// 回归——需代际确认的组装点显式传参）。
public func flowModel(of snapshot: BatterySnapshot, previous: FlowDiagramPreviousSample? = nil) -> FlowDiagramModel {
    flowDiagramModel(
        externalConnected: snapshot.externalConnected,
        isCharging: snapshot.isCharging,
        systemPowerInMW: snapshot.telemetry?.systemPowerInMW,
        batteryPowerMW: snapshot.telemetry?.batteryPowerMW,
        batteryVoltageMV: snapshot.voltageMV,
        batteryAmperageMA: snapshot.amperageMA,
        previous: previous
    )
}
