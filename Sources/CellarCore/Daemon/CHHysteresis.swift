import Foundation

// MARK: - 0.21.0 §2 CHIE 迟滞备用后端（方案 §2.2/§2.3/§2.4；CellarCore 决策纯函数）
//
// 降级链第二生命线（§2.1）：topoff active → strike×3 → degraded → opt-in ∧ CHIE
// 可写 → CHIE 迟滞执法；不可用（写探针失败/持续合盖/热限制）→ 落 80 编排钳（现状）。
//
// 分层（照 Topoff/NativeOrchestration 先例）：决策纯函数全部在本文件（CellarCoreCheck
// 场景域钉死），daemon 侧只做副作用（CHIE 写经 DischargeAdapterControl 面、persistLog、
// 簿记）。**不直接复用 OneShotTrack.tickDischarge**（那是动作轨道绑定；地板 = percent ≤
// 60 非「电流地板」，热 = 40°C，合盖输入来自 ClamshellGate 既有探测——R1-P2-1 措辞
// 更正）。
//
// 执法语义（方案 §2.2 判据逐字）：`percent > target + 滞回` → CHIE 0x8（适配器禁用）；
// `percent ≤ target` → 0x00（恢复使能）。带内（(target, target+滞回]）→ 无动作（滞回
// 防抖——每次执法写 = 一次微充放循环，带宽即循环成本阀门，§2.3「约 1 循环/天」口径）。
// 恢复后 agent 若仍不跟随充电继续 → 再越带 → 再 0x8（自闭环；S1 实证 27 存活）。
//
// ⚠️ **迟滞 × §3 校准共存：无共存门（0.21 M2 review P3-2 随批登记的已知交互）**：
// 迟滞挂载期（degraded 稳态执法）percent 被钳在 target+滞回 ≤ 92 → §3.1 指纹
// `percent ≥ 95 ∧ charging` 永不满足 → calibrationSuspected 结构性不可达——校准抑制
// 在「topoff 已降级 + 迟滞挂载」配置下让位于备用执法（方案 §2.2 互斥矩阵本未列校准；
// 降级语境下 topoff 已失效，校准爬坡与备用执法的取舍 = 备用执法优先）。求序上迟滞
// tick 先于 daemon 抑制早退（DaemonCore+Topoff.topoffConvergenceRouteLocked）——
// 挂载态不被抑制冻结。诚实登记：不为此加互斥门（指纹在该配置不可达，门无消费场景；
// 迟滞退出——热终止/自愈恢复/开关关——后指纹自然恢复可达）。

/// 迟滞通道 XPC wire 键（照 OrchestrationWireKeys 先例：XPCServer 臂 / DaemonXPCClient /
/// validateRequest 三处同源；§2.4 R2-P2-3 开关通道钉死）。
public enum CHHysteresisWireKeys {
    /// setChHysteresisEnabled 命令字面量（开关唯一写入通道；旧 daemon → 「未知命令」
    /// daemonError——App detectStaleBeforeReject 升级提示既有闭环）。
    public static let command = "setChHysteresisEnabled"
    /// 开关单键（UINT64 0/1——照 orchestrationEnabled/auto 同键型，R2-P3 统一纪律）。
    public static let enabled = "chHysteresisEnabled"

    /// 开关值域（0/1 白名单——与 OrchestrationWireKeys.validEnabled 同尺）。
    public static func validEnabled(_ raw: UInt64) -> Bool { raw <= 1 }
}

/// CHIE 迟滞通道常量与 tick 决策纯函数（无状态无 IO；daemon 侧状态由调用方持有传入）。
public enum CHHysteresis {
    /// 地板（百分位）：percent ≤ 60 不滞留禁用（LimitPolicy 保证 target ≥60，本臂为
    /// 防御性恢复——禁用态滞留地板下电池只放不充）。
    public static let percentFloor = 60
    /// 热终止阈值 °C（40——与 Discharge.temperatureLimitC 同值同源引用，单一真相）。
    public static var thermalTerminateC: Double { Discharge.temperatureLimitC }
    /// 热恢复滞回 °C：热终止后温度回降 **阈值 − 滞回** 才重新挂载（R2-P3-4——防
    /// 阈值附近抖动反复挂载/终止）。
    public static let thermalResumeHysteresisC: Double = 2.0

