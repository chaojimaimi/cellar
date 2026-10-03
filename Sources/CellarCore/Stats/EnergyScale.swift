import Foundation

/// 能耗统计定标常数单源（0.22.0 §2.4；SMC-NOTES §11.8 第一轮定标 2026-10-03）。
///
/// 单源纪律：K 值只在本文件出现一处——第二轮定标实验后改一处即全量生效。
/// 估算口径：点采样 vs 区间积分存在 ~10% 系统差（或与 ~1s 负载波动/采样周期
/// 1.084s 有关），UI 以「估算」标注如实呈现（能耗卡脚注）。
public enum EnergyScale {
    /// 系统通道（AccumulatedSystemLoad / AccumulatedSystemPowerIn）：能量(mW·s)
    /// = ΔAcc × K——§11.8 密集窗定标（478s 窗 ∫SystemLoad / ΔAcc = 1.101），
    /// SystemPowerIn 通道独立平行恒等（固件统一标度）。
    public static let systemK = 1.101
    /// 电池放电通道（AccumulatedBatteryDischarge **递减**）：|ΔAcc| × K——
    /// §11.8 电池供电窗定标 0.82-0.83 取中（∫BP 与 ∫V×I 双旁证交叉差 1.6%）。
    /// 充电窗递增语义未定谳（观察期实验④）——递增对跳过不消费。
    public static let dischargeK = 0.825
    /// 放电通道 |Δacc| 合理性上限（W）：对时长 × 本值折算 mWh 上界——超限判
    /// 复位（长间隙后计数反超的兜底；200 W 取整机满载上界，评审 P1-1）。
    public static let dischargeSanityCapWatts = 200.0
}
