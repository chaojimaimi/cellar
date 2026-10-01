import Foundation

// MARK: - 心跳停摆自杀 watchdog（0.20.1 方案 §2.2）

/// 心跳 watchdog 常量与阈值判定（0.20.1 热修——真机两次 daemon 整体挂起（wedge
/// 一/二）的修复形态：KeepAlive {SuccessfulExit:false} 只管退出不管挂起，挂起态
/// 进程活着、launchd 无感知，用户侧 UI 全灰需人工 kickstart → daemon 内部自检，
/// 停摆即 exit(42) 自杀（非零 → KeepAlive 重拉；现退出码仅 0/1，42 无冲突）。
///
/// 纪律（方案 R1-P1/R2-P1 钉死）：
/// - `lastTickAt` 由**独立小锁**（专用 NSLock，与主状态锁无嵌套）保护；watchdog
///   线程只拿小锁、**永不取主状态锁**——无锁序倒置，主线程持锁楔死时 watchdog
///   照常运行。
/// - `lastTickAt` 更新点钉在 `performTickLocked` **入口首行**（调用方已持锁）；
///   严禁钉函数尾部——27 观测路径（backend 缺席/采样失败/控制键读取失败臂）全部
///   early-return，尾部不可达 → 时间戳永不更新 → watchdog 每 150s 误杀重启循环。
/// - 睡眠唤醒 wall clock 跳变 → 接受一次无害重启（fresh 域写幂等、恢复秒级）；
///   不引入 continuous clock 复杂度（方案 §7 风险登记）。
public enum HeartbeatWatchdog {
    /// 检查间隔（秒）——独立 GCD 队列定时器节奏。
    public static let checkInterval: TimeInterval = 30
    /// 停摆阈值（秒）= 3 × 30s tick 间隔 + 60s 余量（评审可调——纯函数单测钉边界）。
    public static let stallThreshold: TimeInterval = 150
    /// 自杀退出码（KeepAlive SuccessfulExit:false 重拉；与 SIGTERM 0 / fail-secure 1 无冲突）。
    public static let suicideExitCode: Int32 = 42

    /// 阈值判定纯函数（CellarCoreCheck 场景域钉死）：`lastTickAt` 距今超过阈值 →
    /// 自杀。`lastTickAt == nil`（进程启动后尚未 tick 过——disabled 模式启动即属
    /// 此形态，首个心跳在 30s 后到达）以 watchdog 装配时刻为参照：装配后 150s 内
    /// 仍无任何 tick 亦属停摆（主 RunLoop 冻结形态照常检出）。
    public static func shouldSelfTerminate(lastTickAt: Date?, watchdogStart: Date, now: Date) -> Bool {
        let reference = lastTickAt ?? watchdogStart
        return now.timeIntervalSince(reference) > stallThreshold
    }
}