    /// 迟滞通道运行时状态（daemon 锁内内存态）。**不持久化**（§2.4 钉死——迟滞运行态
    /// 不入 TopoffPersistedState；重启后 tick 首拍按开关 + CHIE 可写性重估；重启窗内
    /// 的 CHIE 残留由 §2.4 残留巡检兜底——mounted=false 即恢复巡检执法）。
    public struct State: Equatable, Sendable {
        /// 迟滞执法挂载态（true = 通道在管——wire `sub80Hysteresis` 数据源；编排静默
        /// 由 convergenceRoute 的 hysteresisActive 分支承接）。
        public var mounted: Bool
        /// 热终止已发生（落 80 钳；温度回降 ≤ 阈值 − 滞回 → 解除并重走评估门，R2-P3-4）。
        public var thermalTerminated: Bool
        /// 最近一次**成功**写入的 CHIE 使能语义值（幂等写判定输入；true = 0x00 已写 /
        /// false = 0x8 已写 / nil = 从未写或退出恢复已归位）。daemon 写成功后回填——
        /// 照 TopoffChannelState.lastWrittenLimit 先例（纯函数出意图，daemon 簿记）。
        public var lastWrittenAdapterEnabled: Bool?
        /// 执法写计数（§2.3 循环成本告知——每次成功 CHIE 执法写 +1；内存态不持久化，
        /// persistLog 携带；daemon 写成功后回填。0.21.0 M1b 终审注记 b：措辞口径
        /// 「翻转」→「执法写」）。
        public var flipCount: Int

        public init(
            mounted: Bool = false, thermalTerminated: Bool = false,
            lastWrittenAdapterEnabled: Bool? = nil, flipCount: Int = 0
        ) {
            self.mounted = mounted
            self.thermalTerminated = thermalTerminated
            self.lastWrittenAdapterEnabled = lastWrittenAdapterEnabled
            self.flipCount = flipCount
        }
    }

    /// 迟滞每拍推进计划（纯函数输出——daemon 只执行副作用）。
    public struct TickPlan: Equatable, Sendable {
        /// CHIE 写意图（nil = 本拍不写；true = 0x00 恢复使能；false = 0x8 禁用适配器）。
        public let adapterWrite: Bool?
        /// 推进后的通道态（daemon 采纳后回填 lastWrittenAdapterEnabled/flipCount）。
        public let state: State

        public init(adapterWrite: Bool?, state: State) {
            self.adapterWrite = adapterWrite
            self.state = state
        }
    }

    /// 挂载评估门（§2.2 tick 门逐项；纯函数——daemon 只消费）：
    /// degraded（降级稳态——active 承载期不挂载，§2.1 链序）∧ opt-in ∧ CHIE 可写 ∧
    /// mode active ∧ 无在轨动作 ∧ 非自愈观察窗（互斥——迟滞翻转污染探针判定，R1-P1-4）
    /// ∧ 非 chargingDisabled 日程窗（完全放开期静默）∧ 非 fullOnce 临时放开窗（退出臂
    /// 承接——挂载门同步排除防窗内重挂抖动，§1.3）∧ 合盖闸放行（closed == nil 诚实
    /// 缺席放行——照 ClamshellGate.shouldAbort 强检查语义）∧ 非热终止滞留 ∧ 目标 <80
    ///（≥80 由编排钳/App set 执法——迟滞越权互搏）∧ 采样在场。
    public static func mountAllowed(
        degraded: Bool, optIn: Bool, chieWritable: Bool, modeActive: Bool,
        actionActive: Bool, healProbeActive: Bool, chargingDisabledWindow: Bool,
        clamshellClosed: Bool?, thermalTerminated: Bool, target: Int, percent: Int?,
        fullOnceWindow: Bool = false
    ) -> Bool {
        degraded && optIn && chieWritable && modeActive
            && !actionActive && !healProbeActive && !chargingDisabledWindow && !fullOnceWindow
            && clamshellClosed != true && !thermalTerminated
            && target < Topoff.degradedLimit && percent != nil
    }

