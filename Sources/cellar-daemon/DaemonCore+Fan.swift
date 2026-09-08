import Foundation
import CellarCore

// MARK: - Phase 5 v1.1 风扇智能降温（v1.12 M1 槽位化：F0/F1 每风扇槽位状态机）

/// 风扇状态机的 daemon 侧实现（扩展文件拆分——DaemonCore.swift 触及 800 行硬
/// 上限；可见性/属主不变量与 DaemonCore+OneShot.swift 同款：cellar-daemon 为
/// executable target，internal 符号模块外不可达）。语义决策全部经
/// CellarCore.FanGuard / FanPolicy（CellarCoreCheck 矩阵穷举钉死）转移，本扩展
/// 只做副作用（写 FnMd/FnTg、探测、日志）与运行时状态（FanRuntimeState/FanSlot
/// 定义在 DaemonCore+FanState.swift——扩展不能加存储属性）。
///
/// v1.12 M1 槽位化（方案 §2-D2/D3）：per-fan 字段收进 FanSlot，tick 对每槽独立
/// 走 冲突门→facts 探测→漂移检测→writeFollowed→decided→副作用→能力推进 全链；
/// 温度采样一次双扇共享（D1 同开关同策略同阈值）。决策纯函数 FanGuard.decided
/// 签名按键无关参数化——零修改复用，既有 CellarCoreCheck 风扇场景即回归门。
///
/// 锁纪律（方案 §3）：复用 DaemonCore.lock 单一锁（禁新锁）；10s 风扇 tick 与
/// 30s 心跳错峰，锁内仅短临界区（1 次温度采样 + 条件性每槽 1-2 次 SMC 写）；
/// os_log 一律锁外 emit（events 收集、解锁后统一发）。
///
/// 写纪律（spike 定版，方案 §2.4；F1 同构实测 SMC-NOTES §10）：boost 进入 =
/// 两步写（先 FnMd=1 回读一致，再 FnTg=目标 回读一致），释放 = 两步（FnTg→原值
/// 快照 + FnMd=0）；Md=0 下 Tg 写会被固件即时拒绝（回读=原值）——这本身就是
/// 「未解锁」的运行时信号。F1Md 锁存延迟 ∈(100,400]ms（§10.1）——生产
/// verifyLadder=[100,300,800]ms 第二档覆盖，无需调参。
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
    /// FanStatus.state/targetRPM/currentRPM/conflictFlag = 槽 0（存量语义零变化）；
    /// 第二扇四字段仅双槽在位时携带（D5——nil = 旧 daemon/单风扇/未探测，App 隐藏）。
    func fanStatusLocked() -> FanStatus {
        let fanPolicy = policy.fan ?? .default
        // 惰性探测挂点（v1.11 T3 D-3c：status 回包恒组装 → 风扇关态也执行；sticky
        // 后零成本。F1 在位探测照同款先例静默执行——结论经 secondFanPresent 面
        // 可见化，探测本身无 emit 通道）。
        ensureCpuSkinProbeLocked()
        ensureFan1PresenceLocked()
        var secondPresent: Bool?
        var secondState: FanStateWord?
        var secondTarget: Float?
        var secondCurrent: Float?
        if fanState.slots.count == 2 {
            secondPresent = true
            secondState = fanState.slots[1].word
            secondTarget = fanState.slots[1].targetRPM
            secondCurrent = fanState.slots[1].currentRPM
        }
        return FanStatus(
            enabled: fanPolicy.enabled,
            strategy: fanPolicy.strategy,
            state: fanState.slots[0].word,
            targetRPM: fanState.slots[0].targetRPM,
            currentRPM: fanState.slots[0].currentRPM,
            thresholdCentiC: fanPolicy.thresholdCentiC,
            conflictFlag: fanState.slots[0].conflictFlag,
            speedPercent: fanPolicy.speedPercent,
            stage2Percent: fanPolicy.stage2Percent,
            stage2RiseCentiC: fanPolicy.stage2RiseCentiC,
            // 线值 Int 化（0/1 小值域——wireValue UInt64 安全收窄）。
            temperatureSource: Int(FanWire.wireValue(fanPolicy.temperatureSource)),
            cpuSkinTempC: fanState.lastCpuSkinTempC,
            cpuSkinSupported: fanState.cpuSkinSupported,
            cpuSkinThresholdCentiC: fanPolicy.cpuSkinThresholdCentiC,
            cpuSkinHysteresisCentiC: fanPolicy.cpuSkinHysteresisCentiC,
            secondFanPresent: secondPresent,
            secondFanState: secondState,
            secondFanTargetRPM: secondTarget,
            secondFanCurrentRPM: secondCurrent
        )
    }

    // MARK: - CPU 表面温度源（v1.11 T3 双源；惰性探测 sticky）

    /// CPU 表面温度源惰性探测（D-3c）：首次访问执行，结论 sticky 于 FanRuntimeState
    /// （supported nil = 未探——smcClient 缺席窗口不置 sticky，照 probeFanFactsLocked
    /// 「置 nil 不 sticky、下轮重探」先例，区分「未探」与「探而不中」；true/false =
    /// 探测结论，进程内不回落）。探测序列/值域门全权委托共享 CpuSkinSensor.probe
    /// （0.18 T5 D-5b 共享化——与 App 层单一真相，R-4）；首个命中记 cpuSkinKey，
    /// 全不命中 → supported=false（setFan 选 cpuSkin 前置拒绝 fail-visible）。
    /// 静默设计：本函数被锁内组装路径（buildStatusLocked 全调用面）调用，无 emit
    /// 面——探测结论经 FanStatus.cpuSkinSupported / doctor / setFan 拒绝文案三面
    /// 可见化，非静默吞失败（探测结论本身即输出）。
    func ensureCpuSkinProbeLocked() {
        guard fanState.cpuSkinSupported == nil else { return }
        guard let client = smcClient else { return }
        if let key = CpuSkinSensor.probe(connection: client) {
            fanState.cpuSkinKey = key
            fanState.cpuSkinSupported = true
        } else {
            fanState.cpuSkinSupported = false
        }
    }

    // MARK: - setFan XPC（方案 §8）

    /// setFanConfig：校验（缺席保持合并且行 + validated 整包强校验；策略值域已由
    /// XPCServer validateRequest 前置拒绝）→ 应用 policy（**不改 mode**——
    /// setLimits 的「更新即切 active」语义不适用，方案 §8）→ 持久化 → 开关翻转
    /// 重置（§5.2，循环全槽）→ 关闭立即释放 / boost 期立即按新配置 per-slot 重算
    /// 重写（§5.1 D 例外②）→ 开启路径即时 tick（不等 10s 节拍）→ 返回状态。
    func setFanConfig(_ wire: FanWire) throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }

        let base = policy.fan ?? FanPolicy.default
        // 入口先 ensure 探测（R2 P2-5 边界②：防首次 setFan(cpuSkin) 绕过前置拒绝
        // ——sticky 缓存下与 status 组装路径同一次性代价）。
        ensureCpuSkinProbeLocked()
        guard let merged = wire.mergedPolicy(base: base) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setFan 拒绝：风扇参数越界（validated 整包 nil——绝不落半合法策略）"
            ))
            throw FanSetError.invalidParameters
        }
        // cpuSkin 前置拒绝（v1.11 T3 fail-visible：探测结论 sticky false → 错误原文
        // 经 XPC errorReply 透传 App 上屏；探测未决（nil——后端缺席窗口）不拒绝，
        // 由 tick 采样 degraded 路径兜底，不误判「不支持」）。
        if merged.temperatureSource == .cpuSkin, fanState.cpuSkinSupported == false {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setFan 拒绝：本机不支持 CPU 表面温度源（Ts 键探测未命中）"
            ))
            throw FanSetError.cpuSkinUnsupported
        }
        let oldFan = policy.fan
        let wasBoost = fanState.slots.contains { $0.boostActive }
        // F-1 纪律：applyPolicyLocked 之外的直接字段更新——policy.fan 是本命令的
        // 专属修改面（模式/限值不动），与 setLimits/disable/enable 的重建点互斥。
        policy.fan = merged
        persistPolicyLocked(events: &events)
        // 源变更清残留（R1 P3-3：防旧域温度残留一代 tick 参与阈值比较；lastCpuSkin
        // 同清——防旧源显示回显与新源语义错配）。
        if merged.temperatureSource != base.temperatureSource {
            fanState.lastTemperatureC = 0
            fanState.lastCpuSkinTempC = nil
        }

        // 开关翻转重置（方案 §5.2：仅关→开——重新 opt-in = 新意图，R2 P2-A 同判例）：
        // 能力/冲突/进入失败/漂移门循环全槽清零重探；采样计数共享单次清。
        if FanGuard.resetRequired(old: oldFan, new: merged) {
            for i in fanState.slots.indices {
                fanState.slots[i].capability = .unverified
                fanState.slots[i].conflictFlag = false
                fanState.slots[i].entryFailures = 0
                fanState.slots[i].driftTicks = 0
                fanState.slots[i].word = .probing
            }
            fanState.sampleFailures = 0
            fanState.sampleHealthy = true
            // 防御：翻转期残留 boost 理论不可达（boost 只在 enabled 期存在），兜底释放。
            if fanState.slots.contains(where: { $0.boostActive }) {
                releaseFanLocked(events: &events)
            }
            events.append(LogEvent(
                category: .control, level: .info,
                message: "风扇开关已开启：能力/冲突门重置（全槽 \(fanState.slots.count) 扇，重新 opt-in，重探重试）"
            ))
        }
        if !merged.enabled {
            // 关闭 → 立即释放（方案 §11 验收 4：关开关 → 立即释放）。
            if fanState.slots.contains(where: { $0.boostActive }) {
                releaseFanLocked(events: &events)
            }
            for i in fanState.slots.indices {
                fanState.slots[i].word = .off
            }
        } else if wasBoost {
            // boost 期配置变更 → per-slot 立即按新配置重算重写（§5.1 D 例外② + P2-3；
            // 两扇 Mn/Mx 不同目标天然略异——各槽各算各写，比较去重 per-slot）。
            for i in fanState.slots.indices {
                if let target = boostedTargetLocked(index: i, policy: merged, events: &events),
                   let current = fanState.slots[i].targetRPM, target != current {
                    rewriteFanTargetLocked(index: i, target: target, events: &events)
                }
            }
        }
        if merged.enabled {
            // 即时 tick：开启/变更后的重估（进入/释放/驻留语义与下 tick 同源）。
            fanTickLocked(events: &events)
        }
        return buildStatusLocked()
    }

    // MARK: - tick（方案 §5.1 状态机执行体，v1.12 槽位化）

    /// 风扇 tick（10s 节拍；锁内）：温度采样（一次双扇共享）→ F1 在位探测 →
    /// 每槽独立走 fanTickSlotLocked（冲突门/facts/漂移/跟随/决策/副作用/能力推进）。
    func fanTickLocked(events: inout [LogEvent]) {
        // 未启用快速路径：不采样不探测（决策 A 语义直落；释放已由 setFanConfig
        // 即时完成，此处仅为残留防御——理论不可达）。
        guard let fanPolicy = policy.fan, fanPolicy.enabled else {
            if fanState.slots.contains(where: { $0.boostActive }) {
                releaseFanLocked(events: &events)
            }
            return
        }
        let modeActive = policy.mode == "active"

        // 1) 温度采样（v1.11 T3 双源分支；连续失败 ≥3 → sampleHealthy=false（F 行
        //    degraded）——两源共用同一 degraded 机制，R-5 不发明新分支；采样一次
        //    双扇共享——D1 同温同策略）：
        //    battery → BatterySnapshot.temperatureC（与充电热暂停同源，现状零变化）；
        //    cpuSkin → SMC 读 cpuSkinKey（Ts flt 值即 °C，LE 解码直入 °C 口径——
        //    阈值比较统一 °C，与 battery 路径同单位）。探测未命中/客户端缺席按
        //    keyNotFound 抛入 catch（机型事实语义，与采样失败同通道计数降级）。
        var temperatureC = fanState.lastTemperatureC
        do {
            switch fanPolicy.temperatureSource {
            case .battery:
                temperatureC = try monitor.snapshot().temperatureC
            case .cpuSkin:
                guard let client = smcClient, let key = fanState.cpuSkinKey else {
                    throw SMCError.keyNotFound(fanState.cpuSkinKey ?? "Ts0C")
                }
                // 读值同换共享 CpuSkinSensor.read（0.18 T5 D-5b；°C 口径与 battery
                // 路径同单位）。共享 read 非抛（nil = 键缺席/传输故障/尺寸≠4）→
                // malformedReply 抛入统一 catch——本 catch 仅连续失败计数降级不分型，
                // 采样失败语义与旧 try/decode 路径等价（字节数不可知，actual 记 0）。
                guard let valueC = CpuSkinSensor.read(connection: client, key: key), valueC.isFinite else {
                    throw SMCError.malformedReply(key: key, expected: 4, actual: 0)
                }
                temperatureC = valueC
                fanState.lastCpuSkinTempC = temperatureC
            }
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

        // 1b) F1 在位探测（D4 sticky 机型事实；结论转移在本有日志通道处可见化——
        //     status 组装路径同函数静默消费）。
        switch ensureFan1PresenceLocked() {
        case .newlyPresent:
            events.append(LogEvent(
                category: .control, level: .info,
                message: "F1Mn 探测命中：双风扇机型——第二风扇槽位启用（v1.12 D4；同策略独立状态机）"
            ))
        case .newlyAbsent:
            events.append(LogEvent(
                category: .control, level: .info,
                message: "F1Mn 键缺席：单风扇机型——F0 单槽运行（机型事实 sticky，不再重探）"
            ))
        default:
            break
        }

        // 2-7) 每槽独立状态机（D2：同温同策略，进入/冲突/能力全槽位隔离）。
        for i in fanState.slots.indices {
            fanTickSlotLocked(i, policy: fanPolicy, temperatureC: temperatureC,
                              modeActive: modeActive, events: &events)
        }
    }

    /// 单槽 tick（方案 §5.1 步骤 2-7 槽位化）：冲突会话门 → facts 探测缓存 →
    /// 漂移检测 → writeFollowed 证据 → decided → 副作用 → 能力推进，全部以
    /// fanState.slots[index] 为状态承载（D3 诚实隔离：一扇失败不拖累另一扇）。
    private func fanTickSlotLocked(
        _ index: Int, policy fanPolicy: FanPolicy, temperatureC: Double,
        modeActive: Bool, events: inout [LogEvent]
    ) {
        // 2) 冲突会话门（方案 §5.3，per-slot）：该槽冲突置位后本适配器会话内不再
        //    介入此扇（开关翻转重置）；残留 boost 防御性释放（冲突检测路径已释放）。
        if fanState.slots[index].conflictFlag {
            if fanState.slots[index].boostActive {
                releaseSlotLocked(index: index, events: &events)
            }
            fanState.slots[index].word = .conflict
            return
        }

        // 3) facts 探测缓存（方案 §5.1 C' + R1 P3-4，per-slot 代际）：非 boost 期
        //    每 tick 重探；boost 期用缓存，SMCClient 重建（clientGeneration 递增）
        //    后失效重探。类型/尺寸/值语义与预期不符 → fail-visible +
        //    capability=unavailable（方案 §4.1 红线：不做值格式猜测）。
        if fanState.slots[index].factsProbeGeneration != fanState.clientGeneration
            || !fanState.slots[index].boostActive {
            probeFanFactsLocked(index: index, events: &events)
            // boost 期探测失败 → 立即释放该扇，不盲维持（方案 §5.1 不变量注记）。
            if fanState.slots[index].boostActive && fanState.slots[index].facts == nil {
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇 F\(index) boost 期 facts 失效：立即释放（保守，不盲维持）"
                ))
                releaseSlotLocked(index: index, events: &events)
            }
        }

        // 4) 漂移检测（boost 期；方案 §5.3 主方案 = 行为级回读漂移检测，per-slot
        //    lastWrittenTg 基准）：写后下 tick 回读 ≠ 写入值 连续 ≥2 次 → 该槽冲突
        //    标志 + 自动释放该扇 + 会话内不再介入（GO 判据已排除竞争写——直写模式
        //    下漂移即真实外部写者）。漂移计数清零**只由本干净回读分支承担**（P1-1：
        //    重写成功路径不清零，防自家重写掩盖外部写者的跨 tick 累计与自家击穿
        //    冲突检测）。
        if fanState.slots[index].boostActive, let client = smcClient {
            do {
                let back = try client.read(FanKey.tg(index))
                if let last = fanState.slots[index].lastWrittenTg, back != last {
                    noteFanWriteMismatchLocked(
                        index: index,
                        FanBodyError.readbackMismatch(
                            key: FanKey.tg(index), desiredHex: hex(last), actualHex: hex(back)),
                        events: &events, context: "风扇 F\(index) 目标漂移检测"
                    )
                    if fanState.slots[index].conflictFlag { return }
                } else {
                    fanState.slots[index].driftTicks = 0
                }
            } catch let error {
                if FanGuard.isKeyDomainError(error) {
                    // P1-2：Tg 键域错误（keyNotFound/invalidKey）非传输故障——不进
                    // 共享自愈计数；boost 期 Tg 缺席按 degraded 处理走释放（fail-safe）。
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "风扇 F\(index)Tg 回读键域错误（\(error)）：按采样异常处理，释放该扇"
                    ))
                    fanState.slots[index].word = .degraded
                    releaseSlotLocked(index: index, events: &events)
                    return
                }
                noteControlFailureLocked(error, events: &events, context: "风扇 F\(index)Tg 回读")
            }
        }

        // 5) writeFollowed 证据（boost 期；方案 §5.2 路径 A——spike 定版实测可用
        //    且 F1 同构（SMC-NOTES §10 U2'），路径 B 标定不需要）：该扇 Ac ≥ 写入
        //    目标 − 300rpm。Ac 键缺席（keyNotFound）：仅本 tick 无证据（观察窗自会
        //    收口到 unavailable——诚实停用），不进共享自愈计数（P1-2）。
        var writeFollowed = false
        if fanState.slots[index].boostActive, let client = smcClient,
           let target = fanState.slots[index].targetRPM {
            do {
                let acBytes = try client.read(FanKey.ac(index))
                if let ac = FanSMC.decodeRPM(acBytes) {
                    fanState.slots[index].currentRPM = ac
                    writeFollowed = ac >= target - FanGuard.writeFollowFloorRPM
                }
            } catch let error {
                if FanGuard.isKeyDomainError(error) {
                    events.append(LogEvent(
                        category: .control, level: .warn,
                        message: "风扇 F\(index)Ac 回读键域错误（\(error)）：本 tick 无写跟随证据（观察窗收口）"
                    ))
                } else {
                    noteControlFailureLocked(error, events: &events, context: "风扇 F\(index)Ac 回读")
                }
            }
        }

        // 6) 决策（方案 §5.1 求值序 A→B→F→C'→C→G→D→E→S，先命中先输出，由
        //    FanGuard 钉死——签名按键无关，每槽一次；温度/策略/采样健康共享）。
        let decision = FanGuard.decided(
            temperatureC: temperatureC,
            policy: fanPolicy,
            modeActive: modeActive,
            capability: fanState.slots[index].capability,
            boostActive: fanState.slots[index].boostActive,
            boostTicks: fanState.slots[index].boostTicks,
            currentTargetRPM: fanState.slots[index].targetRPM,
            facts: fanState.slots[index].facts,
            sampleHealthy: fanState.sampleHealthy
        )
        switch decision {
        case .idle(let word):
            fanState.slots[index].word = word
        case .enterBoost(let target):
            // 进入 = 两步写（Md=1 → Tg=target，各带回读校验）；失败 → fail-visible
            // 不进入；连续失败 ≥3 → 该扇能力关停（方案 §13 R3 诚实结局）。
            if enterFanBoostLocked(index: index, target: target, events: &events) {
                fanState.slots[index].word = .boost
            }
        case .hold:
            fanState.slots[index].word = .hold
        case .rewrite(let target):
            rewriteFanTargetLocked(index: index, target: target, events: &events)
            if !fanState.slots[index].conflictFlag {
                fanState.slots[index].word = .boost
            }
        case .release(let word):
            if fanState.slots[index].boostActive {
                releaseSlotLocked(index: index, events: &events)
            }
            fanState.slots[index].word = word
        }

        // 7) 能力推进（方案 §5.2；boost 期每 tick，per-slot）：writeFollowed →
        //    verified；观察窗到期（boostTicks ≥ 10）未获证据 → unavailable + 保守
        //    释放该扇（诚实停用，不盲维持 boost）。boostTicks 逐 tick +1（进入置 0、
        //    release 清零，R1 P3-4）。
        if fanState.slots[index].boostActive {
            let advanced = FanGuard.capabilityAdvanced(
                current: fanState.slots[index].capability,
                boostTicks: fanState.slots[index].boostTicks,
                writeFollowed: writeFollowed
            )
            if fanState.slots[index].capability == .unverified && advanced == .unavailable {
                fanState.slots[index].capability = .unavailable
                fanState.slots[index].word = .unsupported
                releaseSlotLocked(index: index, events: &events)
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇 F\(index) 能力观察窗到期（100s）未获写跟随证据：该扇无法自动验证风扇控制——已释放并停用（doctor 可复核）"
                ))
            } else {
                fanState.slots[index].capability = advanced
                // 仅未释放的 boost 期计数（release 已清零——此处不叠加，时序精确）。
                fanState.slots[index].boostTicks += 1
            }
        }
    }

    // MARK: - 释放（五路口统一出口，方案 §6.4；v1.12 循环全槽）

    /// 统一释放出口（五路口：①SIGTERM/SIGINT（restoreAndExit 挂钩）②开关关闭/
    /// disable 模式（setFanConfig 即时 + 决策 A）③决策矩阵 case A/B/E/F（tick）
    /// ④sleepNow 睡眠前释放 ⑤启动恢复分支）——签名与调用点零改动，内部循环槽。
    ///
    /// boost 语境：逐 boost 槽**两步释放**（方案 §2.4 条 3）：FnTg→原值快照（回读
    /// 一致）→ FnMd=0（回读一致）——两步都必须执行，仅停写不停 Md = 未交还；Md
    /// 统一写 0（系统自动规范值），E0 原值仅 spike 还原语境使用（R3 N-2 定版）。
    /// 非 boost 语境：启动/睡眠残留检查（方案 §6.5）——F0Md 恒查；F1Md 仅双槽
    /// 在位时查（单风扇机型零额外 SMC 流量）；≠0 → 写 0 + warn。
    func releaseFanLocked(events: inout [LogEvent]) {
        if fanState.slots.contains(where: { $0.boostActive }) {
            guard smcClient != nil else {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇释放：无 SMC 客户端——Tg/Md 还原不可执行（boost 态保留，残留交启动恢复兜底）"
                ))
                return
            }
            for i in fanState.slots.indices where fanState.slots[i].boostActive {
                releaseSlotLocked(index: i, events: &events)
            }
            return
        }
        // 非 boost 语境：仅风扇已配置时做残留检查（零配置零 SMC 流量）。
        // R1 P1-1：残留检查前先 ensure F1 在位探测——启动恢复路径（五路口⑤）
        // 执行时 slots 恒为 [slot0]（presence 探测挂 status 组装/tick，尚未跑过），
        // 不补探测则双扇 boost 中崩溃残留的 F1Md=1 在启动时永远清不掉（doctor
        // 「可重启清理」指引死循环）。sleepNow/SIGTERM 早于首次 status 的边缘态
        // 同被此覆盖。
        guard policy.fan != nil, let client = smcClient else { return }
        ensureFan1PresenceLocked()
        for i in fanState.slots.indices {
            do {
                let md = try client.read(FanKey.md(i))
                guard md != [0x00] else {
                    let tg = (try? client.read(FanKey.tg(i))).map(hex) ?? "读失败"
                    events.append(LogEvent(
                        category: .control, level: .info,
                        message: "风扇启动检查：F\(i)Md=0（系统自动）F\(i)Tg=\(tg)——无需恢复"
                    ))
                    continue
                }
                try client.write(FanKey.md(i), bytes: [0x00])
                try verifyFanKey(FanKey.md(i), written: [0x00], client: client)
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇启动恢复：F\(i)Md=\(hex(md))≠0（疑似崩溃残留）——已写回 0（系统自动规范值）"
                ))
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇启动恢复：F\(i)Md 读取/写回失败（\(error)）——残留窗口未收口，doctor 风扇行请核对"
                ))
            }
        }
    }

    /// 单槽两步释放（方案 §2.4 条 3）：FnTg→原值快照（回读一致）→ FnMd=0（回读
    /// 一致）。第一步失败 → 继续第二步（Md=0 本身即 fail-safe 方向——系统自动
    /// 接管后 Tg 归系统属主），残留由启动恢复兜底；槽位运行时字段全清。
    private func releaseSlotLocked(index: Int, events: inout [LogEvent]) {
        guard let client = smcClient else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇 F\(index) 释放：无 SMC 客户端——Tg/Md 还原不可执行（boost 态保留，残留交启动恢复兜底）"
            ))
            return
        }
        var releaseOK = true
        if let original = fanState.slots[index].originalTg {
            do {
                try client.write(FanKey.tg(index), bytes: original)
                try verifyFanKey(FanKey.tg(index), written: original, client: client)
            } catch {
                releaseOK = false
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇释放：F\(index)Tg 还原失败（\(error)）——继续 Md=0（失败方向 fail-safe）"
                ))
            }
        }
        do {
            try client.write(FanKey.md(index), bytes: [0x00])
            try verifyFanKey(FanKey.md(index), written: [0x00], client: client)
        } catch {
            releaseOK = false
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇释放：F\(index)Md 还原失败（\(error)）——残留由启动恢复/doctor 兜底"
            ))
        }
        fanState.slots[index].boostActive = false
        fanState.slots[index].boostTicks = 0
        fanState.slots[index].targetRPM = nil
        fanState.slots[index].currentRPM = nil
        fanState.slots[index].lastWrittenTg = nil
        fanState.slots[index].originalTg = nil
        fanState.slots[index].driftTicks = 0
        fanState.slots[index].entryFailures = 0
        if releaseOK {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "风扇已释放：F\(index)Tg→原值 + F\(index)Md=0（交还系统自动）"
            ))
        }
    }

    // MARK: - 副作用内部（进入/重写/探测；全部槽位参数化）

    /// 进入 boost（方案 §2.4 条 2 两步写）：原值快照 → FnMd=1（回读一致）→
    /// FnTg=目标（回读一致）；任一步失败 → fail-visible 不进入 + 回滚（Tg→原值
    /// + Md=0，防「解锁成功但目标写失败」的半进入态滞留，fail-safe 方向）；
    /// 连续失败 ≥3 → 该扇能力置 unavailable（§13 R3 诚实结局——写入静默忽略
    /// 机型的诚实隔离：F1 失败不阻 F0，D3）。
    @discardableResult
    private func enterFanBoostLocked(index: Int, target: Float, events: inout [LogEvent]) -> Bool {
        guard let client = smcClient else { return false }
        let tgBytes = FanSMC.encodeRPM(target)
        do {
            // 原值快照（释放序列的还原目标；读先于一切写）。
            let currentTg = try client.read(FanKey.tg(index))
            fanState.slots[index].originalTg = currentTg
            // 第一步：FnMd=1（回读一致）——Md=0 下 Tg 写会被固件即时拒绝
            // （F1 同构实测 SMC-NOTES §10 U4'；F1Md 锁存 ∈(100,400]ms §10.1，
            // verifyLadder 第二档覆盖）。
            try client.write(FanKey.md(index), bytes: [0x01])
            try verifyFanKey(FanKey.md(index), written: [0x01], client: client)
            // 第二步：FnTg=目标（回读一致）。
            try client.write(FanKey.tg(index), bytes: tgBytes)
            try verifyFanKey(FanKey.tg(index), written: tgBytes, client: client)
        } catch {
            fanState.slots[index].entryFailures += 1
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇 F\(index) 进入 boost 失败（连续第 \(fanState.slots[index].entryFailures) 次）：\(error)——不进入（fail-visible）"
            ))
            rollbackFanEntryLocked(index: index, client: client, events: &events)
            if fanState.slots[index].entryFailures >= FanGuard.sampleFailureLimit {
                fanState.slots[index].capability = .unavailable
                fanState.slots[index].word = .unsupported
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇 F\(index) 进入 boost 连续失败 ≥3 次：该扇能力置为不可用（本机无法介入该扇——M3/M4+ 世代保护的诚实结局，方案 §13 R3；另一扇不受累，D3）"
                ))
            }
            return false
        }
        fanState.slots[index].entryFailures = 0
        fanState.slots[index].boostActive = true
        fanState.slots[index].boostTicks = 0
        fanState.slots[index].targetRPM = target
        fanState.slots[index].lastWrittenTg = tgBytes
        fanState.slots[index].driftTicks = 0
        events.append(LogEvent(
            category: .control, level: .info,
            message: "风扇 F\(index) boost 进入：\(FanKey.md(index))=1 + \(FanKey.tg(index))=\(Int(target))rpm（两步写回读校验通过）"
        ))
        return true
    }

    /// 进入失败回滚（尽力而为：Tg→原值 + Md=0；写失败仅记日志——残留交
    /// 启动恢复/doctor，与释放路径同兜底面）。
    private func rollbackFanEntryLocked(index: Int, client: SMCClient, events: inout [LogEvent]) {
        if let original = fanState.slots[index].originalTg {
            do {
                try client.write(FanKey.tg(index), bytes: original)
                try verifyFanKey(FanKey.tg(index), written: original, client: client)
            } catch {
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇 F\(index) 进入回滚：Tg 还原失败（\(error)）"
                ))
            }
        }
        do {
            try client.write(FanKey.md(index), bytes: [0x00])
            try verifyFanKey(FanKey.md(index), written: [0x00], client: client)
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "风扇 F\(index) 进入回滚：Md 还原失败（\(error)）——残留交启动恢复兜底"
            ))
        }
    }

    /// 带内重写（D 例外族：twoStage 升档跨越 / boost 期配置变更）：仅写 Tg
    /// （Md 已在进入时置 1）——写后回读校验；失败 → 漂移计数（冲突检测通道，
    /// 方案 §5.3）。⚠️ 成功路径**不清 driftTicks**（P1-1）：漂移清零只由 tick
    /// step4 的干净回读 else 分支承担——重写清零会让「重写后同 tick 观察到
    /// 外部漂移」被湮灭，自家重写成为冲突检测的击穿面。
    private func rewriteFanTargetLocked(index: Int, target: Float, events: inout [LogEvent]) {
        guard let client = smcClient else { return }
        let tgBytes = FanSMC.encodeRPM(target)
        do {
            try client.write(FanKey.tg(index), bytes: tgBytes)
            try verifyFanKey(FanKey.tg(index), written: tgBytes, client: client)
            fanState.slots[index].targetRPM = target
            fanState.slots[index].lastWrittenTg = tgBytes
            events.append(LogEvent(
                category: .control, level: .info,
                message: "风扇 F\(index) 目标重写：\(FanKey.tg(index))=\(Int(target))rpm（回读校验通过）"
            ))
        } catch {
            noteFanWriteMismatchLocked(
                index: index, error, events: &events, context: "风扇 F\(index) 目标重写")
        }
    }

    /// 写/回读干扰统一处理（方案 §5.3 行为级漂移检测，per-slot）：计数 +1；
    /// ≥2 → 该槽冲突标志 + 自动释放该扇 + 本适配器会话内不再介入此扇（开关翻转
    /// 重置）。另一扇不受累（D3 诚实隔离——外部写者可能只驱动单扇）。
    private func noteFanWriteMismatchLocked(
        index: Int, _ error: Error, events: inout [LogEvent], context: String
    ) {
        fanState.slots[index].driftTicks += 1
        events.append(LogEvent(
            category: .control, level: .warn,
            message: "\(context)失败（漂移计数 \(fanState.slots[index].driftTicks)/\(FanGuard.conflictDriftTicks)）：\(error)——疑似其他风扇控制工具干预"
        ))
        if fanState.slots[index].driftTicks >= FanGuard.conflictDriftTicks {
            fanState.slots[index].conflictFlag = true
            fanState.slots[index].word = .conflict
            releaseSlotLocked(index: index, events: &events)
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "风扇 F\(index) 检测到其他风扇控制写入者：已释放并暂停该扇介入（会话内不再介入，开关翻转重置）"
            ))
        }
    }

    /// FnMn/FnMx 探测（keyInfo + read，LE 解码——方案 §2.4 条 1 U7 定版；per-slot）。
    /// 成功 → 缓存 + 代际同步；类型/尺寸/值语义异常 → fail-visible + 该扇
    /// capability=unavailable（方案 §4.1：不做值格式猜测）；传输类失败 → 自愈
    /// 计数 + facts 置 nil（下 tick 重试）。
    private func probeFanFactsLocked(index: Int, events: inout [LogEvent]) {
        guard let client = smcClient else {
            if fanState.slots[index].facts != nil {
                fanState.slots[index].facts = nil
                fanState.slots[index].factsProbeGeneration = -1
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "风扇 F\(index) facts 失效：无 SMC 客户端（后端未建立/自愈中）"
                ))
            }
            return
        }
        do {
            let mnInfo = try client.keyInfo(FanKey.mn(index))
            let mxInfo = try client.keyInfo(FanKey.mx(index))
            let mnIsFlt4 = mnInfo.type.trimmingCharacters(in: .whitespaces) == "flt" && mnInfo.size == 4
            let mxIsFlt4 = mxInfo.type.trimmingCharacters(in: .whitespaces) == "flt" && mxInfo.size == 4
            if !(mnIsFlt4 && mxIsFlt4) {
                fanState.slots[index].capability = .unavailable
                fanState.slots[index].facts = nil
                fanState.slots[index].factsProbeGeneration = -1
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇 F\(index) 键类型/尺寸与预期不符（F\(index)Mn=\(mnInfo.type)/\(mnInfo.size)B，F\(index)Mx=\(mxInfo.type)/\(mxInfo.size)B；预期 flt/4B）——该扇能力置为不可用（fail-visible，不做值格式猜测）"
                ))
                return
            }
            let mnBytes = try client.read(FanKey.mn(index))
            let mxBytes = try client.read(FanKey.mx(index))
            guard let mn = FanSMC.decodeRPM(mnBytes), let mx = FanSMC.decodeRPM(mxBytes),
                  mn.isFinite, mx.isFinite, mn > 0, mx > 0, mn <= mx else {
                fanState.slots[index].capability = .unavailable
                fanState.slots[index].facts = nil
                fanState.slots[index].factsProbeGeneration = -1
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "风扇 F\(index) 转速值语义异常（Mn/Mx 解码失败、非正或倒挂）——该扇能力置为不可用（fail-visible）"
                ))
                return
            }
            fanState.slots[index].facts = FanFacts(minRPM: mn, maxRPM: mx)
            fanState.slots[index].factsProbeGeneration = fanState.clientGeneration
        } catch let error {
            if FanGuard.isKeyDomainError(error) {
                // P1-2：键缺席（keyNotFound/invalidKey）是机型事实——不进共享自愈
                // 计数（防周期性拆除充电后端）；直接能力置不可用（B 行接管 =
                // 「本机不支持」诚实停用该扇）。
                if fanState.slots[index].capability != .unavailable {
                    fanState.slots[index].capability = .unavailable
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "风扇 F\(index) 键缺失（\(error)）——该扇能力置为不可用（本机不支持）"
                    ))
                }
                fanState.slots[index].facts = nil
                fanState.slots[index].factsProbeGeneration = -1
                return
            }
            noteControlFailureLocked(error, events: &events, context: "风扇 F\(index) facts 探测")
            fanState.slots[index].facts = nil
            fanState.slots[index].factsProbeGeneration = -1
        }
    }

    /// boost 期配置变更的 per-slot 目标重算（facts 失效 → nil 跳过——tick 的 C'
    /// 路径接管）。两扇 Mn/Mx 不同：各槽用各自 facts 算各自目标（D1——百分比
    /// 语义下目标天然略异，与系统自身异值驱动两扇同构，SMC-NOTES §8.2）。
    private func boostedTargetLocked(index: Int, policy: FanPolicy, events: inout [LogEvent]) -> Float? {
        guard let facts = fanState.slots[index].facts else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "setFan F\(index) boost 期重算：facts 不可用，暂时跳过（tick 探测成功后自动收敛）"
            ))
            return nil
        }
        return FanGuard.targetRPM(policy: policy, facts: facts, temperatureC: fanState.lastTemperatureC)
    }

    /// 写后回读校验（红线 3 同源）：不一致 → 锁存重试阶梯后仍不一致才抛
    /// FanBodyError（fail-visible 语义不变，调用方按 fail-visible/漂移计数处置，
    /// 绝不静默）。
    ///
    /// 实测依据（2026-09-04 真机探针）：F0Md 写入（kr=0 result=0）后 T+10ms
    /// 回读仍是旧值 0、T+100ms 已锁存为新值 1——模式寄存器有 ≤100ms 量级的
    /// 锁存延迟，写后立即回读必然撞在锁存完成之前（0.5.0 能力误判根因：进入/
    /// 还原写全部误报「写后回读不一致」→ 连续失败 ≥3 → 能力置 unavailable）；
    /// 还原写（Md=0）同样受此影响。故采用锁存重试阶梯：写后依次延时
    /// [100, 300, 800]ms（FanSMC.verifyLadderMs 同源）共三次回读，
    /// 任一次读值 == 写入值即通过。F1 实测增补（SMC-NOTES §10.1）：F1Md 锁存
    /// ∈(100,400]ms——第二档覆盖，同阶梯直接适用。
    ///
    /// 锁内持有（线程/锁纪律）：单次校验最坏 100+300+800 = 1.2s 锁内持有，
    /// 期间心跳/XPC 排队等待——可接受。v1.12 双扇口径：同一 tick 双扇串行转移
    /// 写最坏（双扇进入全阶梯耗尽 + 回滚同耗尽）≈ 9.6s，逼近 10s tick 节拍——
    /// 仅极端故障形态可达（F1Md 锁存实测落第二/三档，常态进入 ≈0.6-1.4s），
    /// 心跳延一代可接受不调参；且阶梯仅发生在 boost 进入两步写/进入回滚/释放
    /// 两步/重写等**稀有转移写**，非每 tick（tick 常规路径 hold/idle 不写、
    /// 漂移检测是只读比对不受影响）。禁止在 tick 常规路径使用本阶梯。
    private func verifyFanKey(_ key: String, written: [UInt8], client: SMCClient) throws {
        var lastMismatch: FanBodyError?
        for delayMs in FanSMC.verifyLadderMs {
            Thread.sleep(forTimeInterval: TimeInterval(delayMs) / 1000.0)
            let back = try client.read(key)
            guard back == written else {
                lastMismatch = FanBodyError.readbackMismatch(key: key, desiredHex: hex(written), actualHex: hex(back))
                continue
            }
            return
        }
        throw lastMismatch ?? FanBodyError.readbackMismatch(key: key, desiredHex: hex(written), actualHex: hex(written))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
