import CellarCore
import CellarUI
import Foundation
import os

// MARK: - 0.21.0 §1.1/§1.5 限充执行器抽象 + 关断残留态驱动对账（外迁 extension——
// StatusController.swift 行数纪律，LED extension 同款拆分惯例；跨文件读取的成员
// 在主类已放宽 internal——shortcutRunner/mclClient/mclReadbackValue）

/// 限充执行器抽象（§1.1 R1-P2-3）：编排消费的执行体双实现——**set 路径**
/// （MCLClient 免 root 直写，0.21.0 主通道）/ **shortcut 路径**（既有快捷指令，
/// 0.20 通道降为 fallback）。读回校验失配重跑臂同步走本抽象（R1-P2-3）。
/// Sendable：实现为无状态结构体（detached 闭包捕获存在类型需此约束——
/// ShortcutsRunning 先例）。
protocol LimitExecuting: Sendable {
    /// 执行目标设置。返回**读回校验目标**（set 路径 = 实际写入值；快捷指令路径 =
    /// 同值）——恢复臂 <80 分支钳 80 后读回按写入值校验，不与 pending 原值失配。
    /// 抛错 = 执行失败（detail 进回报链；MCLSetFailure 为 set 路径结构化失败）。
    func execute(target: Int) async throws -> Int
}

/// set 路径执行体（§1.1）：MCLClient.setLimit 免 root 直写。阻塞 ObjC 调用经
/// Task.detached 承载（主 actor 永不等待——MCLClient 线程纪律）。
struct MCLSetLimitExecutor: LimitExecuting {
    let client: MCLClient

    func execute(target: Int) async throws -> Int {
        let value = NativeLimitSet.setTarget(for: target)
        try await Task.detached { [client] in
            client.setLimit(value)
        }.value.get()
        return value
    }
}

/// 快捷指令路径执行体（0.20 WP-2 既有通道；fallback 驻留期承载）。
struct ShortcutLimitExecutor: LimitExecuting {
    let runner: ShortcutsRunning
    let name: String

    func execute(target: Int) async throws -> Int {
        try await runner.run(name: name, percent: target)
        return target
    }
}

extension StatusController {
    /// 执行体构造（§1.1 路由：set 优先；驻留后快捷指令——若用户未建，执行失败
    /// 如实回报，不静默）。
    func makeLimitExecutor(flavor: NativeLimitSet.ExecutorFlavor, name: String) -> LimitExecuting {
        switch flavor {
        case .embeddedSet:
            return MCLSetLimitExecutor(client: mclClient)
        case .shortcut:
            return ShortcutLimitExecutor(runner: shortcutRunner, name: name)
        }
    }

    // MARK: - 0.21.0 §1.5 关断残留闭环（App 侧补偿臂）

    /// App 自发关断（面板 disable / 编排开关关 XPC 成功回包）→ 按表即时对账
    /// （主 actor 调度，阻塞 I/O 全 detached——runControl onSuccess 回调语境）。
    func reconcileShutdownResidualNow() {
        Task { await reconcileShutdownResidual() }
    }