    /// 外部写者簿记失效（code-review P1-1 自愈链钉面——纯函数，daemon 消费回填）：
    /// 迟滞通道之外的 CHIE 写入使 lastWrittenAdapterEnabled 失效（置 nil）。**nil ≠
    /// 任何带宽意图** → 下一执法拍按实况重写 0x8/0x00（同值写幂等安全——S1 E1 实证），
    /// 修死「外部写后簿记陈旧 → 带宽意图被幂等吞掉 → 执法静默卡死（mounted 假活）」
    /// 失败链。未挂载时调用无害（exit 臂 lastWritten==nil 无恢复意图——不产生多余写）。
    ///
    /// ⚠️ **外部写者挂点全集（code-review 复核钉单——新增 CHIE 写点必须对照本清单
    /// 补失效钩，漏一即 P1-1 同型静默死亡）**：
    /// ① 放电终态集中点 `noteDischargeTerminatedLocked`（maintain 四终态/取消、睡眠
    ///    取消、cancelAction 放电分支、监护缺失终止、启动崩溃恢复——恢复写前置失效）；
    /// ② 校准恢复集中点 `restoreCalibrationCHIELocked`（终态/取消恢复写前置失效）；
    /// ③ 放电启动 0x8 写点（`dischargeToLimitLocked` 启动序列 #3——写成功即失效，
    ///    覆盖回读校验失败 throw 臂：动作未注册、终态集中点不可达）；
    /// ④ 启动回滚（actionStore.save 失败 → 回滚 restoreEnabled——**刻意不经**终态
    ///    集中点，R2 P2-B 防冷却误记 → 独立失效钩）；
    /// ⑤ 巡检恢复成功（`patrolCHIEResidualLocked` else 臂——!mounted 可达但恢复的
    ///    0x00 会在「重挂 + 禁用臂」形态下被陈旧簿记幂等吞掉 → 独立失效钩）。
    public static func noteExternalAdapterWrite(state: State) -> State {
        var s = state
        s.lastWrittenAdapterEnabled = nil
        return s
    }

