// CellarCoreCheck —— 0.23.1「编排退役」结构钉面场景域（方案 §3 新增清单）
//
// 覆盖清单（红队终签钉面；源文件结构断言 = 机械门，照 CellarUICheck l10n 门禁
// 读 catalog 同款 #filePath 仓库根推导先例）：
// ① 冻结偏好零消费断言（§0.9）：决策消费面文件全库 grep `orchestrationEnabled`
//    = 0——命中仅允许落在 policy 解码/镜像/照填面（DaemonPolicy 定义与
//    DaemonCore 三构造点透传 / setOrchestrationEnabled 照写 / 日程转移落地段透传）；
// ② observationTick 迁移钉（R2/R3 裁决——27 执法引擎不丢）：DaemonCore+Orchestration.
//    swift 的 observationTickLocked 保留「①日程转移 + ②汇聚点路由消费」两臂、
//    ③断言签发臂（assertionRequest/pendingToken 签发）结构性消失；DaemonCore.swift
//    挂点保留（modernBackendTerminalLocked 门内调用）；
// ③ fullOnce/cancelAction 置窗-清窗-only 化钉（R4/复核 P3——pending 产出臂删除，
//    编译强制由 OrchestrationState 五字段删除承担，本钉防回填）；
// ④ restoreChargeLimit 重写钉（R5）+ Schedule:101 断电簿记臂保留钉（R1——
//    modernBackendTerminalLocked 更名非删除，27 夜窗簿记零回归）；
// ⑤ wire 兼容照填钉（R6/验收 3）：orchestrationStatusLocked 硬编码 false 数据源、
//    reportOrchestration token 幂等 no-op、XPCServer setOrchestration/report 命令臂
//    保留（旧 App 混装窗兼容）。
//
// 全部源文件读取（Data 注入仓库相对路径），不触碰真实 plist、不起 daemon。

import CellarCore
import Foundation

