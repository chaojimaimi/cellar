import Foundation
import CellarCore

// MARK: - Phase 5 v1.1 风扇智能降温（方案 §3-§6；全部锁内）

/// 风扇状态机的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 触及 800 行硬
/// 上限；可见性/属主不变量与 DaemonCore+OneShot.swift 同款：cellar-daemon 为
/// executable target，internal 符号模块外不可达）。语义决策全部经
/// CellarCore.FanGuard / FanPolicy（CellarCoreCheck 矩阵穷举钉死）转移，本扩展
/// 只做副作用（写 F0Md/F0Tg、探测、日志）与运行时状态（FanRuntimeState，
/// 存储在 DaemonCore.swift 的单一属性——扩展不能加存储属性）。
///
/// 锁纪律（方案 §3）：复用 DaemonCore.lock 单一锁（禁新锁）；10s 风扇 tick 与
/// 30s 心跳错峰，锁内仅短临界区（1 次温度采样 + 条件性 1-2 次 SMC 写）；
/// os_log 一律锁外 emit（events 收集、解锁后统一发）。
///
/// 写纪律（spike 定版，方案 §2.4）：boost 进入 = 两步写（先 F0Md=1 回读一致，
/// 再 F0Tg=目标 回读一致），释放 = 两步（F0Tg→原值快照 + F0Md=0）；Md=0 下 Tg
/// 写会被固件即时拒绝（回读=原值）——这本身就是「未解锁」的运行时信号。
extension DaemonCore {
    // MARK: - 入口

    /// 10s 风扇 tick 入口（main.swift 定时器调用；带锁包装，锁纪律见 performTick）。
    func runFanTick() {
        var events: [LogEvent] = []
        lock.lock()
        fanTickLocked(events: &events)
        lock.unlock()
        emit(events)
    }

    /// 风扇状态快照（DaemonCore.buildStatusLocked 调用；锁内）。
    func fanStatusLocked() -> FanStatus {
        let fanPolicy = policy.fan ?? .default
        return FanStatus(
            enabled: fanPolicy.enabled,
            strategy: fanPolicy.strategy,
            state: fanState.word,
            targetRPM: fanState.targetRPM,
            currentRPM: fanState.currentRPM,
            thresholdCentiC: fanPolicy.thresholdCentiC,
            conflictFlag: fanState.conflictFlag,
            speedPercent: fanPolicy.speedPercent,
            stage2Percent: fanPolicy.stage2Percent,
            stage2RiseCentiC: fanPolicy.stage2RiseCentiC
        )
    }

    // MARK: - setFan XPC（方案 §8）

