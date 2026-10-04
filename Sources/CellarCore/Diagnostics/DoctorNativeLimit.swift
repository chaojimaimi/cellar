import Foundation

// MARK: - 0.21.0 §1.3/§1.5 检查 19/20：MCL 残留检测（doctor 第 19/20 项；照
// DoctorOrchestration.swift 的 extension DoctorReportGenerator 先例拆分——
// DoctorReport.swift 行数纪律）
//
// 两项均 27 门控（MCL 读回仅在 set 路径语境有语义——26 上 Cellar 从不写 MCL，
// 读回值是系统自有状态，检测必属误报）。0.21.3 §1.3 登记**例外**：检查 20 的
// suppressed FAIL 臂抬退出码（现 info 恒不抬纪律的唯一例外——机制被系统设置
// 关闭是需要用户行动的真故障形态）。R3-P3-3：27 无 actionTrack——「非 fullOnce
// 在轨」条件恒真，**如实省略**，不为此造假轨道判定（0.21.3 §2.1 起 fullOnce
// 窗在位经 wire fullOnceWindowActive 显性化，检查 19 据此窗内零渲染）。

extension DoctorReportGenerator {
    /// 检查 19（§1.3）：fullOnce 临时放开残留——MCL 读回 100 ∧ policy < 100
    /// （判定源与面板恢复臂同式：NativeLimitSet.fullOnceRestoreAvailable，读回
    /// 驱动非轨道判定）→ INFO + 恢复指引。渲染条件：27 ∧ daemon 在线 ∧ 编排终态
    /// ∧ mode active ∧ 编排开关开（开关关时读回 100 属 §1.5 关断期望态——检查
    /// 20 承接，本项不双报）∧ MCL 读回在位 ∧ **fullOnce 窗不在位**（0.21.3 §2.1
    /// wire 供给——窗内读回 100 是显式放开意图非残留）。
    static func fullOnceResidual(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.mclProbeAttempted, inputs.osMajorVersion >= 27,
              let mcl = inputs.mclProbe, mcl.readable, let readback = mcl.limit,
              let status = inputs.daemonStatus,
              status.capabilities?.contains(DaemonXPC.capabilityOrchestration) == true,
              status.mode == "active",
              status.orchestration?.enabled == true
        else { return nil }
        // 0.21.3 §2.1：窗在位（daemon wire）→ 显式放开期，非残留——零渲染
        //（旧「若刚点击充满一次属预期形态」附注由显式窗态取代）。
        guard status.fullOnceWindowActive != true else { return nil }
        guard NativeLimitSet.fullOnceRestoreAvailable(
            mclReadback: readback, policyUpperLimit: status.upperLimit
        ) else { return nil }
        return DoctorCheck(
            name: "临时放开残留", status: .info,
            detail: "原生限充读回 100% 而策略上限 \(status.upperLimit)%——临时放开未恢复"
                + "。请在 Cellar 面板点击「恢复限充」，或调整上限/重开限充自动收敛"
        )
    }

