import Foundation

// MARK: - Phase 5 v1.1 风扇决策矩阵（方案 §5）—— 纯函数，CellarCoreCheck 穷举钉死

/// 风扇决策矩阵与能力推进（方案 §5.1/§5.2；与 ThermalGuard 同构分层：daemon
/// 只做副作用（两步写/两步释放/探测/日志），全部语义决策经本文件转移）。
///
/// 不变量（实现侧防御，方案 §5.1）：`boostActive ⟹ facts ≠ nil ∧ capability ≠
/// .unavailable ∧ enabled ∧ modeActive`——违反即为输入实现错误，矩阵防御性
/// release（A/B/F/C' 行在 boost 输入下全部输出 release，先命中先输出）。
public enum FanGuard {
    /// 能力观察窗（方案 §5.2）：unverified 最长观察 10 tick（10s×10 = 100s）。
    public static let capabilityObservationTicks = 10
    /// 写跟随路径 A 下限（方案 §2.3 GO③ / §5.2）：F0Ac ≥ 写入目标 − 300rpm。
    public static let writeFollowFloorRPM: Float = 300
    /// 采样连续失败上限（方案 §6.6）：≥3 → sampleHealthy=false（F 行 degraded）。
    public static let sampleFailureLimit = 3
    /// 冲突漂移阈值（方案 §5.3）：写后回读 ≠ 写入值 ≥2 次 → 冲突 + 会话内暂停。
    public static let conflictDriftTicks = 2

    /// 决策矩阵入口（**按序求值、先命中先输出**；求值序 A→B→F→C'→C→G→D→E→S
    /// 钉死——门槛/健康检查先于目标计算，方案 §5.1 表；测试含求值序反例断言）。
    /// - temperatureC：电池温度（BatterySnapshot.temperatureC，与充电热暂停同源，
    ///   方案 §6 温度源单点；daemon 采样失败时传上次值 + sampleHealthy=false——
    ///   F 行在温度比较前短路，值不参与判定）。
    /// - currentTargetRPM：当前写入目标（boost 期最近一次成功写入；daemon 传
    ///   fanState.targetRPM）。D 例外① 去重判据（P1-1）：目标未变 → hold 不写。
    /// - 输出词：`.enterBoost`/`.rewrite` 的目标 = targetRPM 纯函数
    ///   （clamp 进 [Mn, Mx]）。
    public static func decided(
        temperatureC: Double,
        policy: FanPolicy,
        modeActive: Bool,
        capability: FanCapability,
        boostActive: Bool,
        boostTicks: Int,
        currentTargetRPM: Float?,
        facts: FanFacts?,
        sampleHealthy: Bool
    ) -> FanDecision {
        // A：开关关闭 / daemon 停用的交还路径（boostActive ? release : idle，
        // 方案 §5.1 行 1）。状态词 off 两义共用：开关关闭与停用都是「不介入」。
        if !policy.enabled || !modeActive {
            return boostActive
                ? .release(stateWord: .off)
                : .idle(stateWord: .off)
        }
        // B：能力不可用——补格（R1 P1-1a）：boost 期同样交还（状态词 unsupported）。
        if capability == .unavailable {
            return boostActive
                ? .release(stateWord: .unsupported)
                : .idle(stateWord: .unsupported)
        }
        // F：采样异常——**优先级高于 D**（R1 P1-1c）：采样失败即交还的保护面
        // 不被带内驻留吞掉（WP1 教训同型）；不进入（? idle）。
        if !sampleHealthy {
            return boostActive
                ? .release(stateWord: .degraded)
                : .idle(stateWord: .degraded)
        }
        // C'：facts 未探测/失效——非 boost 期每 tick 重探、成功即缓存（R1 P3-4
        // 探测时机）；boost 期 facts 失效**不盲维持**——不变量防御路径（R3
        // N-1 分档），状态词 probing。
        if facts == nil {
            return boostActive
                ? .release(stateWord: .probing)
                : .idle(stateWord: .probing)
        }
        // C：进入 boost（!boostActive ∧ t ≥ 阈值 ∧ 策略可执行；minRaise → 状态词
        // 「暂不支持该策略」，v1.1 §0.5b——枚举保留、语义不实现）。
        if !boostActive && temperatureC >= Double(policy.thresholdCentiC) / 100 {
            if policy.strategy == .minRaise {
                return .idle(stateWord: .strategyUnsupported)
            }
            return .enterBoost(targetRPM: targetRPM(policy: policy, facts: facts!, temperatureC: temperatureC))
        }
        // G：boost 期能力观察窗到期（capability == .unverified ∧ boostTicks ≥ 10）
        // → hold——sticky 转移由 §5.2 推进（daemon 侧每 boost tick 调用
        // capabilityAdvanced；本行仅保证到期 tick 参与常规判定链）。
        if boostActive && capability == .unverified && boostTicks >= capabilityObservationTicks {
            return .hold
        }
        // D：带内驻留（boostActive ∧ t ≥ 阈值−滞回 → **带内不写**；含 t ≥ 阈值的
        // 热态驻留）。例外族（允许重写）：①twoStage 升档跨越（t ≥ 阈值+rise，
        // 且**目标已变化** → rewrite——P1-1 去重：目标不变仍按 hold，消除「boost
        // 期每 tick 常态写」的 §0.5c 违规形态；升档只发生在跨线那一 tick）；②boost
        // 期 setFan 配置变更——后者在 daemon 侧 setFanConfig 直接触发（本函数无
        // 配置变更输入，不落行）。twoStage 降档**不写**（hold 现值直到 release——
        // 降档写徒增抖写面，R1 P3-4）。
        if boostActive && temperatureC >= Double(policy.thresholdCentiC - policy.releaseHysteresisCentiC) / 100 {
            if policy.strategy == .twoStage
                && temperatureC >= Double(policy.thresholdCentiC + policy.stage2RiseCentiC) / 100 {
                let stage2Target = targetRPM(policy: policy, facts: facts!, temperatureC: temperatureC)
                if stage2Target != currentTargetRPM {
                    return .rewrite(targetRPM: stage2Target)
                }
                return .hold
            }
            return .hold
        }
        // E：释放（boostActive ∧ t < 阈值−滞回 → 交还系统；次态 idle，状态词
        // automatic——交还后即正常自动态）。
        if boostActive {
            return .release(stateWord: .automatic)
        }
        // S：静息显式格（!boostActive ∧ t < 阈值——最常见的静息输入显式落格，R1
        // P1-1b）。
        return .idle(stateWord: .automatic)
    }

