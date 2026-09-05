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
    /// WP3 校准动作（同 fullOnce 形态：重试 = 重新发送命令——startCalibration 幂等
    /// 拆分/actionOccupied 拒绝经 daemon 上抛，重试无害）。
    case startCalibration
    case cancelCalibration
    /// Phase 5 v1.1 风扇设置（重试 = 重发上次 FanWire——缺席保持语义下无害）。
    case setFan(FanWire)
    /// Phase 5 v1.4 校准调度（重试 = 重发上次全键 wire——全键覆盖语义下幂等无害）。
    case setCalibrationSchedule(CalibrationScheduleWire)
    /// Phase 5 v1.5 充电热暂停（重试 = 重发上次全键 wire——全键覆盖语义下幂等
    /// 无害，照 setCalibrationSchedule 形态）。
    case setThermal(ThermalWire)
    /// Phase 5 v1.6 充电日程（重试 = 重发上次整包配置 JSON——全键覆盖语义下幂等
    /// 无害，照 setThermal 形态；payload = 宿主页 encode 的紧凑 JSON）。
    case setChargeSchedule(String)

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
        case .startCalibration:
            return CellarL10n.s("calibration.start")
        case .cancelCalibration:
            return CellarL10n.s("calibration.cancel")
        case .setFan:
            return CellarL10n.s("status.summary.setFan")
        case .setCalibrationSchedule:
            return CellarL10n.s("status.summary.setCalibrationSchedule")
        case .setThermal:
            return CellarL10n.s("status.summary.setThermal")
        case .setChargeSchedule:
            return CellarL10n.s("status.summary.setChargeSchedule")
        }
    }
}

// MARK: - Phase 5 v1.6 充电日程（App 侧派生值与通知事件）

/// 充电日程状态快照（方案 §3.2；daemonStatus.scheduleJson 解码 + 当前命中条目
/// id 透传——照 fanStatus/thermalStatus 派生形态，nil = 旧 daemon 门控）。
struct ChargeScheduleStatus: Equatable {
    /// 日程配置（scheduleJson 解码；daemon 侧 encode 产物解码失败理论不可达，
    /// 消费侧回落 .default——仅影响渲染初值，不误判 legacy）。
    var config: ChargeScheduleConfig
    /// 当前命中窗口条目 id（daemon state 内存缓存回读；nil = 无在窗应用/旧 daemon）。
    var activeEntryId: String?
}

/// 充电日程边沿通知事件（UD-7：ingest 对 scheduleActiveId 前后比对的产出）。
/// **不走 CellarNotificationEvent**（UD-7 不新增 case、不动 daemon 字面量→通知
/// 映射）——经 StatusController.onScheduleEvent 出口由 NotificationService
/// deliverSchedule 直投。
enum ScheduleNotification: Equatable {
    /// 窗口进入（含 A→B 无缝直切——命中条目变更按进入语义上报）；条目摘要段 =
    /// ChargeScheduleSummary.line（与列表行同源装配）。
    case entered(entrySummary: String)
    /// 窗口退出恢复（恢复进窗快照 base / 关总开关立即恢复）。
    case restored
}

extension StatusController {
    /// 通知文案的条目摘要段（id → scheduleJson 内条目 → 一行摘要）。条目不存在
    ///（配置刚被删除的竞态）→ 短 id 兜底，不空转也不猜测语义。
    func scheduleEntrySummary(_ id: String, in status: DaemonStatus) -> String {
        let config = status.scheduleJson.flatMap { try? ChargeScheduleConfig.decoded(from: $0) }
        guard let entry = config?.entries.first(where: { $0.id == id }) else {
            return String(id.prefix(8))
        }
        return ChargeScheduleSummary.line(entry)
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