    /// 迟滞每拍推进（判定次序即契约，勿重排）：
    ///
    /// ① **热恢复评估门**（R2-P3-4）：热终止态 ∧ 温度回降 ≤ 阈值 − 滞回（38°C）→
    ///    解除热终止（评估门重走——本拍即可重新挂载）。
    /// ② **终止/退出臂**（幂等；任一命中 → unmount + 0x00 恢复意图——残留禁用不滞留，
    ///    落 80 编排钳由路由层承接）：mode 关（关断清理面全链含迟滞退出）/ !degraded
    ///    （topoff 自愈恢复——CHIE 归还 resting 态）/ !optIn（开关关，off/关断语义不变）
    ///    / !chieWritable（控制面不可写——无法执法）/ 合盖（closed == true 强检查命中
    ///    ——拒绝/中止）/ 过热（≥ 40°C 单点即终止——方向安全，照 Discharge 温度语义；
    ///    命中即置 thermalTerminated）/ **fullOnce 临时放开窗**（放开期充到 100 是预期
    ///    ——驻留 0x8 会物理阻断充电，静默不足以让路，必须退出恢复；窗毕 tick 首拍
    ///    评估门重走重挂，§1.3）/ **目标 ≥ 80**（code-review P3-2：滑杆升 ≥80 后挂载门
    ///    恒假而 mounted 空挂滞留——横幅假「执法中」+ 巡检豁免空悬；退出臂承接
    ///    unmount + 0x00，落编排钳/App set 执法域）。
    /// ③ **静默门**（挂载保持，本拍零写零翻转）：在轨动作（放电/校准掌权）/ 自愈观察窗
    ///    （互斥）/ chargingDisabled 窗（完全放开期——停充意图与 0x8 驻留同向，静默
    ///    即可）/ 采样缺席（percent/ext/isCharging 任一未知——证据不足，照 channelTick
    ///    缺席纪律）。
    /// ④ **挂载评估**：未挂载 → mountAllowed 全过则挂载（挂载拍本身零写——带宽判定
    ///    同拍进行，已越带即拍执法）。
    /// ⑤ **带宽执法**（挂载态）：恢复臂（percent ≤ 60 地板 ∨ percent ≤ target）→
    ///    0x00；禁用臂（percent > target + 滞回 ∧ 外接在场——适配器执法前提，电池供电
    ///    拍写禁用无意义）→ 0x8；带内 → 无动作（滞回防抖）。幂等：意图与
    ///    lastWrittenAdapterEnabled 同值 → 零写（30s 心跳下不重复翻转）。
    public static func tick(
        state: State,
        degraded: Bool,
        optIn: Bool,
        chieWritable: Bool,
        modeActive: Bool,
        actionActive: Bool,
        healProbeActive: Bool,
        chargingDisabledWindow: Bool,
        percent: Int?,
        target: Int,
        hysteresis: Int,
        externalConnected: Bool?,
        isCharging: Bool?,
        clamshellClosed: Bool?,
        temperatureC: Double?,
        fullOnceWindow: Bool = false
    ) -> TickPlan {
        var s = state
        // ① 热恢复评估门（R2-P3-4）：温度回降 ≤ 阈值 − 滞回 → 解除热终止（重走评估门）。
        if s.thermalTerminated, let temperatureC,
           temperatureC <= thermalTerminateC - thermalResumeHysteresisC {
            s.thermalTerminated = false
        }
        // ② 终止/退出臂（幂等）。
        // 过热判定照 Discharge 同源语义：≥ 40°C 单点即触发（方向安全）。
        let overheat = (temperatureC.map { $0 >= thermalTerminateC } ?? false)
        if !modeActive || !degraded || !optIn || !chieWritable
            || clamshellClosed == true || overheat || fullOnceWindow
            || target >= Topoff.degradedLimit {
            if overheat { s.thermalTerminated = true }
            let wasMounted = s.mounted
            s.mounted = false
            // 恢复意图（写 0x00 = adapterWrite true）仅在「可能留有 0x8 驻留」时给出
            //（lastWritten == false = 最近成功写为禁用）；已归位（true/nil）零写。
            // 恢复写成功后 daemon 簿记 lastWritten = nil（resting 态——退出静默）。
            let restoreIntent: Bool? = s.lastWrittenAdapterEnabled == false ? true : nil
            if wasMounted || restoreIntent != nil {
                return TickPlan(adapterWrite: restoreIntent, state: s)
            }
            return TickPlan(adapterWrite: nil, state: s)
        }
        // ③ 静默门（挂载保持，本拍零写）。
        if actionActive || healProbeActive || chargingDisabledWindow
            || percent == nil || externalConnected == nil || isCharging == nil {
            return TickPlan(adapterWrite: nil, state: s)
        }
        // ④ 挂载评估（未挂载 → 门全过即挂载；挂载拍同拍进入带宽判定）。
        if !s.mounted {
            s.mounted = mountAllowed(
                degraded: degraded, optIn: optIn, chieWritable: chieWritable,
                modeActive: modeActive, actionActive: actionActive,
                healProbeActive: healProbeActive, chargingDisabledWindow: chargingDisabledWindow,
                clamshellClosed: clamshellClosed, thermalTerminated: s.thermalTerminated,
                target: target, percent: percent, fullOnceWindow: fullOnceWindow)
            guard s.mounted else { return TickPlan(adapterWrite: nil, state: s) }
        }
        // ⑤ 带宽执法（挂载态；判定次序：恢复臂 → 禁用臂 → 带内无动作）。
        guard let percent else { return TickPlan(adapterWrite: nil, state: s) }
        let restoreIntent = percent <= percentFloor || percent <= target
        let disableIntent = !restoreIntent
            && percent > target + hysteresis && externalConnected == true
        let desired: Bool? = restoreIntent ? true : (disableIntent ? false : nil)
        // 幂等：意图与最近成功写同值 → 零写（防 30s 心跳重复翻转）。
        guard let desired, desired != s.lastWrittenAdapterEnabled else {
            return TickPlan(adapterWrite: nil, state: s)
        }
        return TickPlan(adapterWrite: desired, state: s)
    }
}