/// 0.23.1 编排退役结构钉面域入口（Main.main 调用）。
func runOrchestrationRetirementDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 源文件缺席 = 钉面失效（checkout 残缺/文件被改名）——fail 红而非静默绿。
            check(false, "退役-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    let orchestrationExt = source("Sources/cellar-daemon/DaemonCore+Orchestration.swift")
    let daemonCore = source("Sources/cellar-daemon/DaemonCore.swift")
    let oneShotExt = source("Sources/cellar-daemon/DaemonCore+OneShot.swift")
    let scheduleExt = source("Sources/cellar-daemon/DaemonCore+Schedule.swift")
    let topoffExt = source("Sources/cellar-daemon/DaemonCore+Topoff.swift")
    let topoffCore = source("Sources/CellarCore/Daemon/Topoff.swift")
    let limitSetCore = source("Sources/CellarCore/Daemon/NativeLimitSet.swift")
    let oneShotCore = source("Sources/CellarCore/Daemon/OneShot.swift")
    let statusController = source("App/CellarApp/StatusController.swift")
    let limitExecution = source("App/CellarApp/StatusController+LimitExecution.swift")

    // ---- ① 冻结偏好零消费断言（§0.9 验收 2）----

    // 退役-1a：决策消费面文件 orchestrationEnabled 命中 = 0（原真值表/路由/期望表/
    // 静默门/fullOnce 前置/App 执行链七类消费点全部退役——命中即回填）。
    let decisionConsumers: [(String, String)] = [
        ("CellarCore.Topoff", topoffCore),
        ("CellarCore.NativeLimitSet", limitSetCore),
        ("CellarCore.OneShot", oneShotCore),
        ("daemon.DaemonCore+OneShot", oneShotExt),
        ("daemon.DaemonCore+Topoff", topoffExt),
        ("App.StatusController", statusController),
        ("App.StatusController+LimitExecution", limitExecution),
    ]
    for (name, text) in decisionConsumers {
        check(!text.contains("orchestrationEnabled"), "退役-1",
              "\(name) 无 orchestrationEnabled 命中（冻结偏好零消费断言——决策消费面 = 0）")
    }

    // 退役-1b：照填面文件（DaemonCore 主文件三构造点透传 / Schedule 日程转移落地段
    // 透传）命中仅允许 F-1 显式字段拷贝形态（`orchestrationEnabled: policy.…`）——
    // 决策判据形态（== 比较 / if / guard / 取反）结构性禁止。
    let passThroughFaces: [(String, String)] = [
        ("daemon.DaemonCore", daemonCore),
        ("daemon.DaemonCore+Schedule", scheduleExt),
    ]
    let decisionPatterns = ["orchestrationEnabled ==", "orchestrationEnabled !=",
                            "!orchestrationEnabled", "if orchestrationEnabled",
                            "guard orchestrationEnabled"]
    for (name, text) in passThroughFaces {
        let illegal = decisionPatterns.filter { text.contains($0) }
        check(illegal.isEmpty, "退役-1",
              "\(name) 照填面无决策判据形态（命中仅 F-1 显式字段拷贝——非法形态 \(illegal.isEmpty ? "无" : illegal.joined(separator: "/"))）")
    }

    // ---- ② observationTick 迁移钉（27 执法引擎不丢）----

    // 退役-2a：observationTickLocked 两臂齐备（①日程转移 ②汇聚点路由消费）。
    check(orchestrationExt.contains("func observationTickLocked(")
              && orchestrationExt.contains("applyScheduleTransitionLocked(")
              && orchestrationExt.contains("topoffConvergenceRouteLocked("),
          "退役-2", "observationTickLocked 迁移钉：日程转移 + 汇聚点路由消费两臂齐备（R2——27 执法引擎新家，断言签发臂删除）")
    // 退役-2b：断言签发面结构性消失（真值表/pendingToken 签发不回填）。
    check(!orchestrationExt.contains("assertionRequest")
              && !orchestrationExt.contains("pendingToken ="),
          "退役-2", "断言签发臂退役钉：orchestrationTickLocked ③ 臂（assertionRequest/pendingToken 签发）不回填")
    // 退役-2c：DaemonCore 挂点保留（原 :836——门换 modernBackendTerminalLocked）。
    check(daemonCore.contains("if modernBackendTerminalLocked, let snapshot {")
              && daemonCore.contains("observationTickLocked(now: Date(), snapshot: snapshot, events: &events)"),
          "退役-2", "观测 tick 挂点保留钉：performTickLocked 后端缺席分支 modernBackendTerminalLocked 门内照常驱动（27 执法引擎断驱动不丢）")
    // 退役-2d：更名钉——orchestrationTerminalLocked 旧名零残留（6 消费点全部换
    // modernBackendTerminalLocked，行为零变化）。
    check(!daemonCore.contains("orchestrationTerminalLocked")
              && !oneShotExt.contains("orchestrationTerminalLocked")
              && !scheduleExt.contains("orchestrationTerminalLocked")
              && daemonCore.contains("var modernBackendTerminalLocked: Bool"),
          "退役-2", "平台判别更名钉：orchestrationTerminalLocked → modernBackendTerminalLocked（R7——6 消费点统一更名零残留）")

    // ---- ③ fullOnce / cancelAction 置窗-清窗-only 化钉 ----

    // 退役-3：27 置窗臂 = 置窗 + 即时 tick（无 pending 产出）；cancelAction = 清窗 +
    // 即时 tick（无恢复 pending 产出）。
    check(oneShotExt.contains("fullOnceWindowActive = true")
              && !oneShotExt.contains("pendingToken =")
              && !oneShotExt.contains("pendingTarget ="),
          "退役-3", "fullOnce 27 置窗-only 化钉：置窗 + 即时 tick，pending 产出臂不回填（R4/复核 P3——App 消费链已删除）")
    check(oneShotExt.contains("fullOnceWindowActive = false")
              && oneShotExt.contains("modernBackendTerminalLocked"),
          "退役-3", "cancelAction 27 清窗-only 化钉：清窗 + 即时 tick 域写回 target（恢复臂同款收敛）+ 平台判别门更名")

    // ---- ④ restoreChargeLimit 重写钉 + Schedule 断电簿记臂保留钉 ----

    // 退役-4a：恢复臂重写形态（清窗 + 清锁存 + 即时 tick；无开关前置拒收/无 pending）。
    check(orchestrationExt.contains("func restoreChargeLimit() -> DaemonStatus")
              && orchestrationExt.contains("clearUserActionLatch()")
              && !orchestrationExt.contains("orchestrationSwitchOff")
              && !orchestrationExt.contains("pendingToken ="),
          "退役-4", "restoreChargeLimit 重写钉（R5）：清窗 + 清锁存 + 即时 tick 域写 target——开关前置拒收与 pending 产出删除")
    // 退役-4b：Schedule:101 = 27 日程断电簿记臂保留（R1——保留更名勿删，删除即
    // 27 夜窗「放开窗口」静默失效回归）。
    check(scheduleExt.contains("if modernBackendTerminalLocked {")
              && scheduleExt.contains("applied = true"),
          "退役-4", "Schedule 断电簿记臂保留钉（R1）：27 终态 chargingDisabled 转移 = 纯簿记进入臂（锚点写入 + 跳过 SMC 写）——更名非删除")

    // ---- ⑤ wire 兼容照填钉（验收 3）----

    // 退役-5：恒填面（enabled 硬编码 false 数据源 + 两窗沿更名门恒填 + XPC 命令臂
    // 保留 + 回报 no-op）。
    check(orchestrationExt.contains("OrchestrationStatus(enabled: false)")
              && daemonCore.contains("status.fullOnceWindowActive = fullOnceWindowActive")
              && daemonCore.contains("status.chargingDisabledWindowActive = chargingDisabledWindowActiveLocked")
              && daemonCore.contains("if modernBackendTerminalLocked {"),
          "退役-5", "wire 恒填钉：orchestration.enabled 硬编码 false 数据源 + 两窗沿 modernBackendTerminal 门恒填（wire 零 schema 变化）")
    check(orchestrationExt.contains("func reportOrchestration(token: String, ok: Bool, detail: String?) -> DaemonStatus")
              && orchestrationExt.contains("func setOrchestrationEnabled(_ enabled: Bool) -> DaemonStatus"),
          "退役-5", "XPC 命令族保留钉：setOrchestration（冻结偏好照写）+ reportOrchestration（token 幂等日志 no-op）——旧 App 混装窗兼容")

    // ---- ⑥ 冻结偏好镜像保真钉（policy 字段保留 = 纯镜像面）----

    // 退役-6（自原 OrchestrationDomain 编排-11/12 迁入）：orchestrationEnabled 字段
    // 保留为**冻结偏好镜像**——落盘读回保真 + 旧 JSON 无键 nil 兼容（零决策消费由
    // 退役-1 钉死；两钉合取 = 「仅 policy 镜像+照填面」验收语义的机械化）。
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cellar-retire-f1-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PolicyStore(url: directory.appendingPathComponent("policy.json"))
        try? store.save(DaemonPolicy(
            mode: "active", upperLimit: 85, hysteresis: 2, orchestrationEnabled: true))
        check(store.load()?.orchestrationEnabled == true,
              "退役-6", "冻结偏好镜像保真：orchestrationEnabled=true 落盘读回一致（policy 解码/镜像面保留）")
        let url = directory.appendingPathComponent("legacy.json")
        try? #"{"mode":"active","upperLimit":75,"hysteresis":3}"#
            .write(to: url, atomically: true, encoding: .utf8)
        check(PolicyStore(url: url).load()?.orchestrationEnabled == nil,
              "退役-6", "旧 policy.json 无键 → nil（decodeIfPresent 兼容——0.19.19 形态零回归）")
    }
}
