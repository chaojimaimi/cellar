import Foundation

// MARK: - 0.23.2 ① 充满完成检测（fullOnce 窗专用——27 窗模式自动恢复的判定源）
//
// 背景（方案 phase7-0.23.2 §2/§1.9）：fullOnce 27 临时放开窗（0.21.0 §1.3 置窗-only
// 形态）此前无自动恢复（用户显式恢复臂手动收敛）——本批给窗补「充到 100 → ~1.5min
// 自动回落 + 4h 超时兜底」。检测谓词**复用 `OneShot.isFullOnceComplete`**（单一真相
// ——勿复制判定逻辑，含 isCharging 门与 ≥99 降级兜底），去抖 3 拍窗专用（26 动作轨
// 仍是 2 拍——各通道独立演化，互不引用）。
//
// 分层（照 OneShot/Calibration 先例）：纯函数在本文件（CellarCoreCheck 场景域钉死），
// 计数器 `fullOnceFullTicks` 与窗口态归 daemon 核心态，副作用（清窗/域写收敛/字面量
// 锁存）全在 daemon 的清窗 helper——本类型零 IO、零状态。

/// fullOnce 窗充满检测（纯函数）：
/// - `tick(isCharging:fullyCharged:percent:externalConnected:consecutive:) -> Bool`：
///   连续 `debounceTicks` 拍命中 → true（自动恢复触发面）；
/// - `predicate(isCharging:fullyCharged:percent:externalConnected:) -> Bool`：
///   单拍完成判据（外接门 + `OneShot.isFullOnceComplete`）——daemon 计数器推进/清零
///   与 tick 共用同一谓词源（防两处判定漂移）。
public enum FullChargeDetection {
    /// 完成判定去抖所需连续拍数（30s tick ×3 = ~90s 驻留——窗模式专用；26 动作轨
    /// `OneShot.fullOnceDebounceTicks = 2` 保持不变，两通道独立演化）。
    public static let debounceTicks = 3
    /// 窗超时兜底（**别名同源** `OneShot.fullOnceTimeout` 4h——勿字面量；超时 =
    /// 「4h 内未满 3 拍命中」的兜底恢复，字面量落 fullOnce:timeout 与 26 同映射）。
    public static let fullOnceWindowTimeout: TimeInterval = OneShot.fullOnceTimeout

    /// 单拍完成判据（单一谓词源）：外接在位 ∧ `OneShot.isFullOnceComplete`。
    /// 外接缺席 → false（调用方清零——拔电拍不构成充满证据）。
    public static func predicate(
        isCharging: Bool, fullyCharged: Bool?, percent: Int, externalConnected: Bool
    ) -> Bool {
        guard externalConnected else { return false }
        return OneShot.isFullOnceComplete(
            fullyCharged: fullyCharged, isCharging: isCharging, percent: percent
        )
    }

    /// 去抖检测（计数由调用方持有传入——daemon `fullOnceFullTicks`；`consecutive` =
    /// 本拍之前的连续命中数）：本拍谓词命中 ∧ 连续满 `debounceTicks` 拍 → true。
    /// 未命中（含外接缺席）→ false（调用方清零——中断归零语义与 `OneShot.debounceTick`
    /// 同构，复位钉在 daemon 检测挂点「窗口非活跃拍」单一谓词点 + 清窗 helper）。
    public static func tick(
        isCharging: Bool, fullyCharged: Bool?, percent: Int,
        externalConnected: Bool, consecutive: Int
    ) -> Bool {
        guard predicate(
            isCharging: isCharging, fullyCharged: fullyCharged,
            percent: percent, externalConnected: externalConnected
        ) else { return false }
        return consecutive + 1 >= debounceTicks
    }
}