    /// 目标转速纯函数（方案 §4.1 三策略语义；全部 clamp 进 [F0Mn, F0Mx]——
    /// **boost-only 红线**（方案 §6.2）：值取自运行时探测 facts，绝不硬编码机型
    /// 数值；绝不写低于基线的值去压转速。minRaise 语义不实现（v1.1 拒绝——
    /// C 行拦截后本函数不可达，此处仅保持可编译的防御语义）。
    public static func targetRPM(policy: FanPolicy, facts: FanFacts, temperatureC: Double) -> Float {
        let minRPM = facts.minRPM
        let maxRPM = facts.maxRPM
        func clamped(_ v: Float) -> Float { min(max(v, minRPM), maxRPM) }
        switch policy.strategy {
        case .constantSpeed, .minRaise:
            return clamped(Float(policy.speedPercent) / 100 * maxRPM)
        case .twoStage:
            let stage2Cross = Double(policy.thresholdCentiC + policy.stage2RiseCentiC) / 100
            if temperatureC >= stage2Cross {
                return clamped(Float(policy.stage2Percent) / 100 * maxRPM)
            }
            return clamped(Float(policy.speedPercent) / 100 * maxRPM)
        case .emergency:
            return maxRPM
        }
    }

    /// 能力推进（方案 §5.2 纯函数；sticky，不回落）：
    /// - unverified + writeFollowed → verified（进入 boost 后首个可信证据 tick
    ///   即推进；writeFollowed 由 daemon 侧路径 A（Ac ≥ 目标−300rpm）测得）；
    /// - unverified + 观察窗到期（boostTicks ≥ 10）∧ !writeFollowed → unavailable
    ///   （daemon 在推进到 unavailable 的 tick 执行保守 release + 状态行
    ///   「本机不支持」——诚实失败，不盲维持 boost，§13 R3）；
    /// - unavailable 恒 unavailable（sticky）；**仅用户关→开开关（enabled 翻转）
    ///   时 daemon 重置为 unverified 重探**（resetRequired 判定，本函数不回落）。
    public static func capabilityAdvanced(
        current: FanCapability, boostTicks: Int, writeFollowed: Bool
    ) -> FanCapability {
        switch current {
        case .verified:
            return .verified
        case .unavailable:
            return .unavailable
        case .unverified:
            if writeFollowed { return .verified }
            if boostTicks >= capabilityObservationTicks { return .unavailable }
            return .unverified
        }
    }

    /// 开关翻转判定（方案 §5.2「仅用户关→开开关时重置」）：enabled 自 false 翻
    /// 转为 true → daemon 重置能力/冲突门（重新 opt-in = 新意图，R2 P2-A 同判例；
    /// 未配置过（nil）视作旧值 false）。
    public static func resetRequired(old: FanPolicy?, new: FanPolicy) -> Bool {
        (old?.enabled ?? false) == false && new.enabled == true
    }

    /// 风扇键域错误分流（code-review P1-2）：`keyNotFound`/`invalidKey` = 键缺席/
    /// 键名非法——**机型事实、稳定**，不得进共享传输失败计数（否则键缺席机型每
    /// tick 计数、≥3 触发 SMCClient 重建，周期性地把充电后端一并拆除）；
    /// 仅 `transportFailure` 类传输故障走共享自愈（noteControlFailureLocked）。
    /// daemon 探针/回读 catch 分流与本函数同源；FanDomain 纯逻辑层断言。
    public static func isKeyDomainError(_ error: Error) -> Bool {
        guard let smcError = error as? SMCError else { return false }
        switch smcError {
        case .keyNotFound, .invalidKey:
            return true
        default:
            return false
        }
    }
}