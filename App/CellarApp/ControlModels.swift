import CellarCore
import CellarUI

// MARK: - 控制反馈模型（0.3.2 自 StatusController 拆出，行数纪律；零行为变化）

extension StatusFailureKind {
    /// 横幅文案（与通知文案同源，§2.3 定版常量集中 NotificationService）。
    /// WP2'：safety 终态（温度/地板/监护缺失/CHIE 残留巡检）同通道呈现。
    var message: String {
        switch self {
        case .writeFailed: return CellarL10n.s("notification.writeFailed")
        case .conflictSuspected: return CellarL10n.s("notification.conflictSuspected")
        case .actionTimedOut: return CellarL10n.s("notification.actionTimeout")
        case .actionInterrupted: return CellarL10n.s("notification.actionInterrupted")
        case .actionSafetyTerminated: return CellarL10n.s("notification.actionSafetyTerminated")
        }
    }
}

/// 控制动作的可重放描述（告警横幅「重试」重发上次动作，规格 §2.7 分支 ①：
/// runControl 入口记录、成功清除）。摘要经 CellarL10n（status.summary.*）。
enum ControlAttempt: Equatable {
    case setLimits(upperLimit: Int, hysteresis: Int)
    case setChargingEnabled(Bool)
    /// WP2 一次性动作（重试 = 重新发送动作命令；cancelAction 幂等，重试无害）。
    case fullOnce
    case cancelFullOnce
    /// WP2' 放电动作（同 fullOnce 形态：重试 = 重新发送命令）。
    case dischargeToLimit
    case cancelDischarge

    /// 横幅摘要文案（上次动作是什么）。
    var summary: String {
        switch self {
        case .setLimits(let upperLimit, _):
            return CellarL10n.s("status.summary.setLimits", upperLimit)
        case .setChargingEnabled(true):
            return CellarL10n.s("panel.enableLimit")
        case .setChargingEnabled(false):
            return CellarL10n.s("panel.disableLimit")
        case .fullOnce:
            return CellarL10n.s("status.summary.fullOnce")
        case .cancelFullOnce:
            return CellarL10n.s("status.summary.cancelFullOnce")
        case .dischargeToLimit:
            return CellarL10n.s("status.summary.discharge")
        case .cancelDischarge:
            return CellarL10n.s("status.summary.cancelDischarge")
        }
    }
}

/// 面板运行态控制器：轮询调度、busy 门控、控制操作（全部 XPC 后台执行）、
/// 遥测采样（面板可见期 IOKit 只读快照，独立门控）。
///
/// 与 DaemonInstaller 职责分离（规格 §2.1）：installer 管注册态，本控制器管运行态/
/// 策略控制/遥测；单向接线 = 组合根 onChange(of: installer.registration) →
/// `registrationChanged(_:)`，不反向依赖。
///
/// 主线程纪律（WP2 实证）：任何 XPC/IOKit 调用不得同步出现在主线程——一切走
/// Task.detached，结果经 MainActor.run 回到主 actor 更新状态。
