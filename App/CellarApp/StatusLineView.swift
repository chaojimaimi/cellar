import CellarCore
import SwiftUI

/// 状态行（WP4 规格 §2.4，全部来自 BatterySnapshot）：分组流式——
/// 电源（外接/电池供电，充电中叠加「充电中」、停充显示「已停充」）｜
/// 电流·电压（**幅值** + 方向词来自 isCharging——amperageMA 符号不作方向推断）｜
/// 温度 °C（一位小数）｜循环次数｜适配器（W 取 adapter.watts，缺席隐藏；
/// 电池供电时 adapter == nil → 该段隐藏）。数字 monospacedDigit；
/// 采样失败（snapshot == nil）→「遥测不可用」（不进告警横幅，防 1s 刷屏）。
struct StatusLineView: View {
    let snapshot: BatterySnapshot?
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        if let snapshot {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                powerSegment(snapshot)
                separator
                currentVoltageSegment(snapshot)
                separator
                temperatureSegment(snapshot)
                separator
                Text("循环 \(snapshot.cycleCount)")
                    .monospacedDigit()
                if let adapter = snapshot.adapter, let segment = adapterSegment(adapter) {
                    separator
                    segment
                        .layoutPriority(0)   // 名称过长时优先压缩本段
                }
            }
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
        } else {
            Text("遥测不可用")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(theme.tertiaryText)
    }

    /// 电源段：外接（充电中/已停充）或电池供电。「已停充」用 holding 强调色。
    @ViewBuilder
    private func powerSegment(_ snapshot: BatterySnapshot) -> some View {
        if snapshot.externalConnected && snapshot.isCharging {
            Text("外接 · 充电中")
        } else if snapshot.externalConnected {
            HStack(spacing: 0) {
                Text("外接 · ")
                Text("已停充").foregroundStyle(theme.holding)
            }
        } else {
            Text("电池供电")
        }
    }

    /// 电流·电压段：幅值（mA → A，两位小数）+ 方向词（isCharging 为准，符号不推断）。
    private func currentVoltageSegment(_ snapshot: BatterySnapshot) -> Text {
        let amperage = Double(abs(snapshot.amperageMA)) / 1000
        let direction = snapshot.isCharging ? "充电" : "放电"
        let voltage = Double(snapshot.voltageMV) / 1000
        return Text("\(direction) \(String(format: "%.2f A", amperage)) · \(String(format: "%.1f V", voltage))")
            .monospacedDigit()
    }

    /// 温度段：一位小数。
    private func temperatureSegment(_ snapshot: BatterySnapshot) -> Text {
        Text("\(String(format: "%.1f °C", snapshot.temperatureC))")
            .monospacedDigit()
    }

    /// 适配器段：W（adapter.watts，缺席隐藏）+ 名称；均缺席 → nil（整段隐藏）。
    private func adapterSegment(_ adapter: AdapterInfo) -> Text? {
        var parts: [String] = []
        if let watts = adapter.watts {
            parts.append("\(watts) W")
        }
        if let name = adapter.name {
            parts.append(name)
        }
        guard !parts.isEmpty else { return nil }
        return Text(parts.joined(separator: " · ")).monospacedDigit()
    }
}