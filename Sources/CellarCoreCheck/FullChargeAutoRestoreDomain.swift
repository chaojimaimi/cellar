// CellarCoreCheck —— 0.23.2「充满自动恢复与校准 27 适配批」场景域（方案 §6）
//
// 按域拆独立文件（照 OrchestrationRetirementDomain 源钉先例；纯函数 + 源码钉面）。
// 覆盖清单（方案 §6 逐条，每条注明机制：纯函数 / 源码钉面）：
// ① 充满检测纯函数 ≥6（isCharging 门 / fullyCharged 优先 / nil+99 兜底 / 外接清零 /
//    去抖 2→3 / 复位与常量同源——FullChargeDomain.swift 纯函数面）；
// ② fullOnce 自动恢复源钉（挂点位置 / helper 四件套清面 / 清窗点走 helper / 26 动作轨
//    零触及 / 字面量复用映射回归——映射本体回归 MainEntry 用例 102 既有场景）；
// ③ 校准 27 适配源钉（能力矩阵源钉 + 互斥 ≥3 / advance 27 臂 ≥3 / maintain 相位副作用
//    ≥4 / 调度臂挂点 / .maintainCalibration 路由钉面〔DischargeDomain 真值表补行〕/
//    守卫 27 绕过 + 26 逐值）。
//
// 全部源文件读取（Data 注入仓库相对路径），不触碰真实 plist、不起 daemon。

import CellarCore
import Foundation

