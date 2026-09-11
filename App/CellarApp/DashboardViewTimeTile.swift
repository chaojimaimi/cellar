import CellarCore
import CellarUI
import SwiftUI

// 实时仪表板「时间估算 tile」分区（Phase 5 v1.2 §3.6——DashboardView 组装超
// 400 行，按分区拆文件，红线 6）：满电还需 / 预计可用 + 展示粒度格式化
// （N 分钟 / N 小时 M 分）。样本与电源态投影在 DashboardView.swift。

extension DashboardView {

    var tempValue: String {
        guard let snapshot else { return CellarL10n.s("common.nodata") }
        return String(format: "%.1f", snapshot.temperatureC)
    }

    // ---- 时间 tile（§3.6：满电还需 / 预计可用）----

    var timeTileTitle: String {
        // 0.19.4 §1.2：assist 按 battery 语义（补入期电池真实放电，15 分钟窗速率
        // 外推有意义）。
        flowState == .battery || flowState == .assist
            ? CellarL10n.s("dashboard.tile.time.battery")
            : CellarL10n.s("dashboard.tile.time.charging")
    }

    var timeValue: (value: String, unit: String?) {
        guard let minutes = timeEstimateMinutes else {
            return (CellarL10n.s("common.nodata"), nil)
        }
        // 展示粒度「N 分钟 / N 小时 M 分」（§3.6）。
        if minutes < 60 {
            return ("\(minutes)", CellarL10n.s("dashboard.time.unit.minute"))
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 {
            return ("\(hours)", CellarL10n.s("dashboard.time.unit.hour"))
        }
        // 小时单位入串（走查 R3：缺「小时」致「1 42分」歧义）——值 = 「N 小时 M」+ 单位「分」。
        return ("\(hours) \(CellarL10n.s("dashboard.time.unit.hour")) \(rest)",
                CellarL10n.s("dashboard.time.unit.minutePart"))
    }

    var timeTileSubtitle: String {
        switch flowState {
        case .charging: return CellarL10n.s("dashboard.tile.time.sub.charging")
        case .holding: return CellarL10n.s("dashboard.tile.time.sub.holding")
        // 0.19.4 §1.2：assist 复用 battery 副标「按近 15 分钟功耗外推」（不新增 key）。
        case .assist, .battery: return CellarL10n.s("dashboard.tile.time.sub.battery")
        case nil: return CellarL10n.s("common.nodata")
        }
    }

    /// 时间估算接线（§3.6）：样本环投影 → TimeEstimator 纯函数；holding 恒
    /// nil（直供无时间语义），估算不可信 → 「—」。
    var timeEstimateMinutes: Int? {
        // 电源段已隐含快照非 nil（flowState 由快照派生）——无需再解包快照。
        let state: TimeEstimateState
        switch flowState {
        case .charging: state = .charging
        case .holding: state = .holding
        // 0.19.4 §1.2：assist → .battery（补入期电池真实放电，外推有意义）。
        // 已知边界（R1 P2-5，接受不治理）：样本环清环键为 (isCharging,
        // externalConnected)，charging↔assist 翻转不清环，存在最长 15 分钟
        // 反向斜率混合窗（TimeEstimator 多数自愈为 nil「—」）。
        case .assist, .battery: state = .battery
        case nil: return nil
        }
        // upperLimit 仅 charging 分支使用（至充限上沿外推）；battery/holding 的
        // 估算不依赖 daemon 策略值——daemon 缺席不该吞掉电池态估算（P3-1）。
        // 100 为 battery/holding 分支的占位实参（TimeEstimator 恒不使用）。
        let upperLimit = statusController.daemonStatus?.upperLimit
        if state == .charging, upperLimit == nil { return nil }
        return TimeEstimator.estimateMinutes(
            samples: statusController.estimateSamples,
            state: state,
            upperLimit: upperLimit ?? 100
        )
    }
}
