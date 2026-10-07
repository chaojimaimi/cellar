// CellarCoreCheck —— Phase 5 v1.7 M2 原生限充 daemon 接线场景域（方案 §3 清单）
//
// M1 NativeLimitDomain.swift（解析/口径/三态形态，原生-1..22）之后追加：
// wire 映射三态、DaemonStatus 缺席保持、校准/fullOnce 守卫拒绝文案双口径、
// doctor 第 15 项分支。全部纯函数面（Data 注入/直接构造 reading），不触碰真实
// plist、不起 daemon。与其他场景域共用 FailureCounter 与断言助手。
//
// 覆盖清单（M2 工单）：
// ① wireStatus 三态：detectorError 形态 / inactive（双 nil 钉死）/ active 双口径值
// ② DaemonStatus.nativeLimit 缺席保持（旧回包 decode nil / round-trip / 旧客户端
//    镜像 decode 新回包——多出键透明忽略，M2 验收「旧 App 收新回包不炸」单元侧锚点）
// ③ CalibrationStartRejection.nativeChargeLimit 文案双口径（manual 有/无）
// ④ OneShotStartRejection.nativeChargeLimit 平行 case + fullOnceStartPrecondition
//    守卫矩阵（阻断/fail-open/空策略/mode 优先序）
// ⑤ doctor 第 15 项分支：无策略/警告/提示/失败/未知/未探测缺省零渲染/十五项顺序
// ⑥ **0.23.1 迁移钉**（原 OrchestrationDomain 编排-14/15/16/18/19——编排 wire 兼容
//    面随编排退役保留照填）：OrchestrationStatus 载荷 round-trip / 旧 daemon JSON
//    缺键容忍 / wire 值域矩阵 / makeMessage+validateRequest 编排键组 / 类型白名单
//    整包拒绝

import CellarCore
import Foundation
import XPC