    /// 态驱动对账单跳（R3-P2-2 **读回值驱动**，无需会话记忆——覆盖 App 重启窗）：
    /// 观察 daemonStatus 派生关断期望值（NativeLimitSet.shutdownExpectation——
    /// R3-P1 拆分规则：disable 恒 100 / 编排关 target ≥80 → 100 / target <80 → 80；
    /// 正常执行态 nil = 无补偿），MCL 读回 ≠ 期望 → 补偿 set（走执行器味道——
    /// set 优先/驻留 fallback 一致）。
    ///
    /// 门控纪律：**27 终态门**（26 平台 orchestrationTerminal=false → 恒 no-op
    /// ——App 写 MCL 属 0.21 新行为，26 红线零增量）；读回缺席（nil）→ 不补偿
    /// （读回不可用即无法对账，不猜测语义）；期望达成 → 仅刷新按钮判定源；
    /// **校准可疑豁免（review P2-1）**：读回 > 期望 ∧ App 侧近似指纹命中
    ///（percent ≥95 ∧ charging ∧ target ≤90——`CalibrationCoexistence.
    /// residualCompensationExempt`，CellarCoreCheck 场景域钉死）→ 跳过本轮补偿。
    /// 与 daemon 指纹是两个独立判定（App 无 10 tick 窗状态；该配置下 daemon 指纹
    /// 因对账压回钳 80-85 结构性不可达，App 侧近似是引导链——放行 MCL 100 让电池
    /// 自由充至 percent ≥95，daemon 指纹接管三臂抑制）。近似豁免诚实边界：可能漏
    /// 抑制对账一轮（下轮 30s 重评）；percent 爬坡到 ≥95 前压回循环照旧。
    func reconcileShutdownResidual() async {
        guard orchestrationTerminal else { return }
        guard let status = daemonStatus else { return }
        let expected = NativeLimitSet.shutdownExpectation(
            modeActive: status.mode == "active",
            orchestrationEnabled: status.orchestration?.enabled == true,
            upperLimit: status.upperLimit
        )
        guard let expected else { return }
        let client = mclClient
        let readback = await Task.detached { client.readLimit() }.value
        guard let readback else { return }
        guard readback != expected else {
            mclReadbackValue = readback   // 对账一致——顺带刷新恢复臂判定源
            return
        }
        // 校准可疑豁免（review P2-1）：percent 数据源 = 1s 遥测快照优先、daemon
        // lastPercent 兜底；charging = 遥测 IsCharging 优先、powerOverride 兜底——
        // 表面全关（菜单栏常驻主态）时遥测快照不发布，无兜底则豁免在后台形态恒
        // 惰性（校准恰多发起于此）；daemon lastChargingEnabled 是控制键使能态非
        // 「正在充电」，不参与（27 终态本就 nil）。证据不足 → 豁免 false（保守：
        // 关断残留语义优先，不因观测缺席改变既有行为；IOPS 误豁免最坏代价 =
        // MCL 滞留 100 至下轮 30s 重评，有界且 doctor 检查 20 可见——复核 P3-3′）。
        let telemetry = batterySnapshot
        let calibrationExempt = CalibrationCoexistence.residualCompensationExempt(
            readback: readback,
            expected: expected,
            percent: telemetry?.percent ?? status.lastPercent,
            isCharging: telemetry?.isCharging ?? powerOverride?.isCharging,
            target: status.upperLimit
        )
        if calibrationExempt {
            Self.log.info("关断残留对账跳过：读回 \(readback)% > 期望 \(expected)% ∧ 校准可疑近似命中（percent ≥95 充电 ∧ target ≤90）——MCL 保持，引导 daemon 指纹接管（下轮 30s 重评；近似豁免可能漏抑制对账一轮）")
            return
        }
        // 补偿 set（当前执行体味道；Name 仅快捷指令 fallback 味道消费）。
        let flavor = NativeLimitSet.executorFlavor(dwellingShortcut: executorDwellsShortcut)
        let executor = makeLimitExecutor(
            flavor: flavor, name: OrchestrationSettings.currentShortcutName())
        do {
            let setValue = try await executor.execute(target: expected)
            let verified = await Task.detached { client.readLimit() }.value
            mclReadbackValue = verified
            Self.log.info("关断残留补偿：读回 \(readback)% ≠ 期望 \(expected)% → set \(setValue)%（补偿后读回 \(verified.map(String.init) ?? "不可用")）")
        } catch {
            // 失败仅 os_log（控制横幅不进——关断本身已成功；残留由 doctor 检查 20
            // 可见化 + 下轮对账重试，诚实呈现不静默）。
            Self.log.error("关断残留补偿失败（期望 \(expected)%，读回 \(readback)%）：\(String(describing: error))——下轮对账重试")
        }
    }

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "limit-execution")
}
