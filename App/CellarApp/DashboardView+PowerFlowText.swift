import CellarCore
import CellarUI
import SwiftUI

// MARK: - 功率流三角图数据行（自 DashboardView 抽出——0.18.2 行数红线收敛；
// 访问面 internal：跨文件同模块，属性原 private 因 Swift 作用域规则须放宽）
//
// v0.19.3 功率流向语义批（方案 §D4）：新增 `flowModel` 单一判据来源——外接态
// 功率数字一律取自同一遥测快照（三边恒守恒），遥测缺席回退现状 `V×I` + 策略位；
// 各文本属性只消费模型，不再各自推导。

extension DashboardView {

    var batteryVoltageText: String {
        guard let snapshot else { return CellarL10n.s("common.nodata") }
        return String(format: "%.1f V", Double(snapshot.voltageMV) / 1000)
    }

    /// 适配器副行：telemetry 在场 → 实时+协商复合（适配器节点卡实时 W，v1.11 T1
    /// ——App 层入参面，PowerFlowDiagramView 零改动）/ 现状协商 W / 未接入 / nodata。
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

    /// 功率流向显示模型（v0.19.3 §D4——判定全部下沉 CellarCore 纯函数
    /// `flowDiagramModel`，本文件只做字符串组装）。v0.19.5 §D2：六参直调透传
    /// controller 前态投影（assist 代际确认门的判定输入）。
    var flowModel: FlowDiagramModel {
        flowDiagramModel(
            externalConnected: snapshot?.externalConnected ?? false,
            isCharging: snapshot?.isCharging ?? false,
            systemPowerInMW: snapshot?.telemetry?.systemPowerInMW,
            batteryPowerMW: snapshot?.telemetry?.batteryPowerMW,
            batteryVoltageMV: snapshot?.voltageMV ?? 0,
            batteryAmperageMA: snapshot?.amperageMA ?? 0,
            previous: statusController.flowPreviousSample
        )
    }

    /// 系统副行：系统节点 = 模型 `systemLoadW`（外接态 = SP−BP 推导负载、电池态
    /// = |V×I| 同快照）；缺席 → 「—」不造数。
    var systemLineText: String {
        guard !isNodata else { return CellarL10n.s("common.nodata") }
        guard let loadW = flowModel.systemLoadW else { return CellarL10n.s("common.nodata") }
        return CellarL10n.s("dashboard.sysLine.load", loadW)
    }

    /// 适配器→电池边标签：仅 charging 且边值在场（遥测源 = BP，回退源 = |V×I|，
    /// 皆已过 0.05 显示阈值）。
    var powerABText: String? {
        guard flowModel.kind == .charging, let w = flowModel.batteryEdgeW else { return nil }
        return CellarL10n.s("dashboard.flow.powerIn", w)
    }

    /// 电池→系统边标签：电池态 = 放电方向词（现状口径）；补入态 = 「电池补入」
    /// （assist——电池放电补差，用户可读出 适配器 + 电池 = 系统）；其余态无边。
    var powerBSText: String? {
        switch flowModel.kind {
        case .battery:
            guard let w = flowModel.batteryEdgeW else { return nil }
            // 负值经格式串显「−」方向（组件 color 由放电边 warn 承载）。
            return CellarL10n.s("dashboard.flow.powerOut", -w)
        case .assist:
            guard let w = flowModel.batteryEdgeW else { return nil }
            return CellarL10n.s("dashboard.flow.assist", abs(w))
        default: return nil
        }
    }

    /// 适配器→系统边标签（v0.19.3 按 kind 分派）：**charging** → 直供边真实流量
    /// = 系统负载（现状口径；v0.19.5 未确认窗口子形态例外——load=nil、direct=SP
    /// 时改「直供 · SP W」，见分支内注释）；**assist** → 「直供 · SP W」（适配器实际输出）；
    /// **holding** → SP 在场显「直供 · SP W」/ 缺席 → 「直供」纯词；电池供电 → nil
    /// （边不显示，放电路径由 B→S 边承载）。
    var supplyLineText: String? {
        guard snapshot?.externalConnected == true else { return nil }
        switch flowModel.kind {
        case .charging:
            // 未确认窗口子形态（v0.19.5 评审 P1-1）：kind=.charging 但 load=nil、
            // direct=SP——SP 是适配器输入不是系统负载，「负载」措辞会把输入当
            // 负载误导（与事故「系统 89.2 W」同型）；改「直供 · SP W」（与 golden
            // 钉死形态一致）。识别式唯一：常规 charging 两值恒同源非 nil、② 回退
            // charging direct=nil、异常 SP<BP 两值同 nil。
            if flowModel.systemLoadW == nil, let spW = flowModel.directEdgeW {
                return CellarL10n.s("dashboard.supply.power", String(format: "%.1f", spW))
            }
            guard let loadW = flowModel.directEdgeW else { return nil }
            return CellarL10n.s("dashboard.sysLine.load", loadW)
        case .assist:
            guard let spW = flowModel.directEdgeW else { return nil }
            return CellarL10n.s("dashboard.supply.power", String(format: "%.1f", spW))
        case .holding:
            guard let w = flowModel.directEdgeW else { return CellarL10n.s("dashboard.supply") }
            return CellarL10n.s("dashboard.supply.power", String(format: "%.1f", w))
        case .battery:
            return nil
        }
    }
}