/// 原生限充 M2 接线场景域入口（Main.main 调用；全部纯函数，不触碰真实 plist）。
func runNativeLimitWireDomainScenarios() throws {
    let snapshot = try? BatterySnapshotParser.parse(batteryProps(), timestamp: Date())

    // ---- ① wireStatus 三态（方案 §3.2 钉死：known=false ⇒ active=false 双 nil；
    //      active=false（known=true）⇒ 双 nil；active ⇒ socLimit=blocking 最小）----

    // 原生-23：detectorError → known:false/active:false/双 nil（未知态形态固定；
    // load 损坏注入与直接构造两形态一致）。
    do {
        let constructed = NativeChargeLimit.wireStatus(
            NativeChargeLimitReading(policies: [], detectorError: true)
        )
        check(constructed == NativeLimitStatus(known: false, active: false, socLimit: nil, manualSocLimit: nil),
              "原生-23", "detectorError → known:false ∧ active:false ∧ 双 socLimit nil（未知态形态钉死）")
        let loaded = NativeChargeLimit.wireStatus(
            NativeChargeLimit.load(rooted: Data("corrupted".utf8))
        )
        check(loaded == constructed, "原生-23", "load 损坏注入映射 == 直接构造（detectorError 通路一致）")
    }

    // 原生-24：inactive 形态（成功无阻断）——空 policies / 仅 terminated / 仅
    // manual-100（manual 口径非 nil 也不泄漏）⇒ known:true ∧ active:false ∧ 双 nil。
    do {
        let empty = NativeChargeLimit.wireStatus(NativeChargeLimitReading(policies: [], detectorError: false))
        check(empty == NativeLimitStatus(known: true, active: false, socLimit: nil, manualSocLimit: nil),
              "原生-24", "空策略 → known:true ∧ active:false ∧ 双 nil（inactive 形态钉死）")
        let terminatedOnly = NativeChargeLimit.wireStatus(NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: true),
        ]))
        check(terminatedOnly.active == false && terminatedOnly.socLimit == nil && terminatedOnly.manualSocLimit == nil,
              "原生-24", "仅 terminated → inactive ∧ 双 nil（消费侧过滤后不泄漏）")
        let manualHundred = NativeChargeLimit.wireStatus(NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 100, reason: "manualChargeLimit", terminated: false),
        ]))
        check(manualHundred.active == false && manualHundred.socLimit == nil
                && manualHundred.manualSocLimit == nil,
              "原生-24", "仅 manual-100（soclimit==100 等效关闭）→ inactive ∧ 双 nil（manual 口径不单独点亮 active）")
    }

    // 原生-25：active 手动单策略 → 全字段（known/active/socLimit/manualSocLimit）。
    do {
        let wire = NativeChargeLimit.wireStatus(NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false),
        ]))
        check(wire == NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85),
              "原生-25", "manual 85 单策略 → known:true ∧ active:true ∧ socLimit:85 ∧ manual:85（active 全字段）")
    }

    // 原生-26：active 双口径分流（原生-13/14 的 wire 面）——manual(90)+OBC(85) →
    // socLimit=85（blocking 最小，最先触发者）、manual=90（用户可操作值）；
    // 仅 OBC → manual=nil（通用文案口径）。
    do {
        let mixed = NativeChargeLimit.wireStatus(NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 90, reason: "manualChargeLimit", terminated: false),
            NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false),
        ]))
        check(mixed.active && mixed.socLimit == 85 && mixed.manualSocLimit == 90,
              "原生-26", "manual(90)+OBC(85) → socLimit:85 ∧ manual:90（双口径分流）")
        let obcOnly = NativeChargeLimit.wireStatus(NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false),
        ]))
        check(obcOnly.active && obcOnly.socLimit == 85 && obcOnly.manualSocLimit == nil,
              "原生-26", "仅 OBC → socLimit:85 ∧ manual:nil（通用文案口径）")
    }

    // ---- ② DaemonStatus.nativeLimit 缺席保持（M2 验收：旧 App 收新回包不炸）----

    // 原生-27：旧回包（无键）decode → nil；round-trip 保真；旧客户端字段面镜像
    // decode 新回包 → 多出键透明忽略。
    do {
        let legacyJSON = #"{"version":"0.12.0-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":700000000.0}"#
        let legacy = try JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        check(legacy.nativeLimit == nil,
              "原生-27", "旧回包无 nativeLimit 键 → decode nil（合成 Codable decodeIfPresent 缺席保持）")

        var status = DaemonStatus(version: "0.12.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2)
        status.nativeLimit = NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        let roundTrip = try JSONDecoder().decode(DaemonStatus.self, from: JSONEncoder().encode(status))
        check(roundTrip.nativeLimit == status.nativeLimit,
              "原生-27", "nativeLimit round-trip 保真（active 全字段）")

        struct LegacyStatusMirror: Codable, Equatable {  // 旧 daemon 字段面（v1.6 止）
            var version: String
            var mode: String
            var upperLimit: Int
            var hysteresis: Int
            var timestamp: Date
        }
        let mirror = try JSONDecoder().decode(LegacyStatusMirror.self, from: JSONEncoder().encode(status))
        check(mirror == LegacyStatusMirror(
                version: "0.12.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2,
                timestamp: status.timestamp),
              "原生-27", "旧客户端字段面镜像 decode 新回包成功（多出的 nativeLimit 键透明忽略——零破坏）")
    }

    // ---- ③④ 校准/fullOnce 守卫（方案 §3.1：拒绝文案双口径 + fail-open 边界）----

    // 原生守卫-1：CalibrationStartRejection.nativeChargeLimit(manual) 手动口径文案。
    do {
        let rejection = CalibrationStartRejection.nativeChargeLimit(socLimit: 85)
        check(rejection.message == "系统充电上限已激活（85%），校准需充满 100%——请先在系统设置中关闭"
                && rejection.message == rejection.description,
              "原生守卫-1", "manualSocLimit 存在 → 「系统设置关闭」口径文案（N=85 动态填充，description 同文）")
    }

    // 原生守卫-2：CalibrationStartRejection.nativeChargeLimit(nil) 通用口径文案
    //（OBC 等系统策略对用户不可操作——「系统设置」字样不得出现）。
    check(CalibrationStartRejection.nativeChargeLimit(socLimit: nil).message
              == "检测到系统充电策略占用，校准需充满 100%",
          "原生守卫-2", "仅非手动策略 → 通用口径文案（无 N%、无「系统设置」字样）")

    // 原生守卫-3：OneShotStartRejection.nativeChargeLimit 平行 case 文案双口径
    //（充满一次家族主语惯例）+ Equatable 合成可用。
    do {
        check(OneShotStartRejection.nativeChargeLimit(socLimit: 90).message
                  == "系统充电上限已激活（90%），「充满一次」需充满 100%——请先在系统设置中关闭",
              "原生守卫-3", "manualSocLimit 存在 → 「系统设置关闭」口径文案（N=90 动态填充）")
        check(OneShotStartRejection.nativeChargeLimit(socLimit: nil).message
                  == "检测到系统充电策略占用，「充满一次」需充满 100%",
              "原生守卫-3", "仅非手动策略 → 通用口径文案")
        check(OneShotStartRejection.nativeChargeLimit(socLimit: 90)
                  == OneShotStartRejection.nativeChargeLimit(socLimit: 90),
              "原生守卫-3", "新 case Equatable 合成可用（DaemonCore.swift:762 提级不受影响的前提）")
    }

    // 原生守卫-4：fullOnceStartPrecondition 守卫矩阵（阻断/fail-open/空策略/mode 优先序）。
    do {
        func reading(_ policies: [NativeChargePolicy], detectorError: Bool = false) -> NativeChargeLimitReading {
            NativeChargeLimitReading(policies: policies, detectorError: detectorError)
        }
        let manual85 = reading([NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false)])
        expectEqual(fullOnceStartPrecondition(mode: "active", externalConnected: true, nativeLimit: manual85),
                    .nativeChargeLimit(socLimit: 85),
                    "原生守卫-4", "manual 85 阻断 → 拒绝且关联值=manualSocLimit（文案口径输入）")
        let obcOnly = reading([NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false)])
        expectEqual(fullOnceStartPrecondition(mode: "active", externalConnected: true, nativeLimit: obcOnly),
                    .nativeChargeLimit(socLimit: nil),
                    "原生守卫-4", "仅 OBC 阻断 → 拒绝且关联值 nil（通用文案口径）")
        check(fullOnceStartPrecondition(mode: "active", externalConnected: true,
                                        nativeLimit: reading([], detectorError: true)) == nil,
              "原生守卫-4", "detectorError → 放行（fail-open 唯一边界，os_log warn 在函数内留痕）")
        check(fullOnceStartPrecondition(mode: "active", externalConnected: true,
                                        nativeLimit: reading([])) == nil,
              "原生守卫-4", "空策略 → 放行")
        check(fullOnceStartPrecondition(mode: "active", externalConnected: true, nativeLimit: reading([
            NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: true),
        ])) == nil, "原生守卫-4", "仅 terminated → 放行（消费侧过滤）")
        expectEqual(fullOnceStartPrecondition(mode: "disabled", externalConnected: true, nativeLimit: manual85),
                    .modeNotActive,
                    "原生守卫-4", "mode 先于 native 判定（既有前置次序不被守卫扰动）")
    }

    // ---- ⑤ doctor 第 15 项「原生限充共存」（口径 = blockingPolicies，方案 §3.3）----

    func doctorInputs(
        daemonStatus: DaemonStatus? = DaemonStatus(
            version: "0.12.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2
        ),
        nativeLimit: NativeLimitStatus?,
        attempted: Bool = true
    ) -> DoctorInputs {
        DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: daemonStatus,
            daemonProbeAttempted: true,
            nativeLimit: nativeLimit,
            nativeLimitProbeAttempted: attempted
        )
    }
    func nativeCheck(_ inputs: DoctorInputs) -> DoctorCheck {
        DoctorReportGenerator.generate(inputs).checks.first { $0.name == "原生限充共存" }!
    }

    // 医生-7：未探测缺省 → 不渲染（既有 count 断言兼容）；已探测无阻断策略 →
    // PASS 轻提示（注册态），不抬退出码。
    do {
        let withoutProbe = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: DaemonStatus(version: "0.12.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2),
            daemonProbeAttempted: true
        )
        check(DoctorReportGenerator.generate(withoutProbe).checks.count == 8,
              "医生-7", "nativeLimitProbeAttempted 缺省 → 检查 15 不渲染（7 基础 + daemon，兼容形态）")
        let idle = nativeCheck(doctorInputs(
            daemonStatus: nil,
            nativeLimit: NativeLimitStatus(known: true, active: false, socLimit: nil, manualSocLimit: nil)
        ))
        check(idle.status == .pass && idle.detail.contains("未检测到原生限充策略"),
              "医生-7", "无阻断策略 → PASS 轻提示（daemon 未运行亦照常渲染——plist 读取不依赖 daemon）")
    }

    // 医生-8：active 85 > L_c 80 → WARN（Cellar 执法生效、原生永不触发，二选一）。
    do {
        let check15 = nativeCheck(doctorInputs(
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        ))
        check(check15.status == .warn && check15.detail.contains("Cellar 执法生效")
                && check15.detail.contains("等效 80%") && check15.detail.contains("二选一"),
              "医生-8", "原生 85 > Cellar 80 → WARN（等效 80 + 二选一提示）")
        check(DoctorReportGenerator.generate(doctorInputs(
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        )).worstStatus == .warn,
              "医生-8", "WARN 分支抬升 worstStatus（退出码 1 通道）")
    }

    // 医生-9：active ≤ L_c → INFO（原生先执法，等效原生值）；daemon 未运行/未执法
    //（L_c nil）→ INFO 等效原生值。
    do {
        let equal = nativeCheck(doctorInputs(
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 80, manualSocLimit: 80)
        ))
        check(equal.status == .info && equal.detail.contains("原生先执法") && equal.detail.contains("等效 80%"),
              "医生-9", "原生 80 == Cellar 80 → INFO（≤ 判据，原生先执法等效原生值，不计失败）")
        let below = nativeCheck(doctorInputs(
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 75, manualSocLimit: 75)
        ))
        check(below.status == .info && below.detail.contains("原生先执法"),
              "医生-9", "原生 75 < Cellar 80 → INFO（原生先执法）")
        let offline = nativeCheck(doctorInputs(
            daemonStatus: nil,
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        ))
        check(offline.status == .info && offline.detail.contains("等效原生值"),
              "医生-9", "daemon 未运行（L_c nil）→ INFO 等效原生值（无 Cellar 执法前提，不误报冲突）")
    }

    // 医生-10：active + 校准进行中 → FAIL（判据被破坏；文案双口径——manual 有无）。
    do {
        func calibrationDaemon() -> DaemonStatus {
            var status = DaemonStatus(version: "0.12.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2)
            status.action = OneShotAction(
                kind: Calibration.kind, startedAt: Date(timeIntervalSince1970: 0),
                deadline: Date(timeIntervalSince1970: 3600)
            )
            return status
        }
        let manual = nativeCheck(doctorInputs(
            daemonStatus: calibrationDaemon(),
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        ))
        check(manual.status == .fail && manual.detail.contains("与校准冲突")
                && manual.detail.contains("系统设置"),
              "医生-10", "校准中 + manual 限充 → FAIL（「系统设置」口径 hint）")
        let obc = nativeCheck(doctorInputs(
            daemonStatus: calibrationDaemon(),
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: nil)
        ))
        check(obc.status == .fail && !obc.detail.contains("系统设置"),
              "医生-10", "校准中 + 仅 OBC → FAIL（通用 hint，无「系统设置」字样——双口径）")
        check(DoctorReportGenerator.generate(doctorInputs(
            daemonStatus: calibrationDaemon(),
            nativeLimit: NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        )).worstStatus == .fail,
              "医生-10", "FAIL 分支抬升 worstStatus（退出码 2 通道）")
    }

    // 医生-11：known=false（detectorError）→ INFO「未知」不计失败（worstStatus 不抬升）。
    do {
        let unknown = nativeCheck(doctorInputs(
            nativeLimit: NativeLimitStatus(known: false, active: false, socLimit: nil, manualSocLimit: nil)
        ))
        check(unknown.status == .info && unknown.detail.contains("检测未知"),
              "医生-11", "known=false → INFO 检测未知（提示「未知」，不计失败）")
        check(DoctorReportGenerator.generate(doctorInputs(
            nativeLimit: NativeLimitStatus(known: false, active: false, socLimit: nil, manualSocLimit: nil)
        )).worstStatus == .pass,
              "医生-11", "未知态不抬升 worstStatus（INFO 不参与——与守卫 fail-open 对齐）")
    }

    // 医生-12：CLI 全探测路径输入形态 → 十六项全渲染（编号/顺序钉死：第 16 项追加在末尾）。
    do {
        var ledDaemon = DaemonStatus(
            version: "0.14.0-alpha", mode: "active", upperLimit: 80, hysteresis: 2
        )
        ledDaemon.magSafeLed = MagSafeLED.wireStatus(
            mode: nil, supportState: .supported, readbackRaw: 0x04
        )
        let full = DoctorInputs(
            isRoot: true, smcConnected: true,
            probe: .detected(name: "tahoe", keyNames: ["CHTE"]),
            chargingEnabled: false, chargingError: nil,
            snapshot: snapshot, snapshotError: nil,
            conflict: ConflictScanResult(exact: [], generic: []),
            daemonStatus: ledDaemon,
            daemonProbeAttempted: true,
            keyPresence: KeyPresence(chte: true, chie: true, ch0b: false),
            processHits: [],
            btmState: .running, btmProbeAttempted: true,
            versionMatrix: VersionMatrix(
                cliVersion: "0.12.0-alpha", daemonVersion: "0.12.0-alpha", appVersion: "0.12.0-alpha"
            ),
            dischargeProbe: DischargeProbe(supported: true, chieState: true, readFailed: false),
            fanProbe: FanDoctorProbe(
                keysPresent: ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"],
                mdValue: 0, tgRPM: 1350, config: nil
            ),
            thermal: ThermalStatus(pauseCentiC: 4000, hysteresisCentiC: 300),
            thermalProbeAttempted: true,
            chargeSchedule: ChargeScheduleDoctorProbe(enabled: false, entryCount: 0, activeEntry: nil),
            chargeScheduleProbeAttempted: true,
            nativeLimit: NativeLimitStatus(known: true, active: false, socLimit: nil, manualSocLimit: nil),
            nativeLimitProbeAttempted: true,
            magSafeLed: ledDaemon.magSafeLed,
            magSafeLedProbeAttempted: true
        )
        let report = DoctorReportGenerator.generate(full)
        check(report.checks.count == 16, "医生-12", "全探测输入 → 16 项（7 基础 + daemon + 9-16）")
        check(report.checks[13].name == "充电日程" && report.checks[14].name == "原生限充共存"
                && report.checks[15].name == "MagSafe 指示灯",
              "医生-12", "检查 16 追加在检查 15 之后（顺序钉死）")
        check(report.checks[14].status == .pass && report.worstStatus == .pass && report.exitCode == 0,
              "医生-12", "全绿样本（原生未注册）不抬升退出码")
    }

    // 医生-16（0.20.2 §1.2 的 26 零回归背书）：osMajorVersion 26（缺省）即使 daemon
    // 上报 sub80 capable ∧ sub80State == .active（26 现实不可达形态——防御性输入），
    // 门控在 27 渲染分支内 → 26 分支逐字不变（WARN 现行执法语义）。
    do {
        let active85 = NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
        let sub80Active26 = doctorInputs(
            daemonStatus: DaemonStatus(
                version: "0.20.1-alpha", mode: "active", upperLimit: 80, hysteresis: 2,
                capabilities: [DaemonXPC.capabilityOrchestration, DaemonXPC.capabilitySub80],
                sub80State: .active
            ),
            nativeLimit: active85
        )
        let check15 = nativeCheck(sub80Active26)
        check(check15.status == .warn && check15.detail.contains("Cellar 执法生效")
                && check15.detail.contains("二选一") && check15.detail.contains("现行执法（上限") != true,
              "医生-16", "26 + sub80 门控输入 → WARN 现行语义零回归（0.20.2 §1.2 门控仅 osMajorVersion ≥ 27 分支内——26 行为零变化）")
    }

    try runOrchestrationWireCompatScenarios()
}