    /// setFanConfig：校验（缺席保持合并且行 + validated 整包强校验；minRaise →
    /// 抛错「该策略在当前版本暂未开放」，§0.5b）→ 应用 policy（**不改 mode**——
    /// setLimits 的「更新即切 active」语义不适用，方案 §8）→ 持久化 → 开关翻转
    /// 重置（§5.2）→ 关闭立即释放 / boost 期立即按新配置重算重写（§5.1 D 例外②）
    /// → 开启路径即时 tick（不等 10s 节拍）→ 返回状态。
    func setFanConfig(_ wire: FanWire) throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        let base = policy.fan ?? FanPolicy.default
        guard let merged = wire.mergedPolicy(base: base) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setFan 拒绝：风扇参数越界（validated 整包 nil——绝不落半合法策略）"
            ))
            throw FanSetError.invalidParameters
        }
        guard merged.strategy != .minRaise else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setFan 拒绝：minRaise 策略 v1.1 暂未开放（§0.5b）"
            ))
            throw FanSetError.strategyUnsupported
        }
        let oldFan = policy.fan
        let wasBoost = fanState.boostActive
        // F-1 纪律：applyPolicyLocked 之外的直接字段更新——policy.fan 是本命令的
        // 专属修改面（模式/限值不动），与 setLimits/disable/enable 的重建点互斥。
        policy.fan = merged
        persistPolicyLocked(events: &events)

        // 开关翻转重置（方案 §5.2：仅关→开——重新 opt-in = 新意图，R2 P2-A 同判例）：
        // 能力/冲突/采样/进入失败/漂移门齐清，重探重试。
        if FanGuard.resetRequired(old: oldFan, new: merged) {
            fanState.capability = .unverified
            fanState.conflictFlag = false
            fanState.sampleHealthy = true
            fanState.sampleFailures = 0
            fanState.entryFailures = 0
            fanState.driftTicks = 0
            fanState.word = .probing
            // 防御：翻转期残留 boost 理论不可达（boost 只在 enabled 期存在），兜底释放。
            if fanState.boostActive {
                releaseFanLocked(events: &events)
            }
            events.append(LogEvent(
                category: .control, level: .info,
                message: "风扇开关已开启：能力/冲突门重置（重新 opt-in，重探重试）"
            ))
        }
        if !merged.enabled {
            // 关闭 → 立即释放（方案 §11 验收 4：关开关 → 立即释放）。
            if fanState.boostActive {
                releaseFanLocked(events: &events)
            }
            fanState.word = .off
        } else if wasBoost, let target = boostedTargetLocked(policy: merged, events: &events) {
            // boost 期配置变更 → 立即按新配置重算重写（方案 §5.1 D 例外② + P2-3）。
            if let current = fanState.targetRPM, target != current {
                rewriteFanTargetLocked(target: target, events: &events)
            }
        }
        if merged.enabled {
            // 即时 tick：开启/变更后的重估（进入/释放/驻留语义与下 tick 同源）。
            fanTickLocked(events: &events)
        }
        return buildStatusLocked()
    }

    // MARK: - tick（方案 §5.1 状态机执行体）

    /// 风扇 tick（10s 节拍；锁内）：温度采样 → 冲突会话门 → facts 探测缓存 →
    /// 漂移检测 → writeFollowed 证据（路径 A）→ FanGuard.decided → 副作用 →
    /// 能力推进 + boostTicks 计数。
    func fanTickLocked(events: inout [LogEvent]) {
        // 未启用快速路径：不采样不探测（决策 A 语义直落；释放已由 setFanConfig
        // 即时完成，此处仅为残留防御——理论不可达）。
        guard let fanPolicy = policy.fan, fanPolicy.enabled else {
            if fanState.boostActive {
                releaseFanLocked(events: &events)
            }
            return
        }
        let modeActive = policy.mode == "active"

        // 1) 温度采样（方案 §6 温度源单点 = BatterySnapshot.temperatureC，与充电
        //    热暂停同源）；连续失败 ≥3 → sampleHealthy=false（F 行 degraded）。
        var temperatureC = fanState.lastTemperatureC
        do {
            temperatureC = try monitor.snapshot().temperatureC
            fanState.lastTemperatureC = temperatureC
            fanState.sampleFailures = 0
            fanState.sampleHealthy = true
        } catch {
            fanState.sampleFailures += 1
            if fanState.sampleFailures >= FanGuard.sampleFailureLimit {
                fanState.sampleHealthy = false
            }
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇 tick 温度采样失败（连续第 \(fanState.sampleFailures) 次）：\(error)"
            ))
        }

        // 2) 冲突会话门（方案 §5.3）：冲突标志置位后本适配器会话内不再介入
        //    （开关翻转重置）；残留 boost 防御性释放（冲突检测路径已释放）。
        if fanState.conflictFlag {
            if fanState.boostActive {
                releaseFanLocked(events: &events)
            }
            fanState.word = .conflict
            return
        }

        // 3) facts 探测缓存（方案 §5.1 C' + R1 P3-4 探测时机）：非 boost 期每 tick
        //    重探；boost 期用缓存，SMCClient 重建（clientGeneration 递增）后失效
        //    重探。类型/尺寸/值语义与预期不符 → fail-visible + capability=
        //    unavailable（方案 §4.1 红线：不做值格式猜测）。
        if fanState.factsProbeGeneration != fanState.clientGeneration || !fanState.boostActive {
            probeFanFactsLocked(events: &events)
            // boost 期探测失败 → 立即释放，不盲维持（方案 §5.1 不变量注记）。
            if fanState.boostActive && fanState.facts == nil {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇 boost 期 facts 失效：立即释放（保守，不盲维持）"
                ))
                releaseFanLocked(events: &events)
            }
        }

        // 4) 漂移检测（boost 期；方案 §5.3 主方案 = 行为级回读漂移检测）：写后下
        //    tick 回读 ≠ 写入值 连续 ≥2 次 → 冲突标志 + 自动 release + 会话内
        //    暂停介入（GO 判据已排除竞争写——直写模式下漂移即真实外部写者）。
        //    漂移计数清零**只由本干净回读分支承担**（P1-1：重写成功路径不清零，
        //    防自家重写掩盖外部写者的跨 tick 累计与自家击穿冲突检测）。
        if fanState.boostActive, let client = smcClient {
            do {
                let back = try client.read("F0Tg")
                if let last = fanState.lastWrittenTg, back != last {
                    noteFanWriteMismatchLocked(
                        FanBodyError.readbackMismatch(key: "F0Tg", desiredHex: hex(last), actualHex: hex(back)),
                        events: &events, context: "风扇目标漂移检测"
                    )
                    if fanState.conflictFlag { return }
                } else {
                    fanState.driftTicks = 0
                }
            } catch let error {
                if FanGuard.isKeyDomainError(error) {
                    // P1-2：Tg 键域错误（keyNotFound/invalidKey）非传输故障——不进
                    // 共享自愈计数；boost 期 Tg 缺席按 degraded 处理走释放（fail-safe）。
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "风扇 F0Tg 回读键域错误（\(error)）：按采样异常处理，释放风扇"
                    ))
                    fanState.word = .degraded
                    releaseFanLocked(events: &events)
                    return
                }
                noteControlFailureLocked(error, events: &events, context: "风扇 F0Tg 回读")
            }
        }

        // 5) writeFollowed 证据（boost 期；方案 §5.2 路径 A——spike 定版实测可用，
        //    路径 B 标定不需要，方案 §2.4 条 4）：Ac ≥ 写入目标 − 300rpm。
        //    Ac 键缺席（keyNotFound）：仅本 tick 无证据（观察窗自会收口到
        //    unavailable——诚实停用），不进共享自愈计数（P1-2）。
        var writeFollowed = false
        if fanState.boostActive, let client = smcClient, let target = fanState.targetRPM {
            do {
                let acBytes = try client.read("F0Ac")
                if let ac = FanSMC.decodeRPM(acBytes) {
                    fanState.currentRPM = ac
                    writeFollowed = ac >= target - FanGuard.writeFollowFloorRPM
                }
            } catch let error {
                if FanGuard.isKeyDomainError(error) {
                    events.append(LogEvent(
                        category: .control, level: .warn,
                        message: "风扇 F0Ac 回读键域错误（\(error)）：本 tick 无写跟随证据（观察窗收口）"
                    ))
                } else {
                    noteControlFailureLocked(error, events: &events, context: "风扇 F0Ac 回读")
                }
            }
        }

        // 6) 决策（方案 §5.1 求值序 A→B→F→C'→C→G→D→E→S，先命中先输出，
        //    由 FanGuard 钉死——CellarCoreCheck 矩阵同源）。
        let decision = FanGuard.decided(
            temperatureC: temperatureC,
            policy: fanPolicy,
            modeActive: modeActive,
            capability: fanState.capability,
            boostActive: fanState.boostActive,
            boostTicks: fanState.boostTicks,
            currentTargetRPM: fanState.targetRPM,
            facts: fanState.facts,
            sampleHealthy: fanState.sampleHealthy
        )
        switch decision {
        case .idle(let word):
            fanState.word = word
        case .enterBoost(let target):
            // 进入 = 两步写（Md=1 → Tg=target，各带回读校验）；失败 → fail-visible
            // 不进入；连续失败 ≥3 → 能力关停（方案 §13 R3 诚实结局）。
            if enterFanBoostLocked(target: target, events: &events) {
                fanState.word = .boost
            }
        case .hold:
            fanState.word = .hold
        case .rewrite(let target):
            rewriteFanTargetLocked(target: target, events: &events)
            if !fanState.conflictFlag {
                fanState.word = .boost
            }
        case .release(let word):
            if fanState.boostActive {
                releaseFanLocked(events: &events)
            }
            fanState.word = word
        }

        // 7) 能力推进（方案 §5.2；boost 期每 tick）：writeFollowed → verified；
        //    观察窗到期（boostTicks ≥ 10）未获证据 → unavailable + 保守释放
        //    （诚实停用，不盲维持 boost）。boostTicks 逐 tick +1（进入置 0、
        //    release 清零，R1 P3-4）。
        if fanState.boostActive {
            let advanced = FanGuard.capabilityAdvanced(
                current: fanState.capability,
                boostTicks: fanState.boostTicks,
                writeFollowed: writeFollowed
            )
            if fanState.capability == .unverified && advanced == .unavailable {
                fanState.capability = .unavailable
                fanState.word = .unsupported
                releaseFanLocked(events: &events)
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇能力观察窗到期（100s）未获写跟随证据：本机无法自动验证风扇控制——已释放并停用（doctor 可复核）"
                ))
            } else {
                fanState.capability = advanced
                // 仅未释放的 boost 期计数（release 已清零——此处不叠加，时序精确）。
                fanState.boostTicks += 1
            }
        }
    }

    // MARK: - 释放（五路口统一出口，方案 §6.4）

    /// 统一释放出口（五路口：①SIGTERM/SIGINT（restoreAndExit 挂钩）②开关关闭/
    /// disable 模式（setFanConfig 即时 + 决策 A）③决策矩阵 case A/B/E/F（tick）
    /// ④sleepNow 睡眠前释放 ⑤启动恢复分支）。
    ///
    /// boost 语境：**两步释放**（方案 §2.4 条 3）：F0Tg→原值快照（回读一致）→
    /// F0Md=0（回读一致）——两步都必须执行，仅停写不停 Md = 未交还；Md 统一写
    /// 0（系统自动规范值），E0 原值仅 spike 还原语境使用（R3 N-2 定版）。
    /// 非 boost 语境：启动/睡眠残留检查（方案 §6.5）——F0Md≠0 → 写 0 + warn；
    /// F0Md=0 而 Tg 残留 → 系统自动模式下 Tg 不生效，仅调试日志。
    func releaseFanLocked(events: inout [LogEvent]) {
        if fanState.boostActive {
            guard let client = smcClient else {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇释放：无 SMC 客户端——Tg/Md 还原不可执行（boost 态保留，残留交启动恢复兜底）"
                ))
                return
            }
            var releaseOK = true
            // 第一步：Tg → 原值快照（回读一致）。失败 → 继续第二步（Md=0 本身即
            // fail-safe 方向——系统自动接管后 Tg 归系统属主），残留由启动恢复兜底。
            if let original = fanState.originalTg {
                do {
                    try client.write("F0Tg", bytes: original)
                    try verifyFanKey("F0Tg", written: original, client: client)
                } catch {
                    releaseOK = false
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "风扇释放：F0Tg 还原失败（\(error)）——继续 Md=0（失败方向 fail-safe）"
                    ))
                }
            }
            // 第二步：Md=0（回读一致）——交还系统自动。
            do {
                try client.write("F0Md", bytes: [0x00])
                try verifyFanKey("F0Md", written: [0x00], client: client)
            } catch {
                releaseOK = false
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇释放：F0Md 还原失败（\(error)）——残留由启动恢复/doctor 兜底"
                ))
            }
            fanState.boostActive = false
            fanState.boostTicks = 0
            fanState.targetRPM = nil
            fanState.currentRPM = nil
            fanState.lastWrittenTg = nil
            fanState.originalTg = nil
            fanState.driftTicks = 0
            fanState.entryFailures = 0
            if releaseOK {
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "风扇已释放：F0Tg→原值 + F0Md=0（交还系统自动）"
                ))
            }
            return
        }
        // 非 boost 语境：仅风扇已配置时做残留检查（零配置零 SMC 流量）。
        guard policy.fan != nil, let client = smcClient else { return }
        do {
            let md = try client.read("F0Md")
            guard md != [0x00] else {
                let tg = (try? client.read("F0Tg")).map(hex) ?? "读失败"
                events.append(LogEvent(
                    category: .control, level: .info,
                    message: "风扇启动检查：F0Md=0（系统自动）F0Tg=\(tg)——无需恢复"
                ))
                return
            }
            try client.write("F0Md", bytes: [0x00])
            try verifyFanKey("F0Md", written: [0x00], client: client)
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "风扇启动恢复：F0Md=\(hex(md))≠0（疑似崩溃残留）——已写回 0（系统自动规范值）"
            ))
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇启动恢复：F0Md 读取/写回失败（\(error)）——残留窗口未收口，doctor 风扇行请核对"
            ))
        }
    }

    // MARK: - 副作用内部（进入/重写/探测）

    /// 进入 boost（方案 §2.4 条 2 两步写）：原值快照 → F0Md=1（回读一致）→
    /// F0Tg=目标（回读一致）；任一步失败 → fail-visible 不进入 + 回滚（Tg→原值
    /// + Md=0，防「解锁成功但目标写失败」的半进入态滞留，fail-safe 方向）；
    /// 连续失败 ≥3 → 能力置 unavailable（§13 R3 诚实结局——写入静默忽略机型）。
    @discardableResult
    private func enterFanBoostLocked(target: Float, events: inout [LogEvent]) -> Bool {
        guard let client = smcClient else { return false }
        let tgBytes = FanSMC.encodeRPM(target)
        do {
            // 原值快照（释放序列的还原目标；读先于一切写）。
            let currentTg = try client.read("F0Tg")
            fanState.originalTg = currentTg
            // 第一步：F0Md=1（回读一致）——Md=0 下 Tg 写会被固件即时拒绝。
            try client.write("F0Md", bytes: [0x01])
            try verifyFanKey("F0Md", written: [0x01], client: client)
            // 第二步：F0Tg=目标（回读一致）。
            try client.write("F0Tg", bytes: tgBytes)
            try verifyFanKey("F0Tg", written: tgBytes, client: client)
        } catch {
            fanState.entryFailures += 1
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇进入 boost 失败（连续第 \(fanState.entryFailures) 次）：\(error)——不进入（fail-visible）"
            ))
            rollbackFanEntryLocked(client: client, events: &events)
            if fanState.entryFailures >= FanGuard.sampleFailureLimit {
                fanState.capability = .unavailable
                fanState.word = .unsupported
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇进入 boost 连续失败 ≥3 次：能力置为不可用（本机无法介入——M3/M4+ 世代保护的诚实结局，方案 §13 R3）"
                ))
            }
            return false
        }
        fanState.entryFailures = 0
        fanState.boostActive = true
        fanState.boostTicks = 0
        fanState.targetRPM = target
        fanState.lastWrittenTg = tgBytes
        fanState.driftTicks = 0
        events.append(LogEvent(
            category: .control, level: .info,
            message: "风扇 boost 进入：F0Md=1 + F0Tg=\(Int(target))rpm（两步写回读校验通过）"
        ))
        return true
    }

    /// 进入失败回滚（尽力而为：Tg→原值 + Md=0；写失败仅记日志——残留交
    /// 启动恢复/doctor，与释放路径同兜底面）。
    private func rollbackFanEntryLocked(client: SMCClient, events: inout [LogEvent]) {
        if let original = fanState.originalTg {
            do {
                try client.write("F0Tg", bytes: original)
                try verifyFanKey("F0Tg", written: original, client: client)
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇进入回滚：F0Tg 还原失败（\(error)）"
                ))
            }
        }
        do {
            try client.write("F0Md", bytes: [0x00])
            try verifyFanKey("F0Md", written: [0x00], client: client)
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇进入回滚：F0Md 还原失败（\(error)）——残留交启动恢复兜底"
            ))
        }
    }

    /// 带内重写（D 例外族：twoStage 升档跨越 / boost 期配置变更）：仅写 Tg
    /// （Md 已在进入时置 1）——写后回读校验；失败 → 漂移计数（冲突检测通道，
    /// 方案 §5.3）。⚠️ 成功路径**不清 driftTicks**（P1-1）：漂移清零只由 tick
    /// step4 的干净回读 else 分支承担——重写清零会让「重写后同 tick 观察到
    /// 外部漂移」被湮灭，自家重写成为冲突检测的击穿面。
    private func rewriteFanTargetLocked(target: Float, events: inout [LogEvent]) {
        guard let client = smcClient else { return }
        let tgBytes = FanSMC.encodeRPM(target)
        do {
            try client.write("F0Tg", bytes: tgBytes)
            try verifyFanKey("F0Tg", written: tgBytes, client: client)
            fanState.targetRPM = target
            fanState.lastWrittenTg = tgBytes
            events.append(LogEvent(
                category: .control, level: .info,
                message: "风扇目标重写：F0Tg=\(Int(target))rpm（回读校验通过）"
            ))
        } catch {
            noteFanWriteMismatchLocked(error, events: &events, context: "风扇目标重写")
        }
    }

    /// 写/回读干扰统一处理（方案 §5.3 行为级漂移检测）：计数 +1；≥2 → 冲突标志
    /// + 自动 release + 本适配器会话内不再介入（开关翻转重置）。
    private func noteFanWriteMismatchLocked(_ error: Error, events: inout [LogEvent], context: String) {
        fanState.driftTicks += 1
        events.append(LogEvent(
            category: .control, level: .warn,
            message: "\(context)失败（漂移计数 \(fanState.driftTicks)/\(FanGuard.conflictDriftTicks)）：\(error)——疑似其他风扇控制工具干预"
        ))
        if fanState.driftTicks >= FanGuard.conflictDriftTicks {
            fanState.conflictFlag = true
            fanState.word = .conflict
            releaseFanLocked(events: &events)
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "检测到其他风扇控制写入者：已释放并暂停介入（会话内不再介入，开关翻转重置）"
            ))
        }
    }

    /// F0Mn/F0Mx 探测（keyInfo + read，LE 解码——方案 §2.4 条 1 U7 定版）。
    /// 成功 → 缓存 + 代际同步；类型/尺寸/值语义异常 → fail-visible +
    /// capability=unavailable（方案 §4.1：不做值格式猜测）；传输类失败 → 自愈
    /// 计数 + facts 置 nil（下 tick 重试）。
    private func probeFanFactsLocked(events: inout [LogEvent]) {
        guard let client = smcClient else {
            if fanState.facts != nil {
                fanState.facts = nil
                fanState.factsProbeGeneration = -1
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇 facts 失效：无 SMC 客户端（后端未建立/自愈中）"
                ))
            }
            return
        }
        do {
            let mnInfo = try client.keyInfo("F0Mn")
            let mxInfo = try client.keyInfo("F0Mx")
            let mnIsFlt4 = mnInfo.type.trimmingCharacters(in: .whitespaces) == "flt" && mnInfo.size == 4
            let mxIsFlt4 = mxInfo.type.trimmingCharacters(in: .whitespaces) == "flt" && mxInfo.size == 4
            if !(mnIsFlt4 && mxIsFlt4) {
                fanState.capability = .unavailable
                fanState.facts = nil
                fanState.factsProbeGeneration = -1
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇键类型/尺寸与预期不符（F0Mn=\(mnInfo.type)/\(mnInfo.size)B，F0Mx=\(mxInfo.type)/\(mxInfo.size)B；预期 flt/4B）——能力置为不可用（fail-visible，不做值格式猜测）"
                ))
                return
            }
            let mnBytes = try client.read("F0Mn")
            let mxBytes = try client.read("F0Mx")
            guard let mn = FanSMC.decodeRPM(mnBytes), let mx = FanSMC.decodeRPM(mxBytes),
                  mn.isFinite, mx.isFinite, mn > 0, mx > 0, mn <= mx else {
                fanState.capability = .unavailable
                fanState.facts = nil
                fanState.factsProbeGeneration = -1
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇转速值语义异常（F0Mn/F0Mx 解码失败、非正或倒挂）——能力置为不可用（fail-visible）"
                ))
                return
            }
            fanState.facts = FanFacts(minRPM: mn, maxRPM: mx)
            fanState.factsProbeGeneration = fanState.clientGeneration
        } catch let error {
            if FanGuard.isKeyDomainError(error) {
                // P1-2：F0Mn/F0Mx 键缺席（keyNotFound/invalidKey）是机型事实——
                // 不进共享自愈计数（防周期性拆除充电后端）；直接能力置不可用
                //（B 行接管 =「本机不支持」诚实停用）。
                if fanState.capability != .unavailable {
                    fanState.capability = .unavailable
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "风扇键缺失（\(error)）——能力置为不可用（本机不支持）"
                    ))
                }
                fanState.facts = nil
                fanState.factsProbeGeneration = -1
                return
            }
            noteControlFailureLocked(error, events: &events, context: "风扇 facts 探测")
            fanState.facts = nil
            fanState.factsProbeGeneration = -1
        }
    }

    /// boost 期配置变更的目标重算（facts 失效 → nil 跳过——tick 的 C' 路径接管）。
    private func boostedTargetLocked(policy: FanPolicy, events: inout [LogEvent]) -> Float? {
        guard let facts = fanState.facts else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "setFan boost 期重算：facts 不可用，暂时跳过（tick 探测成功后自动收敛）"
            ))
            return nil
        }
        return FanGuard.targetRPM(policy: policy, facts: facts, temperatureC: fanState.lastTemperatureC)
    }

    /// 写后回读校验（红线 3 同源）：不一致 → FanBodyError 上抛（调用方按
    /// fail-visible/漂移计数处置，绝不静默）。
    private func verifyFanKey(_ key: String, written: [UInt8], client: SMCClient) throws {
        let back = try client.read(key)
        guard back == written else {
            throw FanBodyError.readbackMismatch(key: key, desiredHex: hex(written), actualHex: hex(back))
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - 运行时状态与错误

/// 风扇运行时状态（DaemonCore.swift 的单一存储属性 `var fan`；本文件定义——
/// 扩展不能加存储属性。崩溃重启即清零——重启后由 startup 的 releaseFanLocked
/// 残留检查（F0Md≠0 → 写 0）收口，方案 §6.5）。
struct FanRuntimeState {
    /// boost 活跃（两步写成功后置位；两步释放后清零）。
    var boostActive = false
    /// boost 以来风扇 tick 数（进入置 0，逐 tick +1，release 清零——R1 P3-4）。
    var boostTicks = 0
    /// 能力（sticky；仅开关翻转重置——setFanConfig）。
    var capability: FanCapability = .unverified
    /// 本机 F0Mn/F0Mx 探测缓存（nil = 未探测成功；boost 期失效 → 立即释放）。
    var facts: FanFacts?
    /// facts 探测成功时的客户端代际（≠ clientGeneration → 失效重探）。
    var factsProbeGeneration = -1
    /// SMCClient 重建代际（establishBackendLocked 递增——facts 缓存失效信号）。
    var clientGeneration = 0
    /// 冲突标志（方案 §5.3：漂移 ≥2 → 置位；会话内暂停介入；开关翻转重置）。
    var conflictFlag = false
    /// 进入 boost 连续失败计数（≥3 → 能力 unavailable，§13 R3）。
    var entryFailures = 0
    /// 温度采样连续失败计数（≥3 → sampleHealthy=false）。
    var sampleFailures = 0
    /// 采样健康（BatterySnapshot 连续失败 ≥3 → false；恢复采样自动复位——
    /// capability 不因采样抖动重置，方案 §6.6）。
    var sampleHealthy = true
    /// 最近成功采样温度（采样失败期间沿用——F 行在温度比较前短路，值不参与判定）。
    var lastTemperatureC: Double = 0
    /// 状态行词（各决策副作用更新；初值 off = 未配置形态）。
    var word: FanStateWord = .off
    /// 最近一次写入目标 rpm（FanStatus.targetRPM 载荷）。
    var targetRPM: Float?
    /// 最近一次 F0Ac 活值（仅 boost 期采样；FanStatus.currentRPM 载荷）。
    var currentRPM: Float?
    /// 最近一次成功写入的 F0Tg 字节（漂移检测比对基准）。
    var lastWrittenTg: [UInt8]?
    /// 漂移连续计数（写后回读不一致/下 tick 回读漂移；清朗回读归零）。
    var driftTicks = 0
    /// 进入 boost 时的 F0Tg 原值快照（释放序列第一步的还原目标）。
    var originalTg: [UInt8]?
}

/// setFan 拒绝（message = 用户可读文案；XPC errorReply 原文透传，App 上屏）。
enum FanSetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 参数越界（validated 整包 nil——不落半合法策略）。
    case invalidParameters
    /// minRaise 策略 v1.1 暂未开放（§0.5b fail-visible）。
    case strategyUnsupported

    public var message: String {
        switch self {
        case .invalidParameters: return "风扇参数越界（阈值 30-55°C，转速 40-100%，滞回 1-5°C）"
        case .strategyUnsupported: return FanWireKeys.strategyUnsupportedMessage
        }
    }

    public var description: String { message }
}

/// 风扇写回读校验失败（字节级不一致；description 进日志与 XPC 错误分支）。
enum FanBodyError: Error, Equatable, Sendable {
    case readbackMismatch(key: String, desiredHex: String, actualHex: String)
}

extension FanBodyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .readbackMismatch(let key, let desiredHex, let actualHex):
            return "\(key) 写后回读不一致（期望 \(desiredHex)，实际 \(actualHex)）"
        }
    }
}