/// 充电侧温度守卫（0.4 WP1）：t ≥ pauseC 且正在充电（未到上限）→ 写停充；
/// base == enable（停充态且 percent < 恢复阈值）且 t ≥ resumeC → 保持暂停；
/// t < resumeC → 恢复常规决策。带内滞回借「充电现态」承载，无记忆、无状态存储。
///
/// 独立于 LimitPolicy（限充红线与热保护是两个关注点；WP3 校准的充电相将复用
/// 本模块）。温度数据源 = BatterySnapshot.temperatureC（快照失败时 tick 早退，
/// 判定链拿不到陈旧温度，守卫无需自带数据新鲜度防线，方案 §1）。
public enum ThermalGuard {
    /// 暂停阈值 °C（与 Discharge.temperatureLimitC 同值不同义：放电=紧急终止
    /// 单点触发，充电=暂停且带滞回；两常量独立演化）。
    public static let pauseC = 40.0
    /// 恢复阈值 °C（严格小于暂停阈值；3°C 滞回防 39/40 边界抖动）。
    public static let resumeC = 37.0

    /// 返回：生效动作 + 是否处于温度暂停态（驱动 lastAction 字面量与 App 状态行词）。
    /// base = LimitPolicy.decide(context) 先行结果；本函数按序求值、先命中先输出
    /// （方案 §2.1 决策矩阵 v2）。
    ///
    /// 为什么不看 base 判「充电中升温」（方案 §2.1 要点）：decide 在
    /// chargingEnabled==true ∧ percent < 上限 时恒返回 noop——只看 base 会漏掉
    /// 主场景，守卫必须直接看充电现态。
    public static func guarded(
        base: ChargingAction,
        context: ChargingContext,
        temperatureC: Double
    ) -> (action: ChargingAction, tempPauseActive: Bool) {
        // case 1：限充停充（base==disable ⟺ percent ≥ 上限）透传，限充语义优先。
        // 不标热暂停——温度暂停与限充滞留的显示区分（否则 80% 上限停充会被误读
        // 成热暂停，方案 §2.1）。
        if base == .disableCharging {
            return (.disableCharging, false)
        }
        // case 2：「充电中升温」主场景 t ≥ pauseC ∧ 充电中 → 热停写一次，下 tick
        // 落 case 3 驻留，SMC 无抖写。percent < 上限在外接态由 case 1 优先隐含
        // 保证（percent ≥ 上限 ∧ 充电中 → base 必为 disable，先命中 case 1）；
        // 例外 = external==false 时 base 恒 noop，percent ≥ 上限 ∧ 充电中的输入
        // 亦落本 case（电池变体——写 CHTE=1 为门预置，物理无害，方案 §3.7）。
        // 电池供电（external==false）时同样命中：写 CHTE=1 为门预置，物理无害，
        // 回插热态即被挡（方案 §3.7）。
        if temperatureC >= Self.pauseC && context.chargingEnabled {
            return (.disableCharging, true)
        }
        // case 3/4：暂停驻留态 + 滞回带——base==enable（停充态且 percent < 恢复
        // 阈值）∧ t ≥ resumeC → 保持暂停免重复写（带内不写即不打架，方向
        // fail-safe：少充电无害；外部写者/睡眠残留造成的停充在此被解读为暂停
        // 只是标签误差，行为正确性不受损，方案 §2.1 要点 3）。case 3/4 分列
        // 只为测试断言清晰。
        if base == .enableCharging && temperatureC >= Self.resumeC {
            return (.noop, true)
        }
        // case 5：恢复——base==enable ∧ t < resumeC → 恢复写（滞回完成闭环：
        // 40 停 → 冷至 <37 恢复 → 回温再停，周期分钟级，滞回压频率）。
        if base == .enableCharging {
            return (.enableCharging, false)
        }
        // case 6：其余透传（限充滞回保持 / 电池供电 / 带内充电中 t < pauseC 继续
        // 充），不标热暂停——这些态下停充/继续充才是现行原因（方案 §2.1 完备性）。
        return (base, false)
    }
}