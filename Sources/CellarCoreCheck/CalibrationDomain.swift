// CellarCoreCheck —— WP3 校准（手动触发版）场景域（方案 §4.1 十二项）
//
// 按域拆独立文件（main.swift 不再增长）。与 main.swift / 其他场景域共用
// FailureCounter 与断言助手。
//
// 覆盖清单（方案 §4.1 十二项；⑫ 为 0.23.6 B1-1 增补）：
// ① 启动前置矩阵（mode/external/actionActive/capability 逐条件 + 全过 + 原文可读）
// ② chargeFull 相：充满判定复用（主判据/≥99 降级/2 tick 去抖/中断归零）、
//    ext=false → abort(unplug)、相位超时 → abort(timeout)、stay
// ③ hold 相：holdDuration 边界（-1s stay / 恰好 advance）、ext=false abort、兜底超时
// ④ discharge 相：percent ≤10 → restoreAndComplete（10/11 边界）、温度 39.99 stay /
//    40.0 abort(safety)、CHIE 保活三态（held/rewritten/failed 计数 ≥3 abort）、
//    相位超时 abort、完成成立压住相位超时
// ⑤ 监护缺失门控扩展：两轨道方法（Discharge.swift noteMonitoringLoss/
//    terminateMonitoringLoss）对 calibration∧discharge 计数/终止、对 chargeFull/
//    hold 不触发；safety 字面量按 kind 构造（calibration:safety）。
//    ⚠️ 外层 guard（DaemonCore+Discharge.swift noteDischargeMonitoringLossLocked）
//    不在本工具覆盖内——cellar-daemon 目标不可 import，归 code-reviewer 走查必查项
//    （方案 §4.1.5 分层声明）。
// ⑥ Codable 兼容：旧 JSON（无 phase/phaseStartedAt）→ nil；round-trip；
//    knownKinds 含 calibration（load() 接受 + 未知 kind 仍拒绝）
// ⑦ 字面量家族：8 个 calibration 字面量格式钉死；钉「无 calibration:start」
// ⑧ 通知矩阵：相位转移/终态/首样本/limitReached 前缀豁免/既有回归
// ⑨ AppSide 助手：isCalibrationAction/calibrationPhase 正/反/未知串/nil
// ⑩ 交互与拒绝：autoTriggerReady 在校准在轨下 false；常量独立演化断言；occupied
//    拒绝枚举格式与触发条件钉死（R1 P1-3）
// ⑪ StatusFailureKind 映射钉死（R2 P2-3）：safety/timeout/crash → .actionInterrupted；
//    done/cancel 不入失败通道；既有 fullOnce/discharge 映射不回归
// ⑫ 终态观察空闲臂判定（0.23.6 B1-1）：calibrationIdleOutcomeObservation 单一谓词源
//    （26 执法段空闲臂 / 27 观测段镜像臂共用）——在轨/无锁存双挡门、五终态字面量
//    全映射、非校准字面量 nil（calibrationOutcomeLiteral 全映射已由调度域钉死）
// ⑬ hold→discharge 推进失败收口（0.23.10 B4-1）：推进失败三态（0/1/2 → advance /
//    ≥3 → abort(advanceExhausted, safety:false)——advance 判定短路 deadline 兜底的
//    唯一可达收口）、stay 分支计数透传、discharge 相 keepAliveFailures 独立性、
//    生命周期钉值（取消/崩溃恢复 → 重启校准 → advanceFailures == 0——track 层
//    MainEntry 用例 100 形态直测）

import CellarCore
import Foundation

/// 校准场景域入口（Main.main 调用；Codable 兼容组含 JSON decode/encode）。
func runCalibrationDomainScenarios() throws {
    let t0 = Date(timeIntervalSince1970: 0)
    let kind = Calibration.kind
    let deadline = t0.addingTimeInterval(Calibration.totalDeadline)

    // tick 输入构造助手（daemon 组装形态镜像——相位/相位起始/去抖/保活计数全注入）。
    func calInput(
        phase: Calibration.Phase?,
        phaseStartedAt: Date?,
        now: Date,
        percent: Int,
        externalConnected: Bool = true,
        isCharging: Bool = false,
        fullyCharged: Bool? = false,
        temperatureC: Double = 30,
        deadline: Date = deadline,
        debounceTicks: Int = 0,
        keepAliveFailures: Int = 0,
        advanceFailures: Int = 0,
        chieStatus: DischargeKeepAliveStatus? = nil
    ) -> CalibrationTickInput {
        CalibrationTickInput(
            percent: percent, temperatureC: temperatureC, externalConnected: externalConnected,
            isCharging: isCharging, fullyCharged: fullyCharged, now: now, phase: phase,
            phaseStartedAt: phaseStartedAt, deadline: deadline, debounceTicks: debounceTicks,
            keepAliveFailures: keepAliveFailures, advanceFailures: advanceFailures,
            chieStatus: chieStatus
        )
    }

    // ---- ① 启动前置矩阵（方案 §4.1.1）----

    // 校准-1：mode 两侧 + 全过放行。
    check(calibrationStartPrecondition(
        mode: "disabled", externalConnected: true, actionActive: false, capabilityPresent: true
    ) == .modeNotActive, "校准-1", "mode=disabled → 拒绝（modeNotActive）")
    check(calibrationStartPrecondition(
        mode: "active", externalConnected: true, actionActive: false, capabilityPresent: true
    ) == nil, "校准-1", "active + 外接 + 无动作 + 能力在位 → 放行")

    // 校准-2：external 两侧（含未知——不无据启动）。
    check(calibrationStartPrecondition(
        mode: "active", externalConnected: false, actionActive: false, capabilityPresent: true
    ) == .noExternalPower, "校准-2", "未外接 → 拒绝（noExternalPower）")
    check(calibrationStartPrecondition(
        mode: "active", externalConnected: nil, actionActive: false, capabilityPresent: true
    ) == .noExternalPower, "校准-2", "外接未知（快照失败且无上次已知值）→ 拒绝（不无据启动）")

    // 校准-3：actionActive / capability 两侧。
    check(calibrationStartPrecondition(
        mode: "active", externalConnected: true, actionActive: true, capabilityPresent: true
    ) == .actionOccupied, "校准-3", "动作在轨 → 拒绝（actionOccupied——互斥双向，先完成/取消）")
    check(calibrationStartPrecondition(
        mode: "active", externalConnected: true, actionActive: false, capabilityPresent: false
    ) == .capabilityUnavailable, "校准-3", "能力缺席 → 拒绝（capabilityUnavailable——XPC 纵深防御）")

    // 校准-4：拒绝枚举格式与原文（R1 P1-3）。
    let occupied = CalibrationStartRejection.actionOccupied
    check(occupied.message.contains("其他动作进行中"), "校准-4", ".actionOccupied 原文为中文可读文案（App 如实上屏）")
    check(String(describing: occupied) == occupied.message, "校准-4", "description == message（XPC errorReply 原文透传）")
    check(CalibrationStartRejection.modeNotActive.message.contains("启用状态")
            && CalibrationStartRejection.noExternalPower.message.contains("外接电源"),
          "校准-4", "modeNotActive/noExternalPower 原文可读")

    // ---- ② chargeFull 相（方案 §4.1.2）----

    // 校准-5：充满判定复用 + 2 tick 去抖（fullyCharged 主判据）→ advance(hold)。
    let chargeStart = t0
    let c1 = calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(30),
        percent: 100, isCharging: false, fullyCharged: true
    ))
    check(c1.output == .stay(phase: .chargeFull) && c1.debounceTicks == 1, "校准-5",
          "连续 1 tick 满足（fullyCharged 主判据）→ stay（去抖 1/2）")
    let c2 = calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(60),
        percent: 100, isCharging: false, fullyCharged: true, debounceTicks: c1.debounceTicks
    ))
    check(c2.output == .advance(to: .hold) && c2.debounceTicks == 0, "校准-5",
          "连续 2 tick 满足 → advance(hold)（去抖计数归零）")

    // 校准-6：≥99 降级（FullyCharged 缺失 nil → percent ≥99 && !isCharging）。
    let d1 = calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(30),
        percent: 99, isCharging: false, fullyCharged: nil
    ))
    check(d1.output == .stay(phase: .chargeFull) && d1.debounceTicks == 1, "校准-6",
          "fullyCharged=nil + 99% → 降级判据成立（去抖 1/2）")
    let d2 = calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(60),
        percent: 99, isCharging: false, fullyCharged: nil, debounceTicks: d1.debounceTicks
    ))
    check(d2.output == .advance(to: .hold), "校准-6", "降级判据连续 2 tick → advance(hold)")

    // 校准-7：中断归零（满足后不满足 → 计数清零）。
    let r1 = calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(30),
        percent: 100, isCharging: false, fullyCharged: true
    ))
    let r2 = calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(60),
        percent: 99, isCharging: true, fullyCharged: nil, debounceTicks: r1.debounceTicks
    ))
    check(r2.output == .stay(phase: .chargeFull) && r2.debounceTicks == 0, "校准-7",
          "满足后中断（isCharging=true）→ 去抖归零（中断归零语义）")

    // 校准-8：ext=false → abort(unplug, safety: true)——充电相拔电中止。
    check(calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(60),
        percent: 50, externalConnected: false
    )).output == .abort(reason: CalibrationLiteral.AbortReason.unplug, safety: true),
    "校准-8", "chargeFull 相 ext=false → abort(unplugInChargePhase, safety:true)（lastAction=calibration:safety）")

    // 校准-9：相位超时（6h）→ abort(timeout, safety: false)。
    check(calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart,
        now: chargeStart.addingTimeInterval(Calibration.chargeFullTimeout + 1),
        percent: 50, isCharging: true, fullyCharged: false
    )).output == .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
    "校准-9", "相位超时（>6h 未充满）→ abort(timeout, safety:false)（lastAction=calibration:timeout）")

    // 校准-10：完成判定成立（含去抖未满）压住相位超时——长睡唤醒报推进而非 abort。
    check(calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart,
        now: chargeStart.addingTimeInterval(Calibration.chargeFullTimeout + 3600),
        percent: 100, isCharging: false, fullyCharged: true
    )).output == .stay(phase: .chargeFull) && calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart,
        now: chargeStart.addingTimeInterval(Calibration.chargeFullTimeout + 3600),
        percent: 100, isCharging: false, fullyCharged: true, debounceTicks: 1
    )).output == .advance(to: .hold),
    "校准-10", "完成成立（含去抖未满）不判相位超时——超时窗+充满 → stay/advance 而非 abort")

    // 校准-11：stay 常态（充电中 + 外接）。
    check(calibrationTick(calInput(
        phase: .chargeFull, phaseStartedAt: chargeStart, now: chargeStart.addingTimeInterval(60),
        percent: 45, isCharging: true, fullyCharged: false
    )).output == .stay(phase: .chargeFull), "校准-11", "chargeFull 常态（充电中/未满）→ stay")

    // ---- ③ hold 相（方案 §4.1.3）----

    // 校准-12：holdDuration 边界（-1s stay / 恰好 advance）。
    let holdStart = t0.addingTimeInterval(3600)
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: holdStart,
        now: holdStart.addingTimeInterval(Calibration.holdDuration - 1), percent: 100
    )).output == .stay(phase: .hold), "校准-12", "holdDuration -1s → stay（静置未满）")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: holdStart,
        now: holdStart.addingTimeInterval(Calibration.holdDuration), percent: 100
    )).output == .advance(to: .discharge), "校准-12", "holdDuration 恰好（2h）→ advance(discharge)")

    // 校准-13：hold 相 ext=false → abort(unplug, safety: true)。
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: holdStart, now: holdStart.addingTimeInterval(600),
        percent: 100, externalConnected: false
    )).output == .abort(reason: CalibrationLiteral.AbortReason.unplug, safety: true),
    "校准-13", "hold 相 ext=false → abort(unplugInChargePhase, safety:true)")

    // 校准-14：整体兜底超时（24h deadline）→ abort(timeout)——deadline 仅作 hold 相
    // 24h 整体兜底判据，相位决策不用（R3 P3-1）。次序钉死：推进判定成立（2h 静置
    // 已满）优先于兜底——正常时序下 hold 恒先于 24h 推进（holdStart ≤ start+6h），
    // 兜底臂只在 phaseStartedAt 缺失/异常时序可达（防御）。
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: holdStart,
        now: deadline.addingTimeInterval(1), percent: 100
    )).output == .advance(to: .discharge),
    "校准-14", "推进判定成立（2h 已满，now 已超 24h 兜底）→ advance 优先（次序：advance > 兜底 abort）")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: nil, now: deadline.addingTimeInterval(1), percent: 100
    )).output == .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
    "校准-14", "phaseStartedAt 缺失 + 超 24h 兜底 → abort(timeout)（兜底防御臂可达）")

    // 校准-15：hold stay 常态（静置中满电停充维持）。
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: holdStart, now: holdStart.addingTimeInterval(600), percent: 100
    )).output == .stay(phase: .hold), "校准-15", "hold 常态 → stay")

    // ---- ④ discharge 相（方案 §4.1.4）----

    // 校准-16：percent ≤ 10 → restoreAndComplete（10/11 边界）。
    let dischargeStart = t0.addingTimeInterval(3 * 3600)
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 11, temperatureC: 30, chieStatus: .held
    )).output == .stay(phase: .discharge), "校准-16", "percent=11（>10）→ stay（放电未达目标）")
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 10, temperatureC: 30, chieStatus: .held
    )).output == .restoreAndComplete, "校准-16", "percent=10（≤目标）→ restoreAndComplete")

    // 校准-17：温度 39.99 stay / 40.0 abort(temperature, safety)。
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, temperatureC: 39.99, chieStatus: .held
    )).output == .stay(phase: .discharge), "校准-17", "温度 39.99°C → stay（低于单点中止阈值）")
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, temperatureC: 40.0, chieStatus: .held
    )).output == .abort(reason: CalibrationLiteral.AbortReason.temperature, safety: true),
    "校准-17", "温度 40.0°C → abort(temperature, safety:true)（单点即触发）")

    // 校准-18：CHIE 保活 held/rewritten → stay + 失败计数清零（连续失败语义中断）。
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, keepAliveFailures: 2, chieStatus: .held
    )).output == .stay(phase: .discharge)
    && calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, keepAliveFailures: 2, chieStatus: .rewritten
    )).keepAliveFailures == 0, "校准-18", "held/rewritten → stay 且保活失败计数清零")

    // 校准-19：CHIE 保活 failed 递增计数，≥3 → abort(extRestoredExhausted, safety)。
    let f1 = calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, keepAliveFailures: 1, chieStatus: .failed
    ))
    check(f1.output == .stay(phase: .discharge) && f1.keepAliveFailures == 2, "校准-19",
          "failed 连续第 2 次 → stay（计数 2/3，未达上限）")
    let f2 = calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, keepAliveFailures: 2, chieStatus: .failed
    ))
    check(f2.output == .abort(reason: CalibrationLiteral.AbortReason.keepAliveExhausted, safety: true),
          "校准-19", "failed 连续第 3 次 → abort(extRestoredExhausted, safety:true)（外部恢复充电无法压制）")

    // 校准-20：相位超时（12h）→ abort(timeout)；完成成立压住相位超时。
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart,
        now: dischargeStart.addingTimeInterval(Calibration.dischargeTimeout + 1),
        percent: 50, chieStatus: .held
    )).output == .abort(reason: CalibrationLiteral.AbortReason.timeout, safety: false),
    "校准-20", "放电相相位超时（>12h）→ abort(timeout, safety:false)")
    check(calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart,
        now: dischargeStart.addingTimeInterval(Calibration.dischargeTimeout + 3600),
        percent: 10, chieStatus: .held
    )).output == .restoreAndComplete, "校准-20", "完成成立（percent≤10）压住相位超时 → restoreAndComplete")

    // ---- ⑤ 监护缺失门控扩展（方案 §4.1.5；两轨道方法；外层 guard 走查项）----

    // 校准-21：calibration ∧ discharge → 计数/终止（safety 字面量按 kind 构造）。
    do {
        var track = OneShotTrack()
        _ = track.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        track.setCalibrationPhase(.discharge, startedAt: t0)
        check(!track.noteMonitoringLoss() && !track.noteMonitoringLoss(),
              "校准-21", "校准放电相监护缺失 2 tick → 不终止（计数 2/3）")
        check(track.noteMonitoringLoss(), "校准-21", "连续第 3 tick → 触发终止信号")
        let literal = track.terminateMonitoringLoss()
        check(literal == OneShotLiteral.safety(kind: kind) && literal == "calibration:safety"
                && track.action == nil && track.latchedLiteral == literal,
              "校准-21", "terminateMonitoringLoss → calibration:safety 锁存 + 动作清空（按 kind 构造）")
    }

    // 校准-22：chargeFull/hold 不触发；dischargeToLimit 不回归。
    do {
        var chargeFull = OneShotTrack()
        _ = chargeFull.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        chargeFull.setCalibrationPhase(.chargeFull, startedAt: t0)
        check(!chargeFull.noteMonitoringLoss() && chargeFull.terminateMonitoringLoss() == nil,
              "校准-22", "校准 chargeFull 相监护缺失不计数不终止（门控扩展谓词只在放电相）")
        var hold = OneShotTrack()
        _ = hold.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        hold.setCalibrationPhase(.hold, startedAt: t0)
        check(!hold.noteMonitoringLoss() && hold.terminateMonitoringLoss() == nil,
              "校准-22", "校准 hold 相监护缺失不计数不终止")
        var discharge = OneShotTrack()
        _ = discharge.startIfIdle(now: t0, kind: Discharge.dischargeToLimitKind, targetPercent: 80, timeout: Discharge.dischargeTimeout)
        check(!discharge.noteMonitoringLoss() && !discharge.noteMonitoringLoss()
                && discharge.noteMonitoringLoss(),
              "校准-22", "回归：dischargeToLimit 监护缺失照常计数终止（既有语义不回归）")
    }

    // ---- ⑥ Codable 兼容（方案 §4.1.6）----

    // 校准-23：旧 JSON（无 phase/phaseStartedAt 键）→ nil；新 JSON round-trip。
    do {
        let legacyJSON = #"{"kind":"calibration","startedAt":0,"deadline":86400}"#
        let legacy = try JSONDecoder().decode(OneShotAction.self, from: Data(legacyJSON.utf8))
        check(legacy.kind == kind && legacy.phase == nil && legacy.phaseStartedAt == nil,
              "校准-23", "旧格式 calibration JSON（无 phase/phaseStartedAt）→ 解码成功且两字段 nil（向后兼容）")

        var current = OneShotAction(kind: kind, startedAt: t0, deadline: deadline)
        current.phase = Calibration.Phase.hold.rawValue
        current.phaseStartedAt = t0.addingTimeInterval(3600)
        let round = try JSONDecoder().decode(OneShotAction.self, from: JSONEncoder().encode(current))
        check(round.phase == "hold" && round.phaseStartedAt == t0.addingTimeInterval(3600),
              "校准-23", "新格式 round-trip 保留 phase/phaseStartedAt")
    }

    // 校准-24：ActionStore knownKinds 含 calibration（载入接受 + 未知 kind 仍拒绝）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-calibration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActionStore(url: directory.appendingPathComponent("action.json"))

        var action = OneShotAction(kind: kind, startedAt: t0, deadline: deadline)
        action.phase = Calibration.Phase.discharge.rawValue
        action.phaseStartedAt = t0
        try store.save(action)
        check(store.load()?.kind == kind && store.load()?.phase == Calibration.Phase.discharge.rawValue,
              "校准-24", "白名单：calibration 载入（kind/phase 全字段保留）")

        try JSONEncoder().encode(
            OneShotAction(kind: "batteryCal", startedAt: t0, deadline: deadline)
        ).write(to: store.url)
        check(store.load() == nil && store.fileExists,
              "校准-24", "未知 kind（batteryCal 不在白名单）→ treat-as-absent（既有语义不回归）")
    }

    // ---- ⑦ 字面量家族（方案 §4.1.7）----

    // 校准-25：8 个 calibration 字面量格式钉死 + 无 calibration:start。
    check(CalibrationLiteral.phase(.chargeFull) == "calibration:chargeFull"
            && CalibrationLiteral.phase(.hold) == "calibration:hold"
            && CalibrationLiteral.phase(.discharge) == "calibration:discharge",
          "校准-25", "相位字面量三值格式钉死（wire 格式永不本地化）")
    check(CalibrationLiteral.done() == "calibration:done"
            && CalibrationLiteral.cancel() == "calibration:cancel"
            && CalibrationLiteral.timeout() == "calibration:timeout"
            && CalibrationLiteral.safety() == "calibration:safety"
            && CalibrationLiteral.cancelCrashRecovery() == "calibration:cancel(crash-recovery)",
          "校准-25", "终态字面量五值格式钉死")
    check(CalibrationLiteral.phase(.chargeFull) != "calibration:start",
          "校准-25", "钉无 calibration:start——启动相即 chargeFull 持续字面量（R1 P2-2：sleepNow 跳过分支直写相位字面量）")

    // ---- ⑧ 通知矩阵（方案 §4.1.8）----

    func dStatus(_ lastAction: String?) -> DaemonStatus {
        DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 90,
            hysteresis: 2, lastAction: lastAction, lastPercent: 78,
            lastExternalConnected: true, lastChargingEnabled: false
        )
    }

    // 校准-26：chargeFull→hold 转移 → phaseChanged(.hold)；hold→discharge → phaseChanged(.discharge)。
    check(notificationEvents(
        previous: dStatus("calibration:chargeFull"), current: dStatus("calibration:hold")
    ) == [.calibrationPhaseChanged(phase: .hold)], "校准-26", "进入 calibration:hold → phaseChanged(.hold)")
    check(notificationEvents(
        previous: dStatus("calibration:chargeFull"), current: dStatus("calibration:discharge")
    ) == [.calibrationPhaseChanged(phase: .discharge)], "校准-26", "进入 calibration:discharge → phaseChanged(.discharge)")
    check(notificationEvents(
        previous: dStatus("calibration:hold"), current: dStatus("calibration:hold")
    ) == [], "校准-26", "相位字面量同值 → 无事件（转移守卫；持续态字面量不重复通知）")

    // 校准-27：done → completed；safety/timeout/crash-recovery → interrupted；cancel → []。
    check(notificationEvents(
        previous: dStatus("calibration:discharge"), current: dStatus("calibration:done")
    ) == [.calibrationCompleted], "校准-27", "calibration:done 转移 → calibrationCompleted")
    check(notificationEvents(
        previous: dStatus("calibration:chargeFull"), current: dStatus("calibration:safety")
    ) == [.calibrationInterrupted], "校准-27", "calibration:safety → calibrationInterrupted（中止）")
    check(notificationEvents(
        previous: dStatus("calibration:hold"), current: dStatus("calibration:timeout")
    ) == [.calibrationInterrupted], "校准-27", "calibration:timeout → calibrationInterrupted（timeout 折进 interrupted 语义）")
    check(notificationEvents(
        previous: dStatus("calibration:hold"), current: dStatus("calibration:cancel(crash-recovery)")
    ) == [.calibrationInterrupted], "校准-27", "calibration:cancel(crash-recovery) → calibrationInterrupted（重启中止）")
    check(notificationEvents(
        previous: dStatus("calibration:discharge"), current: dStatus("calibration:cancel")
    ) == [], "校准-27", "calibration:cancel（用户/隐式取消）→ 无事件（即时反馈路径）")

    // 校准-28：首样本臂不破例（相位/终态字面量首样本 → 无事件——终态锁存保证重启前转移可见）。
    check(notificationEvents(previous: nil, current: dStatus("calibration:hold")) == []
            && notificationEvents(previous: nil, current: dStatus("calibration:done")) == []
            && notificationEvents(previous: nil, current: dStatus("calibration:safety")) == [],
          "校准-28", "首样本 calibration:* → 无事件（既有首样本臂不破例）")

    // 校准-29：limitReached 守卫补 calibration: 前缀（校准中止恢复停充不误报「已达上限」，R1 P2-1）。
    check(notificationEvents(
        previous: dStatus("calibration:safety"), current: dStatus("enforce:disableCharging")
    ) == [], "校准-29", "calibration:safety → enforce:disableCharging → 无事件（前缀豁免，防误报 limitReached）")
    check(notificationEvents(
        previous: dStatus("calibration:hold"), current: dStatus("enforce:disableCharging")
    ) == [], "校准-29", "calibration:hold（动作期）→ enforce:disableCharging → 无事件（同豁免）")

    // 校准-30：既有 fullOnce/discharge 通知不回归。
    check(notificationEvents(
        previous: dStatus("fullOnce:start"), current: dStatus("fullOnce:done")
    ) == [.actionCompleted(kind: OneShot.fullOnceKind)], "校准-30", "回归：fullOnce 完成通知不回归")
    check(notificationEvents(
        previous: dStatus("dischargeToLimit:start"), current: dStatus("dischargeToLimit:done")
    ) == [.actionCompleted(kind: Discharge.dischargeToLimitKind)], "校准-30", "回归：discharge 完成通知不回归")
    check(notificationEvents(
        previous: dStatus("fullOnce:done"), current: dStatus("enforce:disableCharging")
    ) == [], "校准-30", "回归：fullOnce 前缀豁免不回归（P1-4）")

    // ---- ⑨ AppSide 助手（方案 §4.1.9）----

    // 校准-31：isCalibrationAction/calibrationPhase 正/反/未知串/nil。
    do {
        func actionStatus(phase: String?) -> DaemonStatus {
            var action = OneShotAction(kind: kind, startedAt: t0, deadline: deadline)
            action.phase = phase
            return DaemonStatus(
                version: "fixture", mode: "active", upperLimit: 90, hysteresis: 2,
                action: action, timestamp: t0
            )
        }
        check(actionStatus(phase: "hold").isCalibrationAction
                && actionStatus(phase: "hold").calibrationPhase == .hold,
              "校准-31", "kind=calibration + phase=hold → isCalibrationAction true / calibrationPhase .hold")
        check(actionStatus(phase: "ferment").calibrationPhase == nil, "校准-31",
              "未知相位串（不在 Phase 原始值域）→ calibrationPhase nil（显式未知，不猜测语义）")
        let noPhase = DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 90, hysteresis: 2,
            action: OneShotAction(kind: kind, startedAt: t0, deadline: deadline), timestamp: t0
        )
        check(noPhase.isCalibrationAction && noPhase.calibrationPhase == nil, "校准-31",
              "phase 缺席（旧格式/缺失）→ isCalibrationAction true / calibrationPhase nil")
        let fullOnce = DaemonStatus(
            version: "fixture", mode: "active", upperLimit: 90, hysteresis: 2,
            action: OneShotAction(kind: OneShot.fullOnceKind, startedAt: t0, deadline: deadline),
            timestamp: t0
        )
        check(!fullOnce.isCalibrationAction && fullOnce.calibrationPhase == nil, "校准-31",
              "非校准动作 → isCalibrationAction false / calibrationPhase nil")
    }

    // ---- ⑩ 交互与拒绝（方案 §4.1.10）----

    // 校准-32：**0.23.0 自动放电自动机退役**——原「自动放电触发判定在校准动作
    // 活跃下恒 false」场景随 autoTriggerReady 判定链删除而退役（自动放电臂整体
    // 不存在，校准×放电互斥由 actionTrack 单轨 + topoff actionActive 静默门承接，
    // TopoffDomain 路由-钉面）。

    // 校准-33：Discharge/Calibration 常量独立演化断言（temperatureLimitC 同值不同义；
    // 其余常量按各自语义独立演化）。
    check(Discharge.temperatureLimitC == Calibration.temperatureLimitC, "校准-33",
          "temperatureLimitC 同值（40.0）——同值不同义，独立演化（各自文件单一真相）")
    check(Discharge.dischargeTimeout != Calibration.dischargeTimeout
            && Discharge.floorPercent != Calibration.dischargeTargetPercent,
          "校准-33", "超时窗/目标值按语义独立演化（放电 2h vs 校准 12h；地板 60 vs 校准目标 10）")

    // 校准-34：轨道幂等（校准在轨 startIfIdle 拒绝；取消后空轨可启动）。
    do {
        var track = OneShotTrack()
        _ = track.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        track.setCalibrationPhase(.chargeFull, startedAt: t0)
        check(!track.startIfIdle(now: t0.addingTimeInterval(10), kind: kind, timeout: Calibration.totalDeadline),
              "校准-34", "校准在轨再次启动 → 拒绝（daemon 幂等回当前状态）")
        _ = track.cancel()
        check(track.startIfIdle(now: t0.addingTimeInterval(20), kind: kind, timeout: Calibration.totalDeadline),
              "校准-34", "取消后空轨 → 可启动")
    }

    // 校准-34a（0.23.2 §1.5 互斥）：fullOnce 临时放开窗活跃 → 校准启动拒绝
    // .fullOnceActive（拒因原文 + description 透传）；互斥对称面 = fullOnce 侧
    // .actionOccupiedOn27（OneShotStartRejection——原文钉在 OneShot 域）。
    check(CalibrationStartRejection.fullOnceActive.message.contains("充满一次")
              && CalibrationStartRejection.fullOnceActive.message.contains("恢复限充"),
          "校准-34a", ".fullOnceActive 原文为中文可读文案（含「先恢复限充」引导——XPC errorReply 上屏）")
    check(String(describing: CalibrationStartRejection.fullOnceActive)
              == CalibrationStartRejection.fullOnceActive.message,
          "校准-34a", "description == message（XPC errorReply 原文透传）")
    check(OneShotStartRejection.actionOccupiedOn27.message.contains("其他动作进行中"),
          "校准-34a", ".actionOccupiedOn27（fullOnce 侧对称拒因）原文可读——27 窗模式在轨动作显式拒绝")
    check(String(describing: OneShotStartRejection.actionOccupiedOn27)
              == OneShotStartRejection.actionOccupiedOn27.message,
          "校准-34a", "actionOccupiedOn27 description == message（XPC errorReply 原文透传）")

    // 校准-35：terminateCalibration 终态锁存（App 轮询必见；M3 判例同 daemon 发起取消）。
    do {
        var track = OneShotTrack()
        _ = track.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        track.setCalibrationPhase(.chargeFull, startedAt: t0)
        let literal = track.terminateCalibration(CalibrationLiteral.done())
        check(literal == "calibration:done" && track.action == nil && track.latchedLiteral == literal,
              "校准-35", "完成终态锁存（done 常驻到下次用户动作）")
        check(track.effectiveLastAction("enforce:disableCharging") == "calibration:done",
              "校准-35", "锁存生效：后续常规 tick 的 enforce:xxx 不覆盖校准终态")
    }

    // ---- ⑪ StatusFailureKind 映射（方案 §4.1.11 + R2 P2-3）----

    // 校准-36：calibration:safety/timeout/cancel(crash-recovery) → .actionInterrupted；
    // done/cancel 不入失败通道；既有映射不回归。
    check(StatusFailureKind(status: dStatus("calibration:safety")) == .actionInterrupted
            && StatusFailureKind(status: dStatus("calibration:timeout")) == .actionInterrupted
            && StatusFailureKind(status: dStatus("calibration:cancel(crash-recovery)")) == .actionInterrupted,
          "校准-36", "校准中止三字面量 → .actionInterrupted（失败横幅通道如实上屏）")
    check(StatusFailureKind(status: dStatus("calibration:done")) == nil
            && StatusFailureKind(status: dStatus("calibration:cancel")) == nil,
          "校准-36", "calibration:done / calibration:cancel 不入失败通道（done 走成功横幅）")
    check(StatusFailureKind(status: dStatus("fullOnce:timeout")) == .actionTimedOut
            && StatusFailureKind(status: dStatus("dischargeToLimit:safety")) == .actionSafetyTerminated
            && StatusFailureKind(status: dStatus("enforce:error")) == .writeFailed,
          "校准-36", "回归：既有 fullOnce/discharge/enforce 映射不回归")

    // ---- ⑫ 终态观察空闲臂判定（0.23.6 B1-1：calibrationIdleOutcomeObservation
    //      单一谓词源——26 执法段空闲臂 / 27 观测段镜像臂共用，防两臂判定漂移）----

    // 校准-37：判定双挡门（在轨挡住 / 无锁存挡住——镜像臂消费的真值表两负例）。
    check(calibrationIdleOutcomeObservation(
        actionActive: true, latchedLiteral: CalibrationLiteral.done()) == nil,
          "校准-37", "actionActive=true（在轨）+ done 锁存 → nil（在轨动作期不观察——③ 调度臂静默同形）")
    check(calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: nil) == nil,
          "校准-37", "actionActive=false + 无锁存 → nil（无终态可观察——常态空闲不补写）")

    // 校准-38：空闲 + 5 个校准终态字面量 → 各自 outcome 全映射（镜像臂补写记录的输入域；
    // cancel/crashRecovery 在列——与执法段空闲臂共用同源，语义收敛不漂移）。
    check(calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: CalibrationLiteral.done()) == .done
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: CalibrationLiteral.cancel()) == .cancel
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: CalibrationLiteral.timeout()) == .timeout
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: CalibrationLiteral.safety()) == .safety
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: CalibrationLiteral.cancelCrashRecovery()) == .crashRecovery,
          "校准-38", "空闲 + 五终态字面量 → 各自 outcome（done/cancel/timeout/safety/crashRecovery 全映射）")

    // 校准-39：空闲 + 非校准字面量 → nil（R1 P2 全等匹配同源——相位/其他动作族/
    // 空串不进观察臂，不虚构校准记录）。
    check(calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: "dischargeToLimit:done") == nil
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: "enforce:disableCharging") == nil
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: "enforce:noop") == nil
            && calibrationIdleOutcomeObservation(
        actionActive: false, latchedLiteral: "") == nil,
          "校准-39", "空闲 + 非校准字面量（dischargeToLimit:done/enforce:*/空串）→ nil")

    // ---- ⑬ hold→discharge 推进失败收口（0.23.10 B4-1，方案 §2.1）----

    // 校准-40：推进失败三态——advanceFailures 0/1/2 → advance 重试（正常路径与
    // 瞬时失败幂等重试语义零变化）；≥3 → abort(advanceExhausted, safety:false)。
    // 缺陷闭环钉面：推进判定成立时本分支每拍短路 deadline 兜底（失败臂内存相位
    // 不推进 → 每拍重进本分支）——持续失败期连 deadline 判定都不可达，计数收口
    // 是唯一可达兜底（plan-reviewer P2-b：deadline 仅 phaseStartedAt==nil 防御态可达）。
    let b4HoldStart = t0.addingTimeInterval(3600)
    let b4HoldDue = b4HoldStart.addingTimeInterval(Calibration.holdDuration)
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: b4HoldDue, percent: 100,
        advanceFailures: 0
    )).output == .advance(to: .discharge), "校准-40", "advanceFailures=0（推进成功常态）→ advance(discharge)——收口不误伤正常路径")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: b4HoldDue, percent: 100,
        advanceFailures: 1
    )).output == .advance(to: .discharge), "校准-40", "advanceFailures=1（瞬时失败第 1 拍）→ advance（下 tick 幂等重试语义保留）")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: b4HoldDue, percent: 100,
        advanceFailures: 2
    )).output == .advance(to: .discharge), "校准-40", "advanceFailures=2（瞬时失败第 2 拍）→ advance（重试窗口内）")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: b4HoldDue, percent: 100,
        advanceFailures: Calibration.advanceFailureLimit
    )).output == .abort(reason: CalibrationLiteral.AbortReason.advanceExhausted, safety: false),
    "校准-40", "advanceFailures=3（达上限）→ abort(advanceExhausted, safety:false)（判例：discharge 相 keepAliveFailures ≥3 收口；safety=false = hold 停充维持是安全态）")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: b4HoldDue, percent: 100,
        advanceFailures: 10
    )).output == .abort(reason: CalibrationLiteral.AbortReason.advanceExhausted, safety: false),
    "校准-40", "advanceFailures=10（远超上限）→ abort(advanceExhausted)（≥ 判定非 ==3 精确匹配）")
    check(calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: deadline.addingTimeInterval(1), percent: 100,
        advanceFailures: Calibration.advanceFailureLimit
    )).output == .abort(reason: CalibrationLiteral.AbortReason.advanceExhausted, safety: false),
    "校准-40", "持续失败期已超 24h deadline → abort(advanceExhausted)（deadline 判定被 advance 判定结构性遮蔽——计数收口不依赖 deadline 可达性）")

    // 校准-41：stay 分支计数透传 + keepAliveFailures 独立性 + 常量判例值钉面。
    // CalibrationTickResult 不携带 advanceFailures（计数增减由 daemon 执行结果
    // 决定——转移纯透传，applyCalibrationCounters 签名不变）。
    check(Calibration.advanceFailureLimit == 3,
          "校准-41", "advanceFailureLimit = 3（自身判例值钉死；与 keepAliveFailureLimit 同值为初版巧合不焊死——两常量按语义独立演化，keepAliveFailureLimit 调值不联动本断言）")
    let b4Stay = calibrationTick(calInput(
        phase: .hold, phaseStartedAt: b4HoldStart, now: b4HoldStart.addingTimeInterval(600), percent: 100,
        advanceFailures: 2
    ))
    check(b4Stay.output == .stay(phase: .hold) && b4Stay.keepAliveFailures == 0 && b4Stay.debounceTicks == 0,
          "校准-41", "hold stay 分支（静置未满）在 advanceFailures=2 时照常 stay、两计数器归零输出——转移不改写推进计数（生命周期归 daemon 执行结果）")
    let b4HoldIndependent = calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, keepAliveFailures: 0, advanceFailures: 3, chieStatus: .held
    ))
    check(b4HoldIndependent.output == .stay(phase: .discharge) && b4HoldIndependent.keepAliveFailures == 0,
          "校准-41", "discharge 相不消费 advanceFailures（held 清零回归——保活判定链零触及）")
    let b4KeepAliveCounting = calibrationTick(calInput(
        phase: .discharge, phaseStartedAt: dischargeStart, now: dischargeStart.addingTimeInterval(300),
        percent: 50, keepAliveFailures: 1, advanceFailures: 3, chieStatus: .failed
    ))
    check(b4KeepAliveCounting.output == .stay(phase: .discharge) && b4KeepAliveCounting.keepAliveFailures == 2,
          "校准-41", "failed 递增仅走 keepAliveFailures（1+1=2，advanceFailures=3 不混入——两计数独立演化，B4-1 非目标：保活语义零触及）")

    // 校准-42：生命周期钉值（track 层直测，MainEntry 用例 100 形态）——取消/崩溃
    // 恢复出口 → 重启校准 → advanceFailures == 0（resetDischargeCounters 全生命周期
    // 出口共用点：startIfIdle/cancel/cancelLatched/cancelForCrashRecovery/
    // terminateCalibration 均调它，逐调用点核对无 mid-action 调用）。
    do {
        var track = OneShotTrack()
        _ = track.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        track.setCalibrationPhase(.hold, startedAt: t0)
        track.applyAdvanceOutcome(false)
        track.applyAdvanceOutcome(false)
        check(track.advanceFailures == 2, "校准-42", "推进失败 2 拍 → 计数 2（applyAdvanceOutcome 失败 +1）")
        _ = track.cancel()
        check(track.advanceFailures == 0, "校准-42", "取消（cancel）→ 计数归零（resetDischargeCounters 共用出口）")
        _ = track.startIfIdle(now: t0.addingTimeInterval(60), kind: kind, timeout: Calibration.totalDeadline)
        check(track.advanceFailures == 0 && track.isActive, "校准-42", "重启校准 → advanceFailures == 0（新动作计数零起点——计数不跨动作存活钉值）")
        track.applyAdvanceOutcome(false)
        check(track.advanceFailures == 1, "校准-42", "重启后再失败 1 拍 → 计数 1（从零起点累计，不残留上轮）")
        track.applyAdvanceOutcome(true)
        check(track.advanceFailures == 0, "校准-42", "推进成功 → 计数归零（成功归零循环——正常路径零变化的行为登记）")

        var crashTrack = OneShotTrack()
        _ = crashTrack.startIfIdle(now: t0, kind: kind, timeout: Calibration.totalDeadline)
        crashTrack.applyAdvanceOutcome(false)
        crashTrack.applyAdvanceOutcome(false)
        crashTrack.applyAdvanceOutcome(false)
        check(crashTrack.advanceFailures == 3, "校准-42", "崩溃恢复前置于轨计数 3（已达上限态）")
        _ = crashTrack.adoptForCrashRecovery(OneShotAction(
            kind: kind, startedAt: t0, deadline: deadline
        ))
        _ = crashTrack.startIfIdle(now: t0.addingTimeInterval(120), kind: kind, timeout: Calibration.totalDeadline)
        check(crashTrack.advanceFailures == 0, "校准-42", "崩溃恢复出口（adoptForCrashRecovery→cancelForCrashRecovery）→ 重启校准 → 计数归零（启动侧出口同源 resetDischargeCounters）")
    }
}