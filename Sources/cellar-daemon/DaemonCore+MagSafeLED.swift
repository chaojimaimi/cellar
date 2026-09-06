import Foundation
import CellarCore

// MARK: - Phase 5 v1.8 MagSafe LED 控制（方案 §3；全部锁内）

/// MagSafe LED 状态机的 daemon 侧实现（扩展文件拆分照 DaemonCore+Fan.swift 先例：
/// DaemonCore.swift 行数纪律；可见性/属主不变量同款——cellar-daemon 为 executable
/// target，internal 符号模块外不可达）。语义决策全部经 CellarCore.MagSafeLED
/// correctionDecision（CellarCoreCheck 矩阵穷举钉死）转移，本扩展只做副作用
///（写 ACLC、探测、日志）与运行时状态（MagSafeLedRuntimeState，存储在
/// DaemonCore.swift 的单一属性——扩展不能加存储属性）。
///
/// 锁纪律：复用 DaemonCore.lock 单一锁（禁新锁）；30s 心跳 tick 内短临界区
///（1 次读 + 条件性 1 次写 + 单次 ~100ms 延迟回读——锁预算 R1 P2-1；全重试阶梯
/// 禁入 tick 常规路径，照风扇禁令 DaemonCore+Fan.swift:601-604）。
extension DaemonCore {
    // MARK: - setMagSafeLed XPC（方案 §3）

