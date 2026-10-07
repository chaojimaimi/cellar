// CellarCoreCheck —— 0.23.3 §4 校准 chargeFull stay 域读回保活（回读门）场景域
//
// 覆盖清单（方案 §4/§6——回读门源码钉 ≥3：回读门在位 / 失配重写路径 / 节流常数）：
// ① 失配判定纯函数（chargeFullReadbackMismatch——100/1 一致 / 值漂 / 态漂 / 键缺席
//    皆失配）；
// ② 节流常数钉面（stride = 10 同源 + reset 置零点）；
// ③ 回读门在位源钉（chargeFull stay 27 分支挂点 / 26 分支零触及——backend 双分支）；
// ④ 失配重写路径源钉（guard 失配 → topoffExecuteWriteLocked(Topoff.shutdownLimit)
//    / 读失败 fail-open 不重写 / hold 相零写不触碰）。
//
// 源码钉面照 FullChargeAutoRestoreDomain 先例（Data 读仓库相对路径，零 plist 零
// daemon 进程）。

import CellarCore
import Foundation

/// 0.23.3 §4 场景域入口（Main.main 调用）。
func runCalibrationReadbackDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 源文件缺席 = 钉面失效（checkout 残缺/文件被改名）——fail 红而非静默绿。
            check(false, "校回-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    let calibrationExt = source("Sources/cellar-daemon/DaemonCore+Calibration.swift")
    let calibrationCore = source("Sources/CellarCore/Daemon/Calibration.swift")
    let daemonCore = source("Sources/cellar-daemon/DaemonCore.swift")

    // ---- ① 失配判定纯函数（Calibration.chargeFullReadbackMismatch）----

    // 校回-1：域 100 ∧ featureState 1 → 一致（零写稳态——启动序列写后的健康读回）。
    check(!Calibration.chargeFullReadbackMismatch(limit: 100, featureState: 1),
          "校回-1", "域 (100, 1) → 一致零写（chargeFull 完全放开语义在位）")
    // 校回-2：值漂 → 失配（W3 在途写 80 晚落——坏序两翼之一，回读门闭合面）。
    check(Calibration.chargeFullReadbackMismatch(limit: 80, featureState: 1),
          "校回-2", "域 limit=80 → 失配（在途 W3 写/外部覆写晚落——重写 {100,1}）")
    // 校回-3：态漂 → 失配（机制关闭态——自愈重开覆盖面）。
    check(Calibration.chargeFullReadbackMismatch(limit: 100, featureState: 0),
          "校回-3", "域 featureState=0 → 失配（机制被关闭——自愈重开）")
    // 校回-4：键缺席（nil）按失配（域文件被删/键被清本身即覆写形态——TopoffWriter.read 语义同款）。
    check(Calibration.chargeFullReadbackMismatch(limit: nil, featureState: 1),
          "校回-4", "域 limit 缺席 → 失配（键清空 = 覆写形态，重写方向正确）")
    check(Calibration.chargeFullReadbackMismatch(limit: 100, featureState: nil),
          "校回-4", "域 featureState 缺席 → 失配（同上）")

    // ---- ② 节流常数（方案 §4：每 N=10 拍节流）----

    // 校回-5：stride 值钉死 10（tick 30s → 读回节奏 5 min；chargeFull ≤6h → ≤72 次）。
    expectEqual(Calibration.chargeFullReadbackStride, 10,
                "校回-5", "chargeFullReadbackStride == 10（5 min 读回节奏，子进程开销有界）")
    // 校回-6：stride 与 26 chargeFull/hold 保活的回读门形态同源钉——常量必须定义在
    // CellarCore.Calibration（纯函数域可测；daemon 侧 % 消费）。
    check(calibrationCore.contains("public static let chargeFullReadbackStride"),
          "校回-6", "stride 常量落位 CellarCore.Calibration（源钉——纯函数域单一属主）")
    check(calibrationCore.contains("limit != Topoff.shutdownLimit || featureState != 1"),
          "校回-6", "失配判据引用 Topoff.shutdownLimit 同源（勿字面量 100——回读门与启动序列同值）")
    // 校回-7：节流计数置零点钉死 startCalibrationLocked（每轮校准独立计拍）。
    check(calibrationExt.contains("calibrationChargeFullReadbackTicks = 0"),
          "校回-7", "节流计数置零在 startCalibrationLocked（源钉——每轮校准独立节流）")

    // ---- ③ 回读门在位（源钉——chargeFull stay 27 分支挂点）----

    // 校回-8：stay 拍 chargeFull 双分支——26 走 CHTE 保活（backend 臂）、27 走域
    // 读回（else 臂）——回读门在位且仅 27 可达（26 红线零触及）。
    check(calibrationExt.contains("calibrationChargeFullReadbackKeepAliveLocked(now: now, events: &events)"),
          "校回-8", "chargeFull stay 拍回读门在位（源钉——27 else 臂挂点）")
    let chargeFullBlock = calibrationExt.range(of: "case .chargeFull:").map { calibrationExt[$0.lowerBound...] }
    check(chargeFullBlock?.contains("keepAliveChargingLocked") == true
          && chargeFullBlock?.contains("calibrationChargeFullReadbackKeepAliveLocked") == true,
          "校回-8", "chargeFull stay 双分支：26 CHTE 保活 + 27 域读回并存（backend if/else 同位）")
    // 校回-9：节流消费形态（计数先递增 + % stride 门——源钉节流语义在 helper 头部）。
    check(calibrationExt.contains("calibrationChargeFullReadbackTicks += 1")
          && calibrationExt.contains("% Calibration.chargeFullReadbackStride == 0"),
          "校回-9", "节流实现 = 递增 + % stride（源钉——每 N 拍一次，非每拍读）")

    // ---- ④ 失配重写路径（源钉——回读门闭合的两翼 + fail-open）----

    // 校回-10：失配 → 重写经 topoffExecuteWriteLocked（簿记包装——lastWrittenLimit
    // 回填，0.23.2 先例），写值 = Topoff.shutdownLimit（与启动序列同值同源）。
    check(calibrationExt.contains("guard Calibration.chargeFullReadbackMismatch(")
          && calibrationExt.contains("topoffExecuteWriteLocked(limit: Topoff.shutdownLimit"),
          "校回-10", "失配 → topoffExecuteWriteLocked(shutdownLimit)（源钉——重写路径 + 值同源）")
    // 校回-11：读失败 fail-open（外层 nil → 不重写——防持久读故障重写风暴）。
    check(calibrationExt.contains("guard let readback = TopoffWriter.read(run: Self.runProcessCapture) else {"),
          "校回-11", "读回入口 = TopoffWriter.read（源钉——fail-open 门在位，读失败不重写）")
    // 校回-12：hold 相零写不触碰（回读门仅 chargeFull——hold 浮充语义不变，方案 §4）。
    let holdWindow = calibrationExt.range(of: "case .hold:")
        .map { String(calibrationExt[$0.lowerBound...].prefix(600)) } ?? ""
    check(!holdWindow.contains("calibrationChargeFullReadbackKeepAliveLocked"),
          "校回-12", "hold 相无回读门（源钉——零写浮充语义不变）")
    // 校回-13：节流计数器为 daemon 核心态存储属性（扩展不能加存储属性——编译面事实钉）。
    check(daemonCore.contains("var calibrationChargeFullReadbackTicks = 0"),
          "校回-13", "节流计数器落 daemon 核心态（源钉——内存态不持久化先例）")
}