    /// 检查 20（§1.5 + 0.21.3 重定版）：MCL 对账残留——期望值派生
    ///（NativeLimitSet.shutdownExpectation **八行表**：两窗/mode 关恒 100 /
    /// 编排开 ≥80 → target / 编排开 <80 非 degraded → 100 ∧ degraded → 80 /
    /// 编排关 degraded → 80 ∧ 非 degraded → 100——旧「编排关 ∧ <80 → 80 兜底」
    /// 行 G1 实证有害〔MCL 80 主导顶掉域 75〕废除；输入增 degraded + 两窗，
    /// daemon wire 供给），读回 ≠ 期望 → INFO + 三分支教育指引（G1 修正：不再
    /// 引导「按需关闭/set 80」——系统设置设具体值或交给 Cellar，绝不用 100%
    /// 作「关闭」）。
    /// **suppressed/残留双态合取（§1.3，R2-P3-3）**：daemon wire
    /// sub80MechanismSuppressed == true → **FAIL 优先**（抬退出码——「info 恒
    /// 不抬」纪律的登记例外；UI-100 机制关闭需用户行动）；无 suppressed 才评
    /// 残留 INFO。读回缺席（探测失败/类缺席）→ 不渲染（读通道死态无对账可言
    /// ——诚实缺席）。
    static func shutdownResidual(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.mclProbeAttempted, inputs.osMajorVersion >= 27,
              let status = inputs.daemonStatus
        else { return nil }
        // 双态合取第一态：suppressed 优先 FAIL（§1.3——同名指引与 App 通用页
        // 警示行一致；锁存解除〔域读回一致〕随 wire 回 false 自然回落）。
        // **挪至 mcl.readable 门之前（review P3）**：suppressed 是 daemon 域侧
        // 证据（wire 透出），不应被 MCL 探测可用性门控——MCL 类缺席/读取失败
        // 的边角形态不应压掉 FAIL 臂。
        if status.sub80MechanismSuppressed == true {
            return DoctorCheck(
                name: "关断残留", status: .fail,
                detail: "系统设置充电上限 100% 已关闭原生限充机制（Cellar 正在自动恢复；"
                    + "若反复出现请在系统设置设一个具体上限（如 80%）——切勿用 100% 作"
                    + "「关闭」，那是机制关闭位；停用限充请用 Cellar 的停用按钮）"
            )
        }
        guard let mcl = inputs.mclProbe, mcl.readable, let readback = mcl.limit else {
            return nil
        }
        guard let expected = NativeLimitSet.shutdownExpectation(
            modeActive: status.mode == "active",
            orchestrationEnabled: status.orchestration?.enabled == true,
            upperLimit: status.upperLimit,
            degraded: status.sub80State == .degraded,
            fullOnceWindowActive: status.fullOnceWindowActive == true,
            chargingDisabledWindowActive: status.chargingDisabledWindowActive == true
        ) else { return nil }
        if readback == expected {
            return DoctorCheck(
                name: "关断残留", status: .pass,
                detail: "MCL 对账一致（读回 \(readback)%，期望 \(expected)%）"
                    + stallBehaviorHeuristicNote(snapshot: inputs.snapshot, status: status)
            )
        }
        // 0.22.4 静默态附注（方案 §3.4 复核 P3：域承载态/探针窗域值 target ≠
        // 期望 80/100 会呈现失配，但 App 补偿臂在该态不对账属预期——与 App 对账
        // 臂同一纯函数判定，单一真相）。status 仍为 INFO 不改（失配事实如实呈现，
        // 文案补「属预期」口径防误导）。
        let silenced = NativeLimitSet.compensationSilenced(
            modeActive: status.mode == "active",
            fullOnceWindow: status.fullOnceWindowActive == true,
            chargingDisabledWindow: status.chargingDisabledWindowActive == true,
            healProbeActive: status.sub80HealProbeActive == true,
            sub80State: status.sub80State,
            upperLimit: status.upperLimit,
            orchestrationEnabled: status.orchestration?.enabled == true
        )
        return DoctorCheck(
            name: "关断残留", status: .info,
            detail: "MCL 读回 \(readback)% 与期望值 \(expected)% 不符（"
                + (silenced
                    ? "当前为域承载态/自愈探针期——App 不对账属预期（域写值直接执法，勿干预）"
                    : "App 缺席窗残留——打开 Cellar App 将自动对账补偿")
                + "）。提示：在系统设置手动调整时"
                + "请设一个具体上限（如 80%）或交给 Cellar 管理——切勿设 100% 来"
                + "「关闭」限充（那是机制关闭位；停用请用 Cellar 的停用按钮）"
                + stallBehaviorHeuristicNote(snapshot: inputs.snapshot, status: status)
        )
    }

    /// 0.22.3 §4 行为启发附注（纯函数；0.22.3 收敛判据——「恢复完成」= 域读回持续
    /// 一致 **∧ 充电行为跟随目标**，域读回单眼会漏掉 10:19 形态：域文件看着对但
    /// 机制已死——死寂态无违规拍〔不充电〕、域读回一致，只能由行为显性化）。
    ///
    /// - **数据源（评审 P0）**：`inputs.snapshot`（检查 5 电池读数，doctor 侧直读
    ///   ——零 wire 变化。**勿用 wire `lastChargingEnabled`**：那是 SMC 充电许可
    ///   控制键非电池充电态，死寂态满电停充时恒 true，主场景永不触发）；
    /// - 触发：`isCharging == false ∧ externalConnected == true ∧ percent ≥
    ///   upperLimit + 3` ∧ 排除三类合法态（评审 P1-2）：两窗在位（fullOnce /
    ///   chargingDisabled——窗内充到 100 是显式放开意图）∧ 降级 80 驻留（上限 ≤77
    ///   时 +3 命中）∧ CHIE 迟滞带挂载（hysteresis 值域 1-20，驻留 target+hys 可达 +3）；
    /// - **附注行不改检查 status/退出码**（「若持续 ≥30 min」是启发声非硬判——
    ///   单次 doctor 运行无法确证持续性，warn 会误伤脚本化退出码契约）；触发面落
    ///   shutdownResidual 检查内自动继承其 27 ∧ daemon 在线门（26 红线由此保证）；
    ///   与 suppressed FAIL 臂共存：FAIL（锁存在位）优先展示，本附注为无锁存时的
    ///   行为启发面。
    static func stallBehaviorHeuristicNote(
        snapshot: BatterySnapshot?, status: DaemonStatus
    ) -> String {
        guard let snapshot,
              snapshot.isCharging == false,
              snapshot.externalConnected == true,
              snapshot.percent >= status.upperLimit + 3,
              status.fullOnceWindowActive != true,
              status.chargingDisabledWindowActive != true,
              status.sub80State != .degraded,
              status.sub80Hysteresis != true
        else { return "" }
        return "；行为启发：电量 \(snapshot.percent)% 高于上限 \(status.upperLimit)%"
            + " 且未在回落——若持续 ≥30 min，充电机制可能被系统关闭（通用页横幅/FAQ Q16）"
    }
}
