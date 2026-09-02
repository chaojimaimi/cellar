// CellarCoreCheck —— WP5 doctor 检查 9–11 + 检查 3/6 扩展场景域（方案 §2.1/§2.2）
//
// 兼容性约束（评审 P0-3）：新输入字段全缺省值 + 条件渲染——用例 65（count==7）/
// 69（count==8）已由 MainEntry.swift 既有断言钉死，本域只覆盖新字段非缺省形态。
// BTM 解析 fixture 用今日真实输出（2026-09-02 实测；含托管标识行已剔除——与
// 解析无关且非白名单字段）。

import CellarCore
import Foundation

/// doctor 扩展场景域入口（Main.main 调用）。
func runDoctorExtendedDomainScenarios() {
    let snapshot = try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date())

    // ---- 检查 9：BTM 注册态解析（纯函数）----

    /// spawn failed 样本（2026-09-02 今日实测摘录；「更新 App 后 BTM 缓存失效」
    /// 事故同形态：job state = spawn failed + last exit code 78）。
    let spawnFailedSample = """
    system/com.cellar.daemon = {
        active count = 0
        path = (submitted by smd.332)
        type = Submitted
        managed_by = com.apple.xpc.ServiceManagement
        state = spawn scheduled

        program identifier = Contents/Library/LaunchDaemons/cellar-daemon (mode: 2)
        parent bundle identifier = com.cellar.app
        parent bundle version = 2

        domain = system
        minimum runtime = 10
        exit timeout = 10
        runs = 54
        last exit code = 78: EX_CONFIG

        semaphores = {
            successful exit => 0
        }

        endpoints = {
            "com.cellar.daemon" = {
                port = 0x14e143
                active = 0
                managed = 1
            }
        }
        job state = spawn failed
    }
    """

    /// 运行中样本（2026-09-02 同日实测形态重构：state 行转 running、exit code 归零
    /// ——恢复后真实样貌；字段布局与实测输出一致）。
    let runningSample = """
    system/com.cellar.daemon = {
        active count = 1
        type = Submitted
        managed_by = com.apple.xpc.ServiceManagement
        state = running

        program identifier = Contents/Library/LaunchDaemons/cellar-daemon (mode: 2)
        parent bundle identifier = com.cellar.app

        domain = system
        minimum runtime = 10
        exit timeout = 10
        runs = 55
        last exit code = 0
    }
    """

    check(BTMState.parseLaunchctlPrint(spawnFailedSample) == .spawnFailed,
          "BTM-1", "今日实测 spawn failed 样本 → .spawnFailed（job state + exit 78 特征）")
    check(BTMState.parseLaunchctlPrint(runningSample) == .running,
          "BTM-1", "运行中样本（state = running + program identifier）→ .running")

    check(BTMState.parseLaunchctlPrint("") == .unregistered,
          "BTM-2", "空输出（print 非零退出且无输出头）→ .unregistered")
    check(BTMState.parseLaunchctlPrint("Could not find service \"com.cellar.daemon\" in domain for system") == .unregistered,
          "BTM-2", "Could not find service → .unregistered")

    check(BTMState.parseLaunchctlPrint("random garbage output without any marker") == nil,
          "BTM-3", "有输出但无任何特征行 → nil（解析失败 = info，不误报）")

    // 宽松性：缺字段不崩（无程序行/无运行计数等已删节形态）。
    check(BTMState.parseLaunchctlPrint("state = running") == .running,
          "BTM-4", "缺字段宽松：仅 state 行 → running")
    check(BTMState.parseLaunchctlPrint("program identifier = Contents/Library/LaunchDaemons/cellar-daemon (mode: 2)") == .running,
          "BTM-4", "缺字段宽松：仅 program identifier（无失败特征）→ running")

    // 启动失败特征行族（launchd 初始化失败各形态）。
    check(BTMState.parseLaunchctlPrint("Could not find and/or execute program specified by service") == .spawnFailed,
          "BTM-5", "程序缺失特征行 → .spawnFailed")
    check(BTMState.parseLaunchctlPrint("Service could not initialize: copy_bundle_path") == .spawnFailed,
          "BTM-5", "copy_bundle_path 特征 → .spawnFailed")
    check(BTMState.parseLaunchctlPrint("exited due to exit(78)") == .spawnFailed,
          "BTM-5", "exited due to exit(78) → .spawnFailed")

    // 运行中优先于残留失败特征（本次运行正常但保留上次崩溃 exit code 不误报）。
    check(BTMState.parseLaunchctlPrint("state = running\nlast exit code = 78: EX_CONFIG") == .running,
          "BTM-6", "running 优先：残留 exit 78 不误报 spawnFailed")

    // ---- 检查 3 键世代标注 + 检查 6 进程命中（并入既有检查）----

    func healthy() -> DoctorInputs {
        DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: [])
        )
    }

    // 医生-1：检查 3 世代标注（keyPresence 非缺省时附加；不改 status；缺省零变化）。
    do {
        let report = DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            keyPresence: KeyPresence(chte: true, chie: true, ch0b: false)
        ))
        check(report.checks[2].status == .pass
                && report.checks[2].detail.contains("CHTE 世代")
                && report.checks[2].detail.contains("CHIE 在位"),
              "医生-1", "tahoe + CHTE/CHIE 在位 → detail 附世代标注（status 仍 pass）")
    }
    do {
        let report = DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "legacy", keyNames: ["CH0B", "CH0C"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            keyPresence: KeyPresence(chte: false, chie: false, ch0b: true)
        ))
        check(report.checks[2].detail.contains("CH0B 世代"), "医生-1", "legacy + CH0B → CH0B 世代标注")
    }
    do {
        let report = DoctorReportGenerator.generate(healthy())
        check(!report.checks[2].detail.contains("世代") && report.checks[2].detail.contains("控制键：CHTE"),
              "医生-1", "keyPresence 缺省 → 无标注（既有 detail 零变化）")
    }

    // 医生-2：检查 6 进程命中并入（分列来源标注；warn 语义同目录命中）。
    do {
        let report = DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: ["batt.daemon"], generic: []),
            processHits: ["bclm[4421]", "aldente-pro[220]"]
        ))
        let check6 = report.checks[5]
        check(check6.status == .warn
                && check6.detail.contains("batt.daemon")
                && check6.detail.contains("进程命中：bclm[4421]、aldente-pro[220]"),
              "医生-2", "进程命中并入检查 6 detail（分列来源标注；warn 同目录语义）")
    }
    do {
        let report = DoctorReportGenerator.generate(DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            processHits: []
        ))
        check(report.checks[5].status == .pass && report.checks[5].detail.contains("未检测到"),
              "医生-2", "进程扫描零命中 → 检查 6 保持 pass（processHits=[] 不抬升）")
    }

    // ---- 检查 9/10/11 渲染与条件 ---- 

    func btmInputs(state: BTMState?, attempted: Bool = true) -> DoctorInputs {
        DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(version: "0.3.1-alpha", mode: "active", upperLimit: 80, hysteresis: 2),
            daemonProbeAttempted: true,
            btmState: state,
            btmProbeAttempted: attempted
        )
    }

    // 医生-3：检查 9 四态 + 条件不渲染。
    func btmCheck(_ inputs: DoctorInputs) -> DoctorCheck {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "BTM 注册" }!
    }
    check(btmCheck(btmInputs(state: .running)).status == .pass, "医生-3", "BTM running → PASS")
    check(btmCheck(btmInputs(state: .spawnFailed)).status == .fail
            && btmCheck(btmInputs(state: .spawnFailed)).detail.contains("sudo cellar install"),
          "医生-3", "BTM spawnFailed → FAIL（附 README「更新 App」节恢复指引）")
    let unregistered = btmCheck(btmInputs(state: .unregistered))
    check(unregistered.status == .info && unregistered.detail.contains("手工路线")
            && unregistered.detail.contains("托管路线"),
          "医生-3", "BTM unregistered → INFO（双路线文案）")
    check(btmCheck(btmInputs(state: nil)).status == .info,
          "医生-3", "BTM 解析失败（nil + attempted）→ INFO（不误报）")
    check(DoctorReportGenerator.generate(btmInputs(state: .running, attempted: false)).checks.count == 8,
          "医生-3", "BTM 未探测 → 不渲染（兼容形态 count==8）")

    // 医生-4：检查 10 版本矩阵判定表。
    func versionInputs(daemon: String?, app: String?) -> DoctorInputs {
        let daemonStatus = daemon.map {
            DaemonStatus(version: $0, mode: "active", upperLimit: 80, hysteresis: 2)
        }
        return DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: daemonStatus,
            daemonProbeAttempted: true,
            versionMatrix: VersionMatrix(
                cliVersion: "0.3.1-alpha", daemonVersion: daemon, appVersion: app
            )
        )
    }
    func versionCheck(_ inputs: DoctorInputs) -> DoctorCheck {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "版本矩阵" }!
    }
    let aligned = versionCheck(versionInputs(daemon: "0.3.1-alpha", app: "0.3.1-alpha"))
    check(aligned.status == .pass && aligned.detail.contains("三方一致"), "医生-4", "三方一致 → PASS")
    let staleDaemon = versionCheck(versionInputs(daemon: "0.3.0-alpha", app: "0.3.1-alpha"))
    check(staleDaemon.status == .fail && staleDaemon.detail.contains("sudo cellar install"),
          "医生-4", "daemon ≠ CLI → FAIL（stale 既有语义）")
    check(versionCheck(versionInputs(daemon: "0.3.1-alpha", app: "0.3.0-alpha")).status == .warn,
          "医生-4", "App ≠ 其他 → WARN（今日实证滞后样本形态）")
    let noApp = versionCheck(versionInputs(daemon: "0.3.1-alpha", app: nil))
    check(noApp.status == .info && noApp.detail.contains("未安装"), "医生-4", "App 缺席 → INFO")
    check(versionCheck(versionInputs(daemon: nil, app: "0.3.1-alpha")).status == .info,
          "医生-4", "daemon 未运行 → INFO（无从比对）")
    check(DoctorReportGenerator.generate(DoctorInputs(
        isRoot: true, smcConnected: true,
        probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
        chargingEnabled: false, chargingError: nil,
        snapshot: snapshot, snapshotError: nil,
        conflict: ConflictScanResult(exact: [], generic: []),
        daemonStatus: DaemonStatus(version: "0.3.1-alpha", mode: "active", upperLimit: 80, hysteresis: 2),
        daemonProbeAttempted: true
    )).checks.count == 8, "医生-4", "versionMatrix 缺省 → 检查 10 不渲染（7 基础 + daemon）")

    // ---- 检查 11 判定表（方案 §2.1 逐字）----

    func dischargeInputs(
        supported: Bool, chieState: Bool?, readFailed: Bool = false,
        action: OneShotAction? = nil
    ) -> DoctorInputs {
        DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(
                version: "0.3.1-alpha", mode: "active", upperLimit: 80, hysteresis: 2,
                action: action
            ),
            daemonProbeAttempted: true,
            dischargeProbe: DischargeProbe(supported: supported, chieState: chieState, readFailed: readFailed)
        )
    }
    func dischargeCheck(_ inputs: DoctorInputs) -> DoctorCheck {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "放电能力" }!
    }
    let dischargeAction = OneShotAction(
        kind: Discharge.dischargeToLimitKind,
        startedAt: Date(timeIntervalSince1970: 0),
        deadline: Date(timeIntervalSince1970: 3600)
    )

    check(dischargeCheck(dischargeInputs(supported: false, chieState: nil)).status == .info
            && dischargeCheck(dischargeInputs(supported: false, chieState: nil)).name == "放电能力",
          "医生-5", "不支持放电 → INFO")
    check(dischargeCheck(dischargeInputs(supported: true, chieState: false, action: dischargeAction)).status == .pass,
          "医生-5", "动作活跃（dischargeToLimit）∧ CHIE 禁用 0x08 → PASS（预期态）")
    check(dischargeCheck(dischargeInputs(supported: true, chieState: true, action: dischargeAction)).status == .warn,
          "医生-5", "动作活跃但 CHIE 回读异常 → WARN")
    check(dischargeCheck(dischargeInputs(supported: true, chieState: true)).status == .pass,
          "医生-5", "无动作 + CHIE 使能 0x00 → PASS")
    let residual = dischargeCheck(dischargeInputs(supported: true, chieState: false))
    check(residual.status == .fail && residual.detail.contains("残留"), "医生-5", "无动作 + CHIE 残留禁用 0x08 → FAIL（附恢复指引）")
    check(dischargeCheck(dischargeInputs(supported: true, chieState: nil, readFailed: true)).status == .info,
          "医生-5", "CHIE 读取失败（非 root 键不可见）→ INFO（与检查 3 同降级）")
    check(DoctorReportGenerator.generate(DoctorInputs(
        isRoot: true, smcConnected: true,
        probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
        chargingEnabled: false, chargingError: nil,
        snapshot: snapshot, snapshotError: nil,
        conflict: ConflictScanResult(exact: [], generic: []),
        daemonStatus: DaemonStatus(
            version: "0.3.1-alpha", mode: "active", upperLimit: 80, hysteresis: 2
        ),
        daemonProbeAttempted: true
    )).checks.count == 8, "医生-5", "dischargeProbe 缺省 → 检查 11 不渲染")

    // 医生-6：CLI 全探测路径输入形态 → 十一项全渲染（编号/顺序钉死）。
    do {
        let full = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(
                version: "0.3.1-alpha", mode: "active", upperLimit: 80, hysteresis: 2
            ),
            daemonProbeAttempted: true,
            keyPresence: KeyPresence(chte: true, chie: true, ch0b: false),
            processHits: [],
            btmState: .running, btmProbeAttempted: true,
            versionMatrix: VersionMatrix(
                cliVersion: "0.3.1-alpha", daemonVersion: "0.3.1-alpha", appVersion: "0.3.1-alpha"
            ),
            dischargeProbe: DischargeProbe(supported: true, chieState: true, readFailed: false)
        )
        let report = DoctorReportGenerator.generate(full)
        check(report.checks.count == 11, "医生-6", "全探测输入 → 11 项（7 基础 + daemon + BTM + 版本 + 放电）")
        check(report.checks[8].name == "BTM 注册" && report.checks[9].name == "版本矩阵"
                && report.checks[10].name == "放电能力",
              "医生-6", "新增三项追加在既有 8 项之后（编号 9/10/11）")
        check(report.checks[10].status == .pass, "医生-6", "放电能力：无动作 + CHIE 使能 → PASS（全绿样本）")
        check(report.worstStatus == .pass && report.exitCode == 0, "医生-6", "全绿样本不抬升退出码")
    }
}