    /// setMagSafeLed（值域 0/1/3/4 已由 XPCServer 臂白名单校验）：system(0) =
    /// persist 清除 + 缓存复位 + 写灯 0 交还系统；非 0 = persist + 缓存更新 +
    /// **disabled 期不写灯**（照风扇「disable 保留 policy 值，enable 后 tick 重申」
    /// 先例）/ active 期立即写（全重试阶梯 [100,300,800]ms 写后回读——稀有转移
    /// 写允许阶梯）。开关翻转重置冲突计数器/锁存（用户改模式 = 新意图，R1 P1-2）。
    func setMagSafeLed(_ rawMode: UInt64) throws -> DaemonStatus {
        var events: [LogEvent] = []
        lock.lock()
        defer {
            lock.unlock()
            emit(events)
        }
        // XPC 臂白名单已保证 0/1/3/4；防御性二次收敛（越域 → 拒绝，不可达）。
        guard let mode = MagSafeLED.validating(UInt8(truncatingIfNeeded: rawMode)) else {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "setMagSafeLed 拒绝：模式值越域（\(rawMode)）"
            ))
            throw MagSafeSetError.invalidParameters
        }
        let oldMode = MagSafeLED.validating(policy.magSafeLedMode)
        let hadConfiguredMode = oldMode != nil && oldMode != .system
        if oldMode != mode {
            // 新意图：冲突计数器/锁存清零（照风扇 resetRequired 语义）。
            magSafeLedState.latchState = MagSafeLED.LatchState()
        }

        if mode == .system {
            // 切回跟随系统：**先恢复写、后清配置**（review P1-2——release 的 guard
            // 语义是「已配置才恢复」读 policy，置 nil 后调用则恢复写永不可达）。
            // 恢复写 0x00 不做字节等值校验（review P2——0x00 是命令值非锁存态，
            // spike 判据④实证系统会重写为色值；写成功即认，D2 判据原文）。
            if hadConfiguredMode, magSafeLedState.supportState == .supported,
               let client = smcClient {
                do {
                    try client.write(MagSafeLED.aclcKey, bytes: [0x00])
                    events.append(LogEvent(
                        category: .control, level: .info,
                        message: "MagSafe LED 已交还系统（ACLC=0x00，写成功即认）"
                    ))
                } catch {
                    events.append(LogEvent(
                        category: .control, level: .error,
                        message: "MagSafe LED 交还系统写失败（\(error)）——残留交系统下次充放覆写自愈"
                    ))
                }
            }
            policy.magSafeLedMode = nil
            persistPolicyLocked(events: &events)
            magSafeLedState.readbackRaw = nil
            magSafeLedState.lastTickAction = .none
            events.append(LogEvent(
                category: .control, level: .info,
                message: "MagSafe LED：跟随系统（配置已清除）"
            ))
            return buildStatusLocked()
        }

        policy.magSafeLedMode = mode.rawValue
        persistPolicyLocked(events: &events)
        // 旧回读证据随新意图作废（未读过形态——计费判据从本 tick 起算）。
        magSafeLedState.readbackRaw = nil
        magSafeLedState.lastTickAction = .none

        guard policy.mode == "active" else {
            events.append(LogEvent(
                category: .control, level: .info,
                message: "MagSafe LED：daemon disabled 期仅保存配置（写灯交 enable 后 tick 重申）"
            ))
            return buildStatusLocked()
        }
        guard magSafeLedState.supportState == .supported, let client = smcClient else {
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "MagSafe LED：键能力未决/不支持——配置已保存，写灯跳过"
            ))
            return buildStatusLocked()
        }
        do {
            try client.write(MagSafeLED.aclcKey, bytes: [mode.rawValue])
            try verifyAclcLocked(written: mode.rawValue, client: client)
            magSafeLedState.readbackRaw = mode.rawValue
            magSafeLedState.lastTickAction = .writeVerified
            events.append(LogEvent(
                category: .control, level: .info,
                message: "MagSafe LED：已写 \(hexByte(mode.rawValue))（写后回读校验通过）"
            ))
        } catch {
            magSafeLedState.lastTickAction = .writeFailed
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "MagSafe LED 写入失败（\(error)）——模式已保存，tick 将重试"
            ))
        }
        return buildStatusLocked()
    }

    // MARK: - wire 状态（buildStatusLocked 恒填调用）

    /// MagSafe LED wire 状态（**恒填**——内存缓存组装零读盘；v1.7 P1 教训：
    /// 不得只在部分回包填充，否则变更类回包经 App ingest 覆盖触发「旧 daemon」
    /// 误判闪断）。
    func magSafeLedStatusLocked() -> MagSafeLEDStatus {
        var wire = MagSafeLED.wireStatus(
            mode: MagSafeLED.validating(policy.magSafeLedMode),
            supportState: magSafeLedState.supportState,
            readbackRaw: magSafeLedState.readbackRaw
        )
        wire.conflict = magSafeLedState.latchState.latched
        return wire
    }

    // MARK: - tick 纠偏（方案 §3）

    /// 30s 心跳纠偏（performTickLocked 尾部调用——各早退分支之后，采样/控制键
    /// 失败 tick 顺延纠偏可接受）：能力未决重探 → 单次回读 → correctionDecision
    /// → 副作用。写后单次 ~100ms 延迟回读（锁存窗实测：风扇 T+10ms 旧值 /
    /// T+100ms 新值；ACLC spike 阶梯内一致同源假设）。
    func magSafeLedTickLocked(events: inout [LogEvent]) {
        // 0) 能力探测：undecided 每 tick 重探（心跳重探 + SMC client 重建后自然
        //    重探，方案 §0-D6）；unsupported sticky 不重探；supported 已立不重探。
        if magSafeLedState.supportState == .undecided {
            probeMagSafeLedLocked(events: &events)
        }
        guard magSafeLedState.supportState == .supported else {
            magSafeLedState.lastTickAction = .none
            return
        }
        // 配置快速路径：跟随系统（policy 无模式）→ 无介入（缓存回读照常维护，
        // 供 doctor 展示系统态；读失败静默——系统自管理域）。
        guard let mode = MagSafeLED.validating(policy.magSafeLedMode), mode != .system,
              let client = smcClient else {
            magSafeLedState.lastTickAction = .none
            if let client = smcClient {
                magSafeLedState.readbackRaw = (try? client.read(MagSafeLED.aclcKey))?.first
            }
            return
        }
        // 1) 回读（决策输入）。
        let readback: UInt8?
        do {
            readback = try client.read(MagSafeLED.aclcKey).first
            magSafeLedState.readbackRaw = readback
        } catch {
            if FanGuard.isKeyDomainError(error) {
                // 键域错误 = 机型事实变化（理论不可达——sticky unsupported 已挡）；
                // fail-visible 停介入。
                magSafeLedState.supportState = .unsupported
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "MagSafe LED 键域错误（\(error)）：能力置为不支持（停介入）"
                ))
                return
            }
            noteControlFailureLocked(error, events: &events, context: "MagSafe LED 回读")
            readback = nil
        }
        // 2) 决策（纯函数，M1 矩阵穷举钉死——计费 gating/锁存/自动解除全在此）。
        let (outcome, newLatch) = MagSafeLED.correctionDecision(
            mode: mode,
            modeActive: policy.mode == "active",
            supportState: magSafeLedState.supportState,
            lastReadbackRaw: readback,
            lastTickAction: magSafeLedState.lastTickAction,
            latchState: magSafeLedState.latchState
        )
        magSafeLedState.latchState = newLatch
        // 3) 副作用。
        switch outcome {
        case .write(let expected):
            do {
                try client.write(MagSafeLED.aclcKey, bytes: [expected.rawValue])
                Thread.sleep(forTimeInterval: 0.1)
                let back = try client.read(MagSafeLED.aclcKey).first
                magSafeLedState.readbackRaw = back
                magSafeLedState.lastTickAction = (back == expected.rawValue) ? .writeVerified : .writeFailed
                if back != expected.rawValue {
                    events.append(LogEvent(
                        category: .control, level: .warn,
                        message: "MagSafe LED 纠偏写后回读不一致（期望 \(hexByte(expected.rawValue))，实际 \(back.map(hexByte) ?? "读失败")）——下 tick 重试"
                    ))
                }
            } catch {
                magSafeLedState.lastTickAction = .writeFailed
                events.append(LogEvent(
                    category: .control, level: .warn,
                    message: "MagSafe LED 纠偏写失败（\(error)）——下 tick 重试"
                ))
            }
        case .skip:
            magSafeLedState.lastTickAction = .skipped
        case .idle:
            magSafeLedState.lastTickAction = .none
        case .conflictLatch:
            magSafeLedState.lastTickAction = .skipped
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "检测到其他 MagSafe LED 写入者（疑似 MagHue 类工具）：已暂停纠偏（连续干净回读自动恢复；doctor 已置冲突态）"
            ))
        }
    }

    // MARK: - 恢复红线（方案 §0-D3）

    /// 恢复路口（restoreAndExit / disable / uninstall 调用）：配置 mode≠system 且
    /// supported → 写 0x00 交还系统。**写成功即认，不做字节等值校验**（review P2：
    /// 0x00 是命令值非锁存态——spike 判据④实证写 00 后系统重写为当前色值，等值
    /// 校验必报假阴性；方案 §7-M0 判据④原文）。写失败 error 日志不阻断（残留交
    /// 系统下次充放覆写自愈）。crash/OOM 不承诺；**不设启动残留检查**（寄存器
    /// 常态是色值，启动写 0 会踩掉系统语义与第三方写入——方案 §0-D3 R1 P1-5）。
    func releaseMagSafeLedLocked(events: inout [LogEvent]) {
        guard let mode = MagSafeLED.validating(policy.magSafeLedMode), mode != .system,
              magSafeLedState.supportState == .supported, let client = smcClient else { return }
        do {
            try client.write(MagSafeLED.aclcKey, bytes: [0x00])
            events.append(LogEvent(
                category: .control, level: .info,
                message: "MagSafe LED 已交还系统（ACLC=0x00，写成功即认）"
            ))
        } catch {
            events.append(LogEvent(
                category: .control, level: .error,
                message: "MagSafe LED 交还系统失败（\(error)）——残留交系统下次充放覆写自愈"
            ))
        }
    }

    // MARK: - 能力探测（方案 §0-D6 分流）

    /// 能力探测分流（照风扇 isKeyDomainError 先例）：keyInfo 成功且 ui8/1B →
    /// supported；键域缺席（keyNotFound）→ **unsupported sticky**（真不支持，
    /// 不重探）；类型/尺寸不符 → unsupported（fail-visible）；传输失败 →
    /// **undecided**（心跳重探，SMC client 重建后自然重探）。⚠️ internal——
    /// startup 启动探测调用（照 persistPolicyLocked v1.1 放宽先例）。
    func probeMagSafeLedLocked(events: inout [LogEvent]) {
        guard let client = smcClient else {
            magSafeLedState.supportState = .undecided
            return
        }
        do {
            let info = try client.keyInfo(MagSafeLED.aclcKey)
            let isUi8 = info.type.trimmingCharacters(in: .whitespaces) == "ui8" && info.size == 1
            if isUi8 {
                if magSafeLedState.supportState != .supported {
                    magSafeLedState.supportState = .supported
                    events.append(LogEvent(
                        category: .control, level: .info,
                        message: "MagSafe LED：ACLC 键在位（ui8/1B）——LED 控制可用"
                    ))
                }
            } else {
                magSafeLedState.supportState = .unsupported
                events.append(LogEvent(
                    category: .control, level: .error,
                    message: "MagSafe LED 键类型/尺寸与预期不符（\(info.type)/\(info.size)B，预期 ui8/1B）——能力置为不支持（fail-visible）"
                ))
            }
        } catch {
            if FanGuard.isKeyDomainError(error) {
                if magSafeLedState.supportState != .unsupported {
                    magSafeLedState.supportState = .unsupported
                    events.append(LogEvent(
                        category: .control, level: .info,
                        message: "MagSafe LED 键缺失（\(error)）——本机不支持（无 MagSafe 充电口机型常态）"
                    ))
                }
                return
            }
            magSafeLedState.supportState = .undecided
            events.append(LogEvent(
                category: .control, level: .warn,
                message: "MagSafe LED 能力探测失败（\(error)）——置未决态，下 tick 重探"
            ))
        }
    }

    // MARK: - 内部

    /// 写后回读校验（照 verifyFanKey 锁存重试阶梯 [100,300,800]ms——ACLC 同类
    /// 寄存器锁存窗，v1.8 spike 阶梯内回读一致实证）。仅限 set/恢复等**稀有转移
    /// 写**；tick 常规路径禁用（R1 P2-1，照风扇禁令）。
    private func verifyAclcLocked(written: UInt8, client: SMCClient) throws {
        var lastBack: UInt8?
        for delayMs in FanSMC.verifyLadderMs {
            Thread.sleep(forTimeInterval: TimeInterval(delayMs) / 1000.0)
            lastBack = try client.read(MagSafeLED.aclcKey).first
            if lastBack == written { return }
        }
        throw MagSafeWriteError.readbackMismatch(
            desired: hexByte(written),
            actual: lastBack.map(hexByte) ?? "读失败"
        )
    }

    private func hexByte(_ value: UInt8) -> String {
        String(format: "0x%02X", value)
    }
}

/// MagSafe LED 运行时状态（DaemonCore.swift 的单一存储属性 `var magSafeLedState`；
/// 本文件定义——扩展不能加存储属性。崩溃重启即清零：KeepAlive 秒级重拉后按
/// policy 重申（tick 纠偏）+ 系统下次充放覆写兼任残留自愈——方案 §0-D3 尽力恢复）。
struct MagSafeLedRuntimeState: Sendable {
    /// 键域能力（undecided = 未决，tick 心跳重探；unsupported sticky 停探）。
    var supportState: MagSafeLED.SupportState = .undecided
    /// 最近一次 ACLC 回读原始字节（nil = 未读过）。
    var readbackRaw: UInt8?
    /// 上一 tick 纠偏动作（correctionDecision 计费判据回路，R2 N1）。
    var lastTickAction: MagSafeLED.CorrectionAction = .none
    /// 冲突锁存跨 tick 状态（漂移计数 / 干净 streak / 锁存位）。
    var latchState = MagSafeLED.LatchState()
}

/// setMagSafeLed 拒绝（message = 用户可读文案；XPC errorReply 原文透传）。
enum MagSafeSetError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 参数越域（XPC 臂白名单后理论不可达——防御面）。
    case invalidParameters

    public var description: String {
        switch self {
        case .invalidParameters: return "MagSafe LED 模式参数越界（0/1/3/4）"
        }
    }
}

/// MagSafe LED 写回读校验失败（字节级不一致；description 进日志）。
enum MagSafeWriteError: Error, Equatable, Sendable, CustomStringConvertible {
    case readbackMismatch(desired: String, actual: String)

    public var description: String {
        switch self {
        case .readbackMismatch(let desired, let actual):
            return "ACLC 写后回读不一致（期望 \(desired)，实际 \(actual)）"
        }
    }
}