// MARK: - ⑥ 编排 wire 兼容迁移钉（0.23.1 自 OrchestrationDomain 编排-14/15/16/18/19
// 迁入——wire 零 schema 变化验收面：载荷照容/键组照解/值域照校验）

private func runOrchestrationWireCompatScenarios() throws {
    // 编排-14（迁移）：OrchestrationStatus round-trip（DaemonStatus.orchestration
    // 载荷全字段——0.23.1 起 daemon 侧 enabled 恒 false 照填，pending 四键旧
    // daemon 形态照容）。
    do {
        var status = DaemonStatus(version: "t", mode: "active", upperLimit: 85, hysteresis: 2)
        status.orchestration = OrchestrationStatus(
            enabled: false, pendingToken: "tok-1234", pendingTarget: 85,
            lastApplied: 80, lastError: nil
        )
        let round = DaemonXPC.encodeStatus(status).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(round == status && round?.orchestration == status.orchestration,
              "编排-14", "orchestration 载荷 round-trip 全字段保留（wire 零 schema 变化——pending 四键兼容照容）")
        var failure = DaemonStatus(version: "t", mode: "active", upperLimit: 85, hysteresis: 2)
        failure.orchestration = OrchestrationStatus(
            enabled: false, pendingToken: nil, pendingTarget: nil,
            lastApplied: 85, lastError: "原生限充 set 通道不可用（PowerUISmartChargeClient 类缺席）"
        )
        let failureRound = DaemonXPC.encodeStatus(failure).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(failureRound?.orchestration?.lastError == "原生限充 set 通道不可用（PowerUISmartChargeClient 类缺席）",
              "编排-14", "lastError 形态 round-trip（旧 daemon 失败回报详情兼容）")
    }
    // 编排-15（迁移）：旧 daemon 回包无 orchestration 键 → 解码 nil（升级窗口双向兼容）。
    do {
        let legacyJSON = #"{"version":"0.19.11-alpha","mode":"active","upperLimit":80,"hysteresis":2,"timestamp":123.0}"#
        let legacy = try? JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        check(legacy?.orchestration == nil && legacy?.upperLimit == 80,
              "编排-15", "旧 daemon JSON（无 orchestration 键）→ 解码 nil 且既有字段照常（decodeIfPresent）")
        let partialJSON = #"{"version":"t","mode":"active","upperLimit":80,"hysteresis":2,"orchestration":{"enabled":true},"timestamp":123.0}"#
        let partial = try? JSONDecoder().decode(DaemonStatus.self, from: Data(partialJSON.utf8))
        check(partial?.orchestration?.enabled == true && partial?.orchestration?.pendingToken == nil,
              "编排-15", "载荷子键缺席 → 子键 nil、enabled 照常（合成 Codable decodeIfPresent——旧 daemon 非 nil 值照容）")
    }
    // 编排-16（迁移）：wire 值域矩阵（XPCServer 臂 / validateRequest 同源常量）。
    do {
        check(OrchestrationWireKeys.validEnabled(0) && OrchestrationWireKeys.validEnabled(1)
                  && !OrchestrationWireKeys.validEnabled(2),
              "编排-16", "开关值域 0/1（键型照既有开关统一）")
        check(!OrchestrationWireKeys.validToken("")
                  && OrchestrationWireKeys.validToken(String(repeating: "a", count: 64))
                  && !OrchestrationWireKeys.validToken(String(repeating: "a", count: 65)),
              "编排-16", "token 非空且 ≤64 字节边界")
        check(OrchestrationWireKeys.validDetail(String(repeating: "a", count: 8192))
                  && !OrchestrationWireKeys.validDetail(String(repeating: "a", count: 8193)),
              "编排-16", "detail ≤8192 字节边界（照 scheduleJson 上限先例）")
        check(OrchestrationWireKeys.command == "setOrchestration"
                  && OrchestrationWireKeys.reportCommand == "reportOrchestration",
              "编排-16", "命令字面量钉死（XPCServer 臂 / DaemonXPCClient 同源——旧 App 混装窗兼容命令族保留）")
    }
    // 编排-18（迁移）：makeMessage 编排键组构造（开关单键 + 回报三键；detail 缺席不发键）。
    do {
        let enableMsg = DaemonXPC.makeMessage(
            cmd: OrchestrationWireKeys.command, upper: 0, hysteresis: 0, orchestrationEnabled: 1
        )
        let enableParsed = DaemonXPC.validateRequest(enableMsg)
        check(enableParsed?.orchestrationEnabled == 1 && enableParsed?.orchestrationReport == nil,
              "编排-18", "setOrchestration 消息 → orchestrationEnabled=1 提取、report nil")
        let reportMsg = DaemonXPC.makeMessage(
            cmd: OrchestrationWireKeys.reportCommand, upper: 0, hysteresis: 0,
            orchestrationReport: OrchestrationReportWire(token: "tok-1", ok: 0, detail: "执行失败")
        )
        let reportParsed = DaemonXPC.validateRequest(reportMsg)
        check(reportParsed?.orchestrationEnabled == nil
                  && reportParsed?.orchestrationReport == OrchestrationReportWire(token: "tok-1", ok: 0, detail: "执行失败"),
              "编排-18", "reportOrchestration 消息 → 三键 wire 提取（ok=false + detail）")
        let okNoDetail = DaemonXPC.makeMessage(
            cmd: OrchestrationWireKeys.reportCommand, upper: 0, hysteresis: 0,
            orchestrationReport: OrchestrationReportWire(token: "tok-2", ok: 1, detail: nil)
        )
        let okParsed = DaemonXPC.validateRequest(okNoDetail)
        check(okParsed?.orchestrationReport?.detail == nil
                  && okParsed?.orchestrationReport?.ok == 1,
              "编排-18", "ok=true 无 detail → detail 键不发（缺席即「无详情」语义）")
    }
    // 编排-19（迁移）：validateRequest 类型白名单——STRING 混入开关节 / token 超长 /
    // detail 超长 → 整包拒绝；既有命令无编排键 → 双字段 nil 兼容。
    do {
        func baseMessage(_ cmd: String) -> xpc_object_t {
            let msg = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(msg, DaemonXPC.cmdKey, cmd)
            xpc_dictionary_set_uint64(msg, DaemonXPC.upperKey, 0)
            xpc_dictionary_set_uint64(msg, DaemonXPC.hysteresisKey, 0)
            return msg
        }
        let mixed = baseMessage(OrchestrationWireKeys.command)
        xpc_dictionary_set_string(mixed, OrchestrationWireKeys.enabled, "1")   // STRING 混入 UINT64 键
        check(DaemonXPC.validateRequest(mixed) == nil,
              "编排-19", "开关键以 STRING 混入 → 整包拒绝（不崩溃，照 auto 同纪律）")
        let longToken = baseMessage(OrchestrationWireKeys.reportCommand)
        xpc_dictionary_set_string(longToken, OrchestrationWireKeys.token, String(repeating: "a", count: 65))
        check(DaemonXPC.validateRequest(longToken) == nil,
              "编排-19", "token 超 64 字节 → 整包拒绝")
        let longDetail = baseMessage(OrchestrationWireKeys.reportCommand)
        xpc_dictionary_set_string(longDetail, OrchestrationWireKeys.token, "tok")
        xpc_dictionary_set_string(longDetail, OrchestrationWireKeys.detail, String(repeating: "a", count: 8193))
        check(DaemonXPC.validateRequest(longDetail) == nil,
              "编排-19", "detail 超 8192 字节 → 整包拒绝（照 scheduleJson 同纪律）")
        let plain = baseMessage("setLimits")
        let plainParsed = DaemonXPC.validateRequest(plain)
        check(plainParsed?.orchestrationEnabled == nil && plainParsed?.orchestrationReport == nil,
              "编排-19", "既有命令无编排键 → 编排字段 nil（天然兼容）")
    }
}
