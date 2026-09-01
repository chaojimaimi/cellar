import CellarCore
import SwiftUI

/// 状态行（WP4 规格 §2.4 数据源 + §7.2 重排）：**固定分段网格 2 行 3 列**——
/// 电源｜电流｜电压 // 温度｜循环｜适配器；每段 caption 标签 + monospacedDigit 值，
/// 分段自适应宽、零截断（消除 §7.2 反馈的流式单行截断与跳动）。
///
/// 全部来自 BatterySnapshot：电流段幅值 + 方向词（currentDirectionWord 纯函数，
/// 规格 §7.2——外接停充方向词 nil 时只显幅值，修「停充显放电 0.00 A」矛盾）；
/// 适配器 W 取 adapter.watts 实时数据（§7.2：数值随硬件真实变化即正确，
/// 缺席整体隐藏、留空位保网格稳定）；采样失败（snapshot == nil）→
/// 「遥测不可用」（不进告警横幅，防 1s 刷屏）。
struct StatusLineView: View {
    let snapshot: BatterySnapshot?
    @Environment(\.cellarTheme) private var theme

    var body: some View {
        if let snapshot {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    powerSegment(snapshot)
                    currentSegment(snapshot)
                    voltageSegment(snapshot)
                }
                GridRow {
                    temperatureSegment(snapshot)
                    cycleSegment(snapshot)
                    // 缺席隐藏：电池供电时 adapter == nil 常态缺席，留空位保持
                    // 2×3 网格形状稳定（温度/循环列不错位）。
                    if let adapter = snapshot.adapter, !adapterParts(adapter).isEmpty {
                        adapterSegment(adapter)
                    }
                }
            }
        } else {
            Text("遥测不可用")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 单段统一样式（规格 §7.2：caption 标签 + monospacedDigit 值）。
    private func segment(caption: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
            value()
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 电源段：外接（充电中/已停充）或电池供电。「已停充」用 holding 强调色
    /// （规格 §2.4 语义保持）。
    private func powerSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: "电源") {
            if snapshot.externalConnected && snapshot.isCharging {
                Text("外接 · 充电中")
            } else if snapshot.externalConnected {
                // 分两段 Text（macOS 26 下 Text+Text 拼接已弃用）；「已停充」
                // 子文本显式 holding，覆盖外层 secondaryText。
                HStack(spacing: 0) {
                    Text("外接 · ")
                    Text("已停充").foregroundStyle(theme.holding)
                }
            } else {
                Text("电池供电")
            }
        }
    }

    /// 电流段：幅值（mA → A，两位小数）+ 方向词（currentDirectionWord 纯函数，
    /// 规格 §7.2；方向词 nil = 外接停充 → 只显幅值不标方向）。
    private func currentSegment(_ snapshot: BatterySnapshot) -> some View {
        let amperage = Double(abs(snapshot.amperageMA)) / 1000
        let ampText = String(format: "%.2f A", amperage)
        let word = currentDirectionWord(
            isCharging: snapshot.isCharging,
            externalConnected: snapshot.externalConnected
        )
        return segment(caption: "电流") {
            Text(word.map { "\($0) \(ampText)" } ?? ampText)
        }
    }

    /// 电压段：一位小数。
    private func voltageSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: "电压") {
            Text(String(format: "%.1f V", Double(snapshot.voltageMV) / 1000))
        }
    }

    /// 温度段：一位小数。
    private func temperatureSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: "温度") {
            Text(String(format: "%.1f °C", snapshot.temperatureC))
        }
    }

    /// 循环次数。
    private func cycleSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: "循环") {
            Text("\(snapshot.cycleCount)")
        }
    }

    /// 适配器段：W（adapter.watts 实时数据，规格 §7.2）+ 名称；均缺席 → 整段
    /// 隐藏（调用处判定）。名称过长限宽自然换行——零截断，不复用原流式布局的
    /// 压缩截断手段。
    private func adapterSegment(_ adapter: AdapterInfo) -> some View {
        segment(caption: "适配器") {
            Text(adapterParts(adapter).joined(separator: " · "))
                .frame(maxWidth: 140, alignment: .leading)
        }
    }

    private func adapterParts(_ adapter: AdapterInfo) -> [String] {
        var parts: [String] = []
        if let watts = adapter.watts {
            parts.append("\(watts) W")
        }
        if let name = adapter.name {
            parts.append(name)
        }
        return parts
    }
}