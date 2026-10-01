// CellarCoreCheck —— 0.20.1 健壮性热修批场景域（方案 §2.1/§2.2/§3.1/§3.2/§3.3/§4）：
// - watchdog 阈值判定纯函数（§2.2——阈值/间隔常量 + 边界三分支 + nil lastTickAt 参照）；
// - §2.1 事件落盘枚举（DischargePersistEvent——case 全集 = 挂钩表六行，文案格式钉死）；
// - §3.1 install 指引分支（BootstrapFailureGuidance——BTM 损坏/清理竞态/其余三分流）；
// - §3.2 doctor 检查 9 spawnFailed 按路线再分流（appManaged → resetbtm 指引）；
// - §3.3 doctor 检查 8/9 口径统一（XPC 失败 ∧ 注册在位 → WARN + kickstart）；
// - §4 检查 3 文案按运行身份分流（root 不再带「非 root 时结论仅供参考」限定语）。
//
// 全部为 CellarCore 纯函数面（daemon/CLI/App 侧只消费），零 IOKit/子进程触碰；
// 与 MainEntry 共用 FailureCounter 与断言助手。

import CellarCore
import Foundation

/// 0.20.1 健壮性热修域入口（Main.main 调用）。
func runRobustnessDomainScenarios() {
    // ---- §2.2 watchdog：常量与阈值判定纯函数 ----

    // 常量钉死（评审定稿值：间隔 30s、阈值 150s = 3×30s + 60s 余量、退出码 42）。
    expectEqual(HeartbeatWatchdog.checkInterval, 30.0, "热修-wd-1", "检查间隔 = 30s")
    expectEqual(HeartbeatWatchdog.stallThreshold, 150.0, "热修-wd-1", "停摆阈值 = 150s（3×30s tick + 60s 余量）")
    expectEqual(HeartbeatWatchdog.suicideExitCode, Int32(42), "热修-wd-1", "自杀退出码 = 42（0/1 无冲突）")

    let start = Date(timeIntervalSince1970: 1_000_000)
    let tick = start.addingTimeInterval(30)   // 首 tick（入口首行更新点语义）

    check(!HeartbeatWatchdog.shouldSelfTerminate(
        lastTickAt: tick, watchdogStart: start, now: tick.addingTimeInterval(149.9)
    ), "热修-wd-2", "lastTick 距今 149.9s（< 阈值）→ 不自杀")
    check(!HeartbeatWatchdog.shouldSelfTerminate(
        lastTickAt: tick, watchdogStart: start, now: tick.addingTimeInterval(150.0)
    ), "热修-wd-3", "lastTick 距今恰 150s（== 阈值，严格大于判定）→ 不自杀")
    check(HeartbeatWatchdog.shouldSelfTerminate(
        lastTickAt: tick, watchdogStart: start, now: tick.addingTimeInterval(150.1)
    ), "热修-wd-4", "lastTick 距今 150.1s（> 阈值）→ 自杀")
    check(!HeartbeatWatchdog.shouldSelfTerminate(
        lastTickAt: tick, watchdogStart: start, now: tick.addingTimeInterval(30)
    ), "热修-wd-5", "正常心跳节奏（距今 30s）→ 不自杀")
    // nil lastTickAt（disabled 模式启动后尚未 tick）：以 watchdog 装配时刻为参照——
    // 装配后 150s 内不杀（首心跳 30s 到达），仍无 tick 视为停摆（主 RunLoop 冻结形态）。
    check(!HeartbeatWatchdog.shouldSelfTerminate(
        lastTickAt: nil, watchdogStart: start, now: start.addingTimeInterval(150.0)
    ), "热修-wd-6", "无 tick 记录 + 装配后恰 150s → 不自杀（严格大于）")
    check(HeartbeatWatchdog.shouldSelfTerminate(
        lastTickAt: nil, watchdogStart: start, now: start.addingTimeInterval(180)
    ), "热修-wd-7", "无 tick 记录 + 装配后 180s（主 RunLoop 冻结、首心跳不可达）→ 自杀")

    // ---- §2.1 放电关键事件落盘枚举（case 全集 = 挂钩表六行）----

    // 第一行·启动（manual/autostart）：initiator/target/percent（电量未知 = 未知）。
    expectEqual(
        DischargePersistEvent.started(initiator: "manual", target: 75, percent: 86).message,
        "放电启动：initiator=manual target=75% percent=86%",
        "热修-落盘-1", "启动事件文案（manual + 电量在位）")
    expectEqual(
        DischargePersistEvent.started(initiator: "auto", target: 75, percent: nil).message,
        "放电启动：initiator=auto target=75% percent=未知",
        "热修-落盘-1", "启动事件文案（auto + 电量未知——快照失败回落亦未知形态）")

    // 第二行·前置拒绝（能力不可用/mode/外接/电量/合盖/持久化——各拒绝臂共用）。
    expectEqual(
        DischargePersistEvent.rejected(reason: "合盖状态（防合盖放电黑屏——强检查命中）").message,
        "放电拒绝：原因=合盖状态（防合盖放电黑屏——强检查命中）",
        "热修-落盘-2", "拒绝事件文案（拒绝臂原因透传）")

    // 第三行·maintain 终态（完成/超时/安全终止 + 历时）。
    expectEqual(
        DischargePersistEvent.terminal(outcome: "安全终止(thermal)", durationSeconds: 1800).message,
        "放电终态：outcome=安全终止(thermal) 历时=1800s",
        "热修-落盘-3", "终态事件文案（outcome + 历时）")

    // 第四行·监护缺失终止（缺失原因=调用方注入的早退成因）。
    expectEqual(
        DischargePersistEvent.monitoringLoss(reason: "电池采样失败").message,
        "放电监护缺失终止：缺失原因=电池采样失败",
        "热修-落盘-4", "监护缺失终止事件文案")

    // 第五行·取消（睡眠/合盖中止/用户/隐式/保活失败/外接恢复）。
    expectEqual(
        DischargePersistEvent.cancelled(reason: "系统睡眠").message,
        "放电取消：原因=系统睡眠",
        "热修-落盘-5", "取消事件文案")

    // 第六行·启动崩溃恢复。
    expectEqual(
        DischargePersistEvent.crashRecovery(detail: "kind=dischargeToLimit 残留已取消，已恢复 CHIE=0x00").message,
        "放电崩溃恢复：kind=dischargeToLimit 残留已取消，已恢复 CHIE=0x00",
        "热修-落盘-6", "崩溃恢复事件文案")

    // 枚举边界（挂钩表六行 = case 全集）：Equatable 可区分各事件族。
    check(DischargePersistEvent.cancelled(reason: "x") != DischargePersistEvent.rejected(reason: "x"),
          "热修-落盘-7", "取消与拒绝为不同事件族（挂钩表行边界）")

    // ---- §3.1 install BTM 幽灵检测：指引分流纯函数 ----

    /// BTM 损坏记录样本（真机定谳形态：managed_by 托管 + last exit 78 EX_CONFIG）。
    let btmCorruptedSample = """
    system/com.cellar.daemon = {
        active count = 0
        type = Submitted
        managed_by = com.apple.xpc.ServiceManagement
        state = spawn scheduled
        program identifier = Contents/Library/LaunchDaemons/cellar-daemon (mode: 2)
        runs = 54
        last exit code = 78: EX_CONFIG
        job state = spawn failed
    }
    """
    expectEqual(
        BootstrapFailureGuidance.classify(fromPrintOutput: btmCorruptedSample),
        BootstrapFailureGuidance.btmCorruptedRecord,
        "热修-幽灵-1", "managed_by ∧ last exit 78 → BTM 损坏记录（面板卸载 + resetbtm 指引）")

    // 托管注册在位但非 78 退出（非损坏形态）→ 其余（不附 BTM 指引防误导）。
    let managedHealthySample = "managed_by = com.apple.xpc.ServiceManagement\nlast exit code = 0\nstate = running\n"
    expectEqual(
        BootstrapFailureGuidance.classify(fromPrintOutput: managedHealthySample),
        BootstrapFailureGuidance.other,
        "热修-幽灵-2", "managed_by 在位 ∧ 无 exit 78 → other（原始错误透传）")

    // 无 managed_by（bootout 后清理竞态——含 Could not find service/空输出/手工
    // program 行三形态）→ cleanupRace（等 60s 重跑 install 幂等）。
    expectEqual(
        BootstrapFailureGuidance.classify(
            fromPrintOutput: "Could not find service \"com.cellar.daemon\" in domain for system"
        ),
        BootstrapFailureGuidance.cleanupRace,
        "热修-幽灵-3", "Could not find service（无 managed_by）→ 清理竞态指引")
    expectEqual(
        BootstrapFailureGuidance.classify(fromPrintOutput: ""),
        BootstrapFailureGuidance.cleanupRace,
        "热修-幽灵-3", "空输出 → 清理竞态指引")
    expectEqual(
        BootstrapFailureGuidance.classify(fromPrintOutput: "program = /Library/PrivilegedHelperTools/com.cellar.daemon\nstate = not running\n"),
        BootstrapFailureGuidance.cleanupRace,
        "热修-幽灵-3", "手工格式（无 managed_by）→ 清理竞态指引")

    // 78 误报防线：exit 0 / 其他退出码不构成损坏判定。
    expectEqual(
        BootstrapFailureGuidance.classify(fromPrintOutput: "managed_by = com.apple.xpc.ServiceManagement\nlast exit code = 1\n"),
        BootstrapFailureGuidance.other,
        "热修-幽灵-4", "managed_by ∧ last exit 1（非 78）→ other（不误判损坏）")

    // ---- §3.2 doctor 检查 9：spawnFailed 按路线再分流 ----

    func doctorInputs(
        btmState: BTMState?, daemonStatus: DaemonStatus?, route: DaemonRoute?, isRoot: Bool = true
    ) -> DoctorInputs {
        DoctorInputs(
            isRoot: isRoot, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: daemonStatus,
            daemonProbeAttempted: true,
            btmState: btmState,
            btmProbeAttempted: true,
            daemonRoute: route
        )
    }

    do {
        // appManaged ∧ spawn failed → FAIL 新指引（面板卸载 + resetbtm——原「重启或
        // sudo cellar install」在该形态下是死循环）。
        let report = DoctorReportGenerator.generate(doctorInputs(
            btmState: .spawnFailed, daemonStatus: nil, route: .appManaged
        ))
        let btmCheck = report.checks.first { $0.name == "守护进程注册" }
        check(btmCheck?.status == .fail
            && btmCheck?.detail.contains("App 托管 BTM 记录损坏") == true
            && btmCheck?.detail.contains("sfltool resetbtm") == true,
              "热修-医生-1", "appManaged ∧ spawnFailed → FAIL「App 托管 BTM 记录损坏…resetbtm」指引")
        // manual / unknown / 未解析 → 保持原语义（README「更新 App」节指引）。
        for route in [DaemonRoute.manual, .unknown, nil] {
            let report = DoctorReportGenerator.generate(doctorInputs(
                btmState: .spawnFailed, daemonStatus: nil, route: route
            ))
            let btmCheck = report.checks.first { $0.name == "守护进程注册" }
            check(btmCheck?.status == .fail
                && btmCheck?.detail.contains("README「更新 App」节") == true,
                  "热修-医生-2", "spawnFailed ∧ route=\(String(describing: route)) → 原语义（README 指引）")
        }
    }

    // ---- §3.3 doctor 检查 8/9 口径统一 ----

    do {
        // running ∧ XPC 失败（检查 8 判「未安装或未运行」）→ 检查 9 WARN 注明
        // 「注册在位但 XPC 无响应」+ kickstart 指引（wedge 挂起形态可检出）。
        let report = DoctorReportGenerator.generate(doctorInputs(
            btmState: .running, daemonStatus: nil, route: .appManaged
        ))
        let btmCheck = report.checks.first { $0.name == "守护进程注册" }
        check(btmCheck?.status == .warn
            && btmCheck?.detail.contains("注册在位但 XPC 无响应") == true
            && btmCheck?.detail.contains("kickstart -k system/com.cellar.daemon") == true,
              "热修-医生-3", "running ∧ XPC 失败 → WARN「注册在位但 XPC 无响应」+ kickstart")
        // running ∧ XPC 可达 → 既有 PASS 语义零变化。
        let onlineReport = DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: nil, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(
                version: DaemonXPC.daemonVersion, mode: "active",
                upperLimit: 80, hysteresis: 2, timestamp: Date()
            ),
            daemonProbeAttempted: true,
            btmState: .running,
            btmProbeAttempted: true,
            daemonRoute: .appManaged
        ))
        let onlineCheck = onlineReport.checks.first { $0.name == "守护进程注册" }
        check(onlineCheck?.status == .pass && onlineCheck?.detail == "daemon 已注册且运行中",
              "热修-医生-4", "running ∧ XPC 可达 → PASS「daemon 已注册且运行中」（既有语义）")
    }

    // ---- §4 检查 3：后端探测 noneAvailable 文案按运行身份分流 ----

    do {
        func readOnlyInputs(isRoot: Bool) -> DoctorInputs {
            DoctorInputs(
                isRoot: isRoot, smcConnected: true,
                probe: .noneAvailable,
                chargingEnabled: nil, chargingError: nil,
                snapshot: nil, snapshotError: nil,
                conflict: ConflictScanResult(exact: [], generic: [])
            )
        }
        let rootReport = DoctorReportGenerator.generate(readOnlyInputs(isRoot: true))
        let rootCheck = rootReport.checks.first { $0.name == "后端探测" }
        // root：探测结论是确定性事实——「非 root 时结论仅供参考」限定语不再出现。
        check(rootCheck?.detail.contains("非 root 时结论仅供参考") != true
            && rootCheck?.detail.contains("root 身份探测，结论确定") == true,
              "热修-医生-5", "root ∧ noneAvailable → 「root 身份探测，结论确定」（过时措辞移除）")
        let userReport = DoctorReportGenerator.generate(readOnlyInputs(isRoot: false))
        let userCheck = userReport.checks.first { $0.name == "后端探测" }
        check(userCheck?.detail.contains("非 root 时结论仅供参考") == true,
              "热修-医生-6", "非 root ∧ noneAvailable → 原限定语保留")
    }
}
