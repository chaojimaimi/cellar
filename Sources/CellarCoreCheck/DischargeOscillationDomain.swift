// CellarCoreCheck —— 放电振荡批收敛面场景域（0.23.0 退役版；原 0.21.1 振荡根治域）
//
// **0.23.0 自动放电自动机退役（方案 §2/§8 F4 账）**：振荡/熔断状态机与
// autoTriggerReady 三门矩阵场景族（原振荡-1..9、乒乓-3）随生产代码删除；
// 域内非退役面保留：
// ① 乒乓循环回归断链第一环（Topoff.convergenceRoute——编排关域承载 + 断言静默，
//    修后断链形态持续钉面）；
// ② 行为矩阵六行 × 边界 79/80/81（convergenceRoute + setTarget 映射退役钉面）；
// ③ wire：sub80WrittenLimit / autoDischargeSuspended（旧 JSON 缺席 + round-trip；
//    autoDischargeSuspended 恒 false——wire 字段保留零变化）。
// 原 :177/:267 的 NativeLimitSet.shutdownExpectation（W4 行）断言**迁移
// NativeLimitSetDomain**（set-8/set-9 翻新基底不灭——0.23.0 §④ 行 6/7 翻新同源）。
//
// 全部纯函数面（无 IO、不起 daemon）；daemon 侧接线为 executable internal——以代码
// 走查 + 真机验收兜底。

import CellarCore
import Foundation

/// 放电振荡批收敛面场景域入口（Main.main 调用）。
func runDischargeOscillationDomainScenarios() throws {

    // ---- ① 乒乓循环回归断链第一环（真机事件 target=80 编排关——方案 §0.1/§0.4）----
    // 修前形态（已入档定谳）：编排关 ∧ target 80 → 汇聚点守卫清理域 100 + off →
    // agent 跟域 100 持续充电 → 过冲 82 → 自动放电循环自持。修后断链钉面（原第二/
    // 三环——W4 期望 100 与门 a/熔断——随 0.23.0 自动机退役收敛：W4 断言迁
    // NativeLimitSetDomain 行 8，自动放电臂整体不存在 = 第三环结构性断链）：

    // 乒乓-1：断链第一环——域随写 target（编排关 ∧ target 80 → 汇聚目标 80 非 100、
    // 非清理、**0.21.3 §1.1 起域承载执法（owned 扩展）**、编排静默）。乒乓形态不
    // 复活的论证：owned 的 strike 链只重写域值（80 与卫生分支同值）；0.23.0 起自动
    // 放电触发链已删除——循环发起体结构性消失。
    let incident = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
        upperLimit: 80, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(incident.convergenceTarget == 80, "乒乓-1",
          "编排关 ∧ target 80 → 汇聚目标 80（域随写 80——域恢复滞回根治面；修前清理域 100 已废除）")
    check(incident.orchestrationDesired == nil, "乒乓-1",
          "编排关 → 编排静默（开关仅门控 App set 执行通道——域通道不受门，架构自述不变量对齐）")
    check(incident.topoffOwned, "乒乓-1",
          "target 80 ∧ 编排关 → **0.21.3 §1.1 owned 扩展**（域承载全区间执法——violation/strike 链只重写域 80；0.23.0 起自动放电臂已退役，循环断链保持）")

    // ---- ② 行为矩阵六行 × 边界 79/80/81（方案 §2.3 全形态）----

    func route(_ orchestrationEnabled: Bool, _ upperLimit: Int)
        -> (convergenceTarget: Int?, orchestrationDesired: Int?, topoffOwned: Bool) {
        Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: orchestrationEnabled,
            chargingDisabledWindow: false, upperLimit: upperLimit,
            sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false
        )
    }

    // 矩阵-1：行 1/2（target <80 ∧ 编排开/关）——topoff 承载、编排静默（开关独立性）；
    // 边界 79 承载 / 80 不承载（<80 判据边界）。
    check(route(true, 79).topoffOwned && route(true, 79).convergenceTarget == 79
              && route(true, 79).orchestrationDesired == nil,
          "矩阵-1", "target 79 ∧ 编排开 → topoff 承载 79、编排静默（<80 域执法——App set 拒 <80 不参与）")
    check(route(false, 79).topoffOwned && route(false, 79).convergenceTarget == 79
              && route(false, 79).orchestrationDesired == nil,
          "矩阵-1", "target 79 ∧ 编排关 → 同行 1（topoff 不受编排开关门——域随写语义一致化对称面）")
    check(NativeLimitSet.setTarget(for: 79) == nil, "矩阵-1",
          "target 79 恢复臂不写 MCL（0.22.4 §3.2 映射退役：<80 → nil——执行体永不向原生 MCL 写 <80 值，也不再写 100 补值〔13:32 互搏元凶链〕；域写值直接执法）")

    // 矩阵-2：行 3/4（target ≥80 ∧ 编排开/关）——域随写 target、编排开断言 target、
    // 编排关静默；边界 80/81 双侧。
    check(route(true, 80).convergenceTarget == 80 && !route(true, 80).topoffOwned
              && route(true, 80).orchestrationDesired == 80,
          "矩阵-2", "target 80（边界）∧ 编排开 → 域随写 80 + 断言 80（0.21.1 改后域=target）")
    check(route(true, 81).convergenceTarget == 81 && route(true, 81).orchestrationDesired == 81,
          "矩阵-2", "target 81 ∧ 编排开 → 域随写 81 + 断言 81（≥80 全区间随写）")
    check(route(false, 80).convergenceTarget == 80 && route(false, 80).orchestrationDesired == nil,
          "矩阵-2", "target 80 ∧ 编排关 → 域随写 80 + 编排静默（乒乓断链第一环——矩阵行 4）")
    check(route(false, 81).convergenceTarget == 81 && route(false, 81).orchestrationDesired == nil,
          "矩阵-2", "target 81 ∧ 编排关 → 域随写 81（域故障时 MCL 80 兜底——行 2 同构；0.23.0 起无自动放电熔断面）")

    // 矩阵-3：行 5（fullOnce/日程窗）——域 100、断言 100、topoff 失效（完全放开；
    // 原窗内自动放电静默钉面随触发链退役收敛为「无触发链」）。
    let windowRow = Topoff.convergenceRoute(
        modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: true,
        upperLimit: 80, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(windowRow.convergenceTarget == 100 && windowRow.orchestrationDesired == 100
              && !windowRow.topoffOwned,
          "矩阵-3", "chargingDisabled 日程窗 → 域 100 + 断言 100 + topoff 失效（完全放开）")

    // 矩阵-4：行 6（mode 关真停用）——汇聚 nil、断言 nil（原 shutdownExpectation
    // 断言已迁 NativeLimitSetDomain set-7——W4 行 3）。
    let offRow = Topoff.convergenceRoute(
        modeActive: false, orchestrationEnabled: true, chargingDisabledWindow: false,
        upperLimit: 80, sub80Capable: true, actionActive: false,
        degraded: false, healProbeActive: false
    )
    check(offRow.convergenceTarget == nil && offRow.orchestrationDesired == nil
              && !offRow.topoffOwned,
          "矩阵-4", "mode 关 → 汇聚 nil + 断言 nil + topoff 失效（真停用——off 语义收紧后唯一 off 源）")

    // ---- ③ wire（sub80WrittenLimit / autoDischargeSuspended——字段保留零变化）----

    // 线-1：旧 JSON（无新键）→ 双 nil（decodeIfPresent 兼容——旧 daemon 回包天然解码）。
    do {
        let oldJSON = """
        {"version":"0.21.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":2000000}
        """
        let old = try JSONDecoder().decode(DaemonStatus.self, from: Data(oldJSON.utf8))
        check(old.sub80WrittenLimit == nil && old.autoDischargeSuspended == nil, "线-1",
              "旧 daemon 回包（无 sub80WrittenLimit/autoDischargeSuspended 键）→ 双 nil（向后兼容）")
    }

    // 线-2：round-trip 保留 + init 缺省 nil（既有夹具形态不破坏）。0.23.0 起新
    // daemon autoDischargeSuspended 恒 false（振荡熔断退役——wire 字段保留）。
    do {
        var status = DaemonStatus(version: "fixture", mode: "active", upperLimit: 80, hysteresis: 2)
        check(status.sub80WrittenLimit == nil && status.autoDischargeSuspended == nil, "线-2",
              "init 缺省双 nil（既有构造点零 diff）")
        status.sub80WrittenLimit = 80
        status.autoDischargeSuspended = true
        let revived = try JSONDecoder().decode(
            DaemonStatus.self, from: JSONEncoder().encode(status)
        )
        check(revived.sub80WrittenLimit == 80 && revived.autoDischargeSuspended == true, "线-2",
              "round-trip 保留域生效值与抑制态（App 读回失配提示 + 横幅数据源——wire 解码面兼容保留）")
    }
}