/// 0.23.2 批场景域入口（Main.main 调用）。
func runFullChargeAutoRestoreDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 源文件缺席 = 钉面失效（checkout 残缺/文件被改名）——fail 红而非静默绿。
            check(false, "窗钉-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    let detectionCore = source("Sources/CellarCore/Daemon/FullChargeDetection.swift")
    let oneShotCore = source("Sources/CellarCore/Daemon/OneShot.swift")
    let orchestrationExt = source("Sources/cellar-daemon/DaemonCore+Orchestration.swift")
    let daemonCore = source("Sources/cellar-daemon/DaemonCore.swift")
    let oneShotExt = source("Sources/cellar-daemon/DaemonCore+OneShot.swift")
    let calibrationExt = source("Sources/cellar-daemon/DaemonCore+Calibration.swift")
    let runtimeProbeCore = source("Sources/CellarCore/Control/RuntimeProbe.swift")
    let t0 = Date(timeIntervalSince1970: 0)

    // ---- ① 充满检测纯函数（方案 §2/§6——FullChargeDetection）----

    // 检测-1：isCharging 门（谓词复用 OneShot.isFullOnceComplete——充电中恒未完成）。
    check(!FullChargeDetection.predicate(
        isCharging: true, fullyCharged: true, percent: 100, externalConnected: true),
          "检测-1", "isCharging 门：充电中 + fullyCharged=true → 未完成（OneShot.isFullOnceComplete 单一真相）")
    check(!FullChargeDetection.tick(
        isCharging: true, fullyCharged: true, percent: 100,
        externalConnected: true, consecutive: FullChargeDetection.debounceTicks - 1),
          "检测-1", "isCharging 门经 tick 同样成立（去抖满足拍亦不越过充电门）")

    // 检测-2：fullyCharged 优先（true → 完成与 percent 无关；false → 恒不成立）。
    check(FullChargeDetection.predicate(
        isCharging: false, fullyCharged: true, percent: 80, externalConnected: true),
          "检测-2", "fullyCharged=true + !isCharging → 完成（percent 不参与——主判据优先）")
    check(!FullChargeDetection.predicate(
        isCharging: false, fullyCharged: false, percent: 100, externalConnected: true),
          "检测-2", "fullyCharged=false（键在位且为 No）→ 恒未完成（降级不覆盖 false）")

    // 检测-3：nil + 99 兜底（FullyCharged 键缺/类型不符 → ≥99 降级）。
    check(FullChargeDetection.predicate(
        isCharging: false, fullyCharged: nil, percent: 99, externalConnected: true),
          "检测-3", "fullyCharged=nil + percent=99 → 完成（≥99 降级边界含 99）")
    check(!FullChargeDetection.predicate(
        isCharging: false, fullyCharged: nil, percent: 98, externalConnected: true),
          "检测-3", "fullyCharged=nil + percent=98 → 未完成（降级仅覆盖 nil）")

    // 检测-4：外接缺席清零（拔电拍不构成充满证据——谓词 false → 调用方清零）。
    check(!FullChargeDetection.predicate(
        isCharging: false, fullyCharged: true, percent: 100, externalConnected: false),
          "检测-4", "外接缺席 → 谓词 false（调用方清零——中断归零语义）")
    check(!FullChargeDetection.tick(
        isCharging: false, fullyCharged: true, percent: 100,
        externalConnected: false, consecutive: FullChargeDetection.debounceTicks - 1),
          "检测-4", "外接缺席经 tick → false（去抖不越过外接门）")

    // 检测-5：去抖 2→3（第 3 个连续命中拍才触发——窗模式专用 3 拍，26 动作轨 2 拍
    // 独立演化）。
    check(!FullChargeDetection.tick(
        isCharging: false, fullyCharged: true, percent: 100,
        externalConnected: true, consecutive: 0),
          "检测-5", "consecutive=0（第 1 拍命中）→ 未达标")
    check(!FullChargeDetection.tick(
        isCharging: false, fullyCharged: true, percent: 100,
        externalConnected: true, consecutive: 1),
          "检测-5", "consecutive=1（第 2 拍命中）→ 未达标")
    check(FullChargeDetection.tick(
        isCharging: false, fullyCharged: true, percent: 100,
        externalConnected: true, consecutive: 2),
          "检测-5", "consecutive=2（第 3 拍命中）→ 达标（自动恢复触发面）")

    // 检测-6：复位与常量同源（未命中即复位由调用方执行——纯函数 false 即复位信号；
    // debounceTicks=3 与 26 轨 2 独立；fullOnceWindowTimeout 别名同源 4h 勿字面量）。
    check(FullChargeDetection.debounceTicks == 3 && OneShot.fullOnceDebounceTicks == 2,
          "检测-6", "窗模式去抖 3 拍 ∧ 26 动作轨 2 拍（两通道独立演化，互不引用）")
    check(FullChargeDetection.fullOnceWindowTimeout == OneShot.fullOnceTimeout,
          "检测-6", "窗超时别名同源 OneShot.fullOnceTimeout（4h——勿字面量，方案 §1.8）")
    check(FullChargeDetection.fullOnceWindowTimeout == 4 * 3600,
          "检测-6", "窗超时 = 4h（26 fullOnce 超时对齐——v1 6h 系笔误的裁决落字）")
    check(detectionCore.contains("OneShot.isFullOnceComplete(")
              && !detectionCore.contains("percent >= 99"),
          "检测-6", "谓词复用钉面：FullChargeDetection 调用 OneShot.isFullOnceComplete、无内联 ≥99 判定复制（单一真相勿复制逻辑）")

    // ---- ② fullOnce 自动恢复源钉（方案 §3——挂点/helper/清窗点/26 零触及）----

    // 窗钉-1：挂点位置（observationTickLocked 头部——日程转移后、topoff 路由前；
    // 红 R2 钉死：清窗后同拍汇聚路由收敛，防嵌套 tick）。
    do {
        if let head = orchestrationExt.range(of: "func observationTickLocked("),
           let tail = orchestrationExt.range(of: "// MARK: - setOrchestration XPC") {
            let body = String(orchestrationExt[head.lowerBound..<tail.lowerBound])
            let scheduleAt = body.range(of: "applyScheduleTransitionLocked(")
            let windowAt = body.range(of: "FullChargeDetection.tick(")
            let routeAt = body.range(of: "topoffConvergenceRouteLocked(now: now, snapshot: snapshot, events: &events)")
            // 安全解包（code-review P3：前序 check 不短路——重构致钉面文本缺席时
            // 红报告而非进程 crash；校27-1 同款形态）。
            if let scheduleAt, let windowAt, let routeAt {
                check(scheduleAt.lowerBound < windowAt.lowerBound
                          && windowAt.lowerBound < routeAt.lowerBound,
                      "窗钉-1", "挂点次序钉死：日程转移 → fullOnce 窗自动恢复（FullChargeDetection.tick）→ topoff 路由消费（方案 §3——topoff 路由前、日程转移后）")
            } else {
                check(false, "窗钉-1", "挂点次序钉死：三个锚点文本须全部在位（某锚点缺席 = 钉面红）")
            }
            check(body.contains("} else if fullOnceFullTicks != 0 {")
                      && body.contains("fullOnceFullTicks = 0"),
                  "窗钉-1", "窗口非活跃拍清计数器在位（红 R6 单一谓词点——五处清窗点免疫跨窗泄漏）")
            check(body.contains("FullChargeDetection.fullOnceWindowTimeout"),
                  "窗钉-1", "超时判定别名同源（无 4h 字面量——与 26 fullOnce 超时同源勿字面量）")
        } else {
            check(false, "窗钉-1", "observationTickLocked 区段定位失败")
        }
    }

    // 窗钉-2：helper 四件套清面（窗标志 + startedAt + 计数器 + 共存识别态）+ 字面量
    // 两臂 + **零 tick 零域写**（红 R2——helper 只清状态）。
    do {
        if let head = oneShotExt.range(of: "func clearFullOnceWindowStateLocked("),
           let tail = oneShotExt.range(of: "/// fullOnce XPC") {
            let body = String(oneShotExt[head.lowerBound..<tail.lowerBound])
            check(body.contains("fullOnceWindowActive = false")
                      && body.contains("fullOnceWindowStartedAt = nil")
                      && body.contains("fullOnceFullTicks = 0")
                      && body.contains("calibrationCoexistenceState = CalibrationCoexistence.State.empty"),
                  "窗钉-2", "helper 四件套清面：窗标志 + startedAt + 充满计数器 + calibrationCoexistenceState（§1.4 兼修——suspected 清零防吞恢复拍域写）")
            check(body.contains("case .full:") && body.contains("latchTerminalLiteral(OneShotLiteral.done())")
                      && body.contains("case .timeout:") && body.contains("latchTerminalLiteral(OneShotLiteral.timeout())"),
                  "窗钉-2", "字面量复用钉面：.full → fullOnce:done / .timeout → fullOnce:timeout（§1.6——notificationEvents 与 App 横幅映射全现成零新增；映射回归 MainEntry 用例 102）")
            check(body.contains("case .manual:")
                      && !(body.range(of: "case .manual:").map { r in body[r.lowerBound...].contains("latchTerminalLiteral") } == true),
                  "窗钉-2", "手动清窗臂不落字面量（用户即时反馈路径——XPC 本就无终态语义；.full/.timeout 两臂锁存）")
            check(!body.contains("performTickLocked") && !body.contains("topoffExecuteWriteLocked"),
                  "窗钉-2", "helper 零 tick 零域写（红 R2 钉死——域写交同拍/外层汇聚路由收敛，防嵌套 tick）")
        } else {
            check(false, "窗钉-2", "clearFullOnceWindowStateLocked 区段定位失败")
        }
    }

    // 窗钉-3：三清窗点走 helper（setLimits/disable/SIGHUP——DaemonCore.swift 三处；
    // cancelAction 在 oneShotExt、restoreChargeLimit 在 orchestrationExt——退役-3 补钉）。
    do {
        let manualClears = daemonCore.components(separatedBy: "clearFullOnceWindowStateLocked(").count - 1
        check(manualClears == 3,
              "窗钉-3", "DaemonCore.swift 三清窗点（setLimits/disable/SIGHUP）全部走 helper（\(manualClears) 处——直写 fullOnceWindowActive = false 收口）")
        let strayWrites = daemonCore.components(separatedBy: "\n").filter {
            $0.contains("fullOnceWindowActive = false") && !$0.contains("var fullOnceWindowActive")
        }
        check(strayWrites.isEmpty,
              "窗钉-3", "DaemonCore.swift 无窗标志直写残留（\(strayWrites.count) 处——唯一声明初值行除外，清窗面单一出口 = helper）")
        check(oneShotExt.contains("clearFullOnceWindowStateLocked(")
                  && orchestrationExt.contains("clearFullOnceWindowStateLocked("),
              "窗钉-3", "cancelAction（oneShotExt）∧ restoreChargeLimit（orchestrationExt）清窗走 helper（含 0.23.1 手动恢复 suspected 潜伏缺陷兼修）")
    }

    // 窗钉-4：26 动作轨零触及（fullOnceTimeout 26 路径不变——动作轨完成/超时恢复链
    // 逐行原样；27 自动恢复不触碰动作轨）。
    check(oneShotExt.contains("func maintainActionLocked(")
              && oneShotExt.contains("restoreLimitChargingLocked(backend: backend, terminal: \"完成\", events: &events)")
              && oneShotExt.contains("restoreLimitChargingLocked(backend: backend, terminal: \"超时\", events: &events)")
              && oneShotExt.contains("actionTrack.tick(now: now, fullyCharged: fullyCharged, isCharging: isCharging, percent: percent)"),
          "窗钉-4", "26 动作轨零触及：maintainActionLocked 完成判据 tick + 终态恢复链逐行原样（fullOnceTimeout 26 路径不变——红线）")
    check(oneShotExt.contains("fullOnceWindowStartedAt = Date()")
              && oneShotExt.contains("fullOnceFullTicks = 0"),
          "窗钉-4", "27 置窗臂窗口态三件齐备：窗标志 + startedAt + 计数器归零（自动恢复窗口态随窗置位）")
    check(oneShotExt.contains("throw OneShotStartRejection.actionOccupiedOn27")
              && oneShotExt.contains("回当前状态（幂等）"),
          "窗钉-4", "幂等拆分钉面：27 在轨动作 → .actionOccupiedOn27 新拒因；26 → 静默幂等返回不动（§1.5——26 对在轨动作非拒绝）")

    // ---- ③ 校准 27 适配源钉（方案 §4——守卫绕过/互斥/启动序列/maintain/advance/调度臂）----

    // 校27-1：能力矩阵源钉（writable 臂含 calibration / 无 CHIE 臂与 26 成功路径不变
    // ——纯函数面回归 HealthCapabilitiesDomain 能力-6）。
    do {
        if let head = runtimeProbeCore.range(of: "public static func noBackendTerminalDisposition(") {
            let body = String(runtimeProbeCore[head.lowerBound...])
            let chieArm = body.range(of: "if chieWritable {")
            let elseArm = body.range(of: "} else {")
            guard let chieArm, let elseArm else {
                check(false, "校27-1", "noBackendTerminalDisposition 两臂锚点须在位")
                return
            }
            check(chieArm.lowerBound < elseArm.lowerBound,
                  "校27-1", "noBackendTerminalDisposition 两臂定位成功")
            do {
                let writableBody = String(body[chieArm.upperBound..<elseArm.lowerBound])
                let restBody = String(body[elseArm.upperBound...])
                check(writableBody.contains("DaemonXPC.capabilityCalibration"),
                      "校27-1", "CHIE 可写臂含 capabilityCalibration（0.23.2 校准能力解禁——App 校准按钮/调度卡数据驱动放行）")
                check(!restBody.contains("DaemonXPC.capabilityCalibration"),
                      "校27-1", "无 CHIE 臂不含 calibration（守卫绕过不越权——无放电面即无校准 discharge 相）")
            }
        } else {
            check(false, "校27-1", "noBackendTerminalDisposition 区段定位失败")
        }
    }

    // 校27-2：互斥三钉（fullOnce 侧 .actionOccupiedOn27 / 校准侧 .fullOnceActive /
    // 双向拒因文案——纯函数面回归 CalibrationDomain 校准-34a）。
    check(oneShotExt.contains("throw OneShotStartRejection.actionOccupiedOn27"),
          "校27-2", "互斥①：fullOnce() 幂等拆分 27 臂 → .actionOccupiedOn27（在轨放电/校准显式拒绝）")
    check(calibrationExt.contains("if fullOnceWindowActive {")
              && calibrationExt.contains("throw CalibrationStartRejection.fullOnceActive"),
          "校27-2", "互斥②：startCalibrationLocked 幂等拆分后 → .fullOnceActive（窗活跃校准拒绝）")
    check(calibrationExt.contains("nativeChargeLimit(socLimit:") == false
              || calibrationExt.contains("throw CalibrationStartRejection.nativeChargeLimit(socLimit: nativeReading.manualSocLimit)"),
          "校27-2", "互斥③回归锚：26 原生守卫拒因仍在位（.nativeChargeLimit——26 守卫逐值不变的载体之一）")

    // 校27-3：advance 27 臂三钉（②撤停充 27 跳过 / ③CHIE 经 DischargeAdapterControl /
    // 失败相位不推进——方案 §4.3 源码钉）。
    do {
        if let head = calibrationExt.range(of: "private func advanceCalibrationLocked(") {
            let body = String(calibrationExt[head.lowerBound...])
            check(body.contains("校准相位推进（27）：跳过 CHTE 撤停充"),
                  "校27-3", "advance ②：27 跳过撤停充（backend nil——CHTE 键族缺席，dischargeToLimitLocked 27 跳过先例）")
            check(body.contains("DischargeAdapterControl.setAdapterEnabled(false, client: client)")
                      && body.contains("DischargeAdapterControl.adapterState(client: client)"),
                  "校27-3", "advance ③：27 CHIE=0x8 写 + 回读经 DischargeAdapterControl client 直挂（maintainDischarge 27 同款）")
            check(body.contains("client 缺席——不写 CHIE、相位不推进"),
                  "校27-3", "advance 失败臂：27 client 缺席/写失败 → 相位不推进（return false——下 tick 幂等重试全序列）")
        } else {
            check(false, "校27-3", "advanceCalibrationLocked 区段定位失败")
        }
    }

    // 校27-4：maintain 相位副作用四钉（chargeFull 27 无保活 / hold 零写 / discharge
    // CHIE client 读改写 / restore·abort 域写 target——方案 §4.3 源码钉）。
    do {
        if let head = calibrationExt.range(of: "func maintainCalibrationLocked(") {
            let body = String(calibrationExt[head.lowerBound...])
            check(body.contains("if let backend {\n                    keepAliveChargingLocked(")
                      && body.contains("if let backend {\n                    holdLimitChargingLocked("),
                  "校27-4", "stay 相位副作用 26 包裹钉：chargeFull CHTE 保活 / hold 停充维持均经 if let backend（27 无 CHTE/CH0B 键族 → 零写浮充——FAQ 语义差异登记）")
            check(body.contains("DischargeAdapterControl.adapterState(client: client)")
                      && body.contains("DischargeAdapterControl.setAdapterEnabled(false, client: client)"),
                  "校27-4", "discharge 相：27 CHIE 保活读改写/回读经 DischargeAdapterControl（maintainDischargeLocked 27 同款——失败 noteControlFailureLocked 自愈计数）")
            check(body.components(separatedBy: "topoffExecuteWriteLocked(limit: policy.upperLimit, now: now, events: &events)").count - 1 >= 2,
                  "校27-4", "restoreAndComplete/abort 双臂：27 域直写 target（topoffExecuteWriteLocked 簿记包装——lastWrittenLimit 回填消盲窗）")
            check(body.contains("enforceLimitChargingLocked(backend: backend, temperatureC: snapshot.temperatureC, events: &events)"),
                  "校27-4", "restoreAndComplete/abort 26 臂：enforceLimitChargingLocked 逐行原样（26 红线——恢复限充语义走 CHTE）")
        } else {
            check(false, "校27-4", "maintainCalibrationLocked 区段定位失败")
        }
    }

    // 校27-5：调度臂挂点（observationTickLocked 内、日程转移后 topoff 路由前——
    // calibrationAutoStartReady → startCalibrationLocked(.auto)；拒因照 26 调度臂）。
    do {
        if let head = orchestrationExt.range(of: "func observationTickLocked("),
           let tail = orchestrationExt.range(of: "// MARK: - setOrchestration XPC") {
            let body = String(orchestrationExt[head.lowerBound..<tail.lowerBound])
            let scheduleAt = body.range(of: "applyScheduleTransitionLocked(")
            let armAt = body.range(of: "calibrationAutoStartReady(")
            let startAt = body.range(of: "startCalibrationLocked(\n                    initiator: .auto")
            let routeAt = body.range(of: "topoffConvergenceRouteLocked(now: now, snapshot: snapshot, events: &events)")
            // 安全解包（code-review P3——窗钉-1 同款形态）。
            if let scheduleAt, let armAt, let startAt, let routeAt {
                check(armAt.lowerBound < routeAt.lowerBound
                          && scheduleAt.lowerBound < armAt.lowerBound,
                      "校27-5", "27 调度臂挂点：日程转移后、topoff 路由前（calibrationAutoStartReady → startCalibrationLocked(.auto)——26 执法段调度臂的观测段镜像）")
            } else {
                check(false, "校27-5", "27 调度臂挂点：四个锚点文本须全部在位（某锚点缺席 = 钉面红）")
            }
            check(startAt != nil, "校27-5", "调度臂启动调用在位（startCalibrationLocked(.auto)）")
            check(body.contains("rejection == .persistenceFailed")
                      && body.contains("自动校准启动失败")
                      && body.contains("自动校准未启动"),
                  "校27-5", "调度臂拒因处置照 26：persistenceFailed warn 提级 / 其余 info 静默顺延（同措辞同分级）")
            check(body.contains("backend: nil, client: smcClient"),
                  "校27-5", "调度臂同拍 maintain 接管（26 同判例 R2 P1）——27 传 backend: nil + client: smcClient")
        } else {
            check(false, "校27-5", "observationTickLocked 区段定位失败")
        }
    }

    // 校27-6：.maintainCalibration 路由钉面（daemon 接线——纯函数真值表补行在
    // DischargeDomain 放电-32；观测段消费臂 if let client = smcClient, let snapshot）。
    check(daemonCore.contains("isCalibrationAction: actionTrack.action?.kind == Calibration.kind,")
              && daemonCore.contains("case .maintainCalibration:")
              && daemonCore.contains("maintainCalibrationLocked(\n                        now: Date(), snapshot: snapshot, backend: nil, client: client, events: &events"),
          "校27-6", "观测段路由消费接线：isCalibrationAction 注入 + .maintainCalibration 臂（backend: nil + client 直挂——26 执法段分支传 backend 原样）")
    check(daemonCore.components(separatedBy: "if let client = smcClient, let snapshot {").count - 1 >= 2,
          "校27-6", "观测段防御分支纪律：maintainDischarge/maintainCalibration 两臂同款 if let client = smcClient, let snapshot（client/快照缺席 → 监控缺失计数不静默）")

    // 校27-7：守卫 27 绕过 + 26 逐值（startCalibrationLocked 平台判别臂——照
    // fullOnceStartPrecondition capabilities 先例；26 守卫逐值不变红线）。
    do {
        if let head = calibrationExt.range(of: "let nativeReading = NativeChargeLimit.load("),
           let tail = calibrationExt.range(of: "let now = Date()") {
            let body = String(calibrationExt[head.lowerBound..<tail.lowerBound])
            check(body.contains("if modernBackendTerminalLocked {")
                      && body.contains("原生守卫绕过"),
                  "校27-7", "27 平台判别臂：原生守卫绕过（plist 注册残留非现行上限——M1 同论证域写 100 覆写 MCL；照 fullOnce 27 臂先例）")
            check(body.contains("} else if nativeReading.detectorError {")
                      && body.contains("fail-open 放行")
                      && body.contains("} else if !nativeReading.blockingPolicies.isEmpty {")
                      && body.contains("throw CalibrationStartRejection.nativeChargeLimit(socLimit: nativeReading.manualSocLimit)"),
                  "校27-7", "26 守卫逐值不变：detectorError fail-open warn / blockingPolicies fail-closed 拒绝——两臂原值原语义（红线）")
        } else {
            check(false, "校27-7", "原生守卫区段定位失败")
        }
    }

    // 校27-8：27 启动序列（进相域直写 100 经 topoffExecuteWriteLocked 簿记包装——
    // 写失败 error 日志 + 6h 相位超时兜底；26 无此臂）。
    check(calibrationExt.contains("topoffExecuteWriteLocked(limit: Topoff.shutdownLimit, now: now, events: &events)")
              && calibrationExt.contains("按 6h 相位超时兜底")
              && calibrationExt.contains("if modernBackendTerminalLocked {\n            if topoffExecuteWriteLocked("),
          "校27-8", "27 启动序列：进相域写 100（Topoff.shutdownLimit 同常量先例）经簿记包装——写失败 error 日志 + 6h 相位超时兜底（「静默充电」如实登记）")
    check(oneShotCore.contains("case actionOccupiedOn27")
              && oneShotCore.contains("latchTerminalLiteral"),
          "校27-8", "CellarCore 新面在位：OneShotStartRejection.actionOccupiedOn27 拒因 + OneShotTrack.latchTerminalLiteral 窗终态锁存（批内既有纯函数域回归：校准-34a/用例 102）")
    _ = t0   // 时间基准保留（后续纯函数场景扩展用）
}
