import CellarCore
import CellarUI
import SwiftUI

// MARK: - 功率流三角图数据行（自 DashboardView 抽出——0.18.2 行数红线收敛；
// 访问面 internal：跨文件同模块，属性原 private 因 Swift 作用域规则须放宽）

extension DashboardView {

    var batteryVoltageText: String {
        guard let snapshot else { return CellarL10n.s("common.nodata") }
        return String(format: "%.1f V", Double(snapshot.voltageMV) / 1000)
    }

    /// 适配器副行：telemetry 在场 → 实时+额定复合（适配器节点卡实时 W，v1.11 T1
    /// ——App 层入参面，PowerFlowDiagramView 零改动）/ 现状额定 W / 未接入 / nodata。
    var adapterLineText: String {
        guard !isNodata else { return CellarL10n.s("common.nodata") }
        if let systemPowerMW = snapshot?.telemetry?.systemPowerInMW,
           let rated = snapshot?.adapter?.watts {
            return CellarL10n.s("statusline.adapter.live", String(format: "%.1f", Double(systemPowerMW) / 1000), rated)
        }
        if let watts = snapshot?.adapter?.watts {
            return CellarL10n.s("dashboard.adapter.line.present", watts)
        }
        return CellarL10n.s("dashboard.adapter.line.absent")
    }

    /// 系统副行：电池态显实测负载（电池是唯一电源，V×A = 系统功耗）；外接态
    /// （充电/停充）遥测在场 → SystemLoad 实测负载（0.18.2 口径扩展——
    /// SystemLoadMW 字段已在案，补上消除充电态「—」）；遥测缺席 → 「—」不造数。
    var systemLineText: String {
        guard !isNodata else { return CellarL10n.s("common.nodata") }
        if snapshot?.externalConnected == false {
            return CellarL10n.s("dashboard.sysLine.load", abs(batteryPowerW))
        }
        if let loadMW = snapshot?.telemetry?.systemLoadMW {
            return CellarL10n.s("dashboard.sysLine.load", Double(loadMW) / 1000)
        }
        return CellarL10n.s("common.nodata")
    }

    var powerABText: String? {
        guard flowState == .charging, abs(batteryPowerW) >= 0.05 else { return nil }
        return CellarL10n.s("dashboard.flow.powerIn", abs(batteryPowerW))
    }

    var powerBSText: String? {
        guard flowState == .onBattery, abs(batteryPowerW) >= 0.05 else { return nil }
        // 负值经格式串显「−」方向（组件 color 由放电边 warn 承载）。
        return CellarL10n.s("dashboard.flow.powerOut", -abs(batteryPowerW))
    }
    /// 适配器→系统边标签（0.18.2 三态口径修正）：**充电态** → 「系统负载 · X W」
    /// （此边真实流量 = 系统负载 SystemLoad——「直供 · 总输入 W」在充电态语义错误
    /// 且与电池边并排诱发错误加法，用户走查实测反馈）；**停充态** → 「直供 · 实时
    /// W」（telemetry 在场，总输入=直供功率两者等价）/ 缺席 → 现状「直供」文案。
    /// 电池供电 → nil（边不显示，放电路径由 B→S 边承载）。
    var supplyLineText: String? {
        guard snapshot?.externalConnected == true else { return nil }
        if flowState == .charging {
            guard let loadMW = snapshot?.telemetry?.systemLoadMW else { return nil }
            return CellarL10n.s("dashboard.sysLine.load", Double(loadMW) / 1000)
        }
        if let systemPowerMW = snapshot?.telemetry?.systemPowerInMW {
            return CellarL10n.s("dashboard.supply.power", String(format: "%.1f", Double(systemPowerMW) / 1000))
        }
        return CellarL10n.s("dashboard.supply")
    }
}
