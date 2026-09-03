import CellarCore
import SwiftUI

/// 状态行（WP4 规格 §2.4 数据源 + §7.2 重排；WP4 自 App target 下沉）：**固定分段网格 2 行 3 列**——
/// 电源｜电流｜电压 // 温度｜循环｜适配器；每段 caption 标签 + monospacedDigit 值，
/// 分段自适应宽、零截断（消除 §7.2 反馈的流式单行截断与跳动）。
///
/// 全部来自 BatterySnapshot：电流段幅值 + 方向词（currentDirection 纯函数，
/// 规格 §7.2——外接停充方向词 nil 时只显幅值，修「停充显放电 0.00 A」矛盾；
/// WP4 §4.3 消费 CellarCore 枚举 + CellarL10n 词条）；
/// 适配器 W 取 adapter.watts 实时数据（§7.2：数值随硬件真实变化即正确，
/// 缺席整体隐藏、留空位保网格稳定）；采样失败（snapshot == nil）→
/// 「遥测不可用」（不进告警横幅，防 1s 刷屏）。
public struct StatusLineView: View {
    public let snapshot: BatterySnapshot?
    /// 温度暂停态（daemonStatus.isTempPauseAction 派生）：温度段追加「暂停中」注词。
    /// 默认 false 向后兼容——既有调用点（快照矩阵/无 daemon 场景）零改动（方案 §2.4）。
    public let tempPauseActive: Bool
    @Environment(\.cellarTheme) private var theme

    public init(snapshot: BatterySnapshot?, tempPauseActive: Bool = false) {
        self.snapshot = snapshot
        self.tempPauseActive = tempPauseActive
    }

    public var body: some View {
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
            Text(CellarL10n.s("statusline.unavailable"))
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

    /// 电源段：外接（充电中/已停充）或电池供电，词随风格（§3.5 对账表——
    /// statusChargingExternal / statusHoldingExternal / statusBattery）。
    private func powerSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: CellarL10n.s("statusline.power")) {
            if snapshot.externalConnected && snapshot.isCharging {
                Text(theme.word(.statusChargingExternal))
            } else if snapshot.externalConnected {
                holdingWord
            } else {
                Text(theme.word(.statusBattery))
            }
        }
    }

    /// 停充段：语汇串按「·」拆两段渲染——前缀普通色 + 状态词 holding 强调色
    /// （规格 §2.4 语义保持，A 原生视觉零回归）；串内无「·」时整串强调（回退
    /// 安全，不丢语义）。
    @ViewBuilder
    private var holdingWord: some View {
        let full = theme.word(.statusHoldingExternal)
        if let separator = full.firstIndex(of: "·") {
            HStack(spacing: 0) {
                Text(String(full[...separator]))
                Text(String(full[full.index(after: separator)...]))
                    .foregroundStyle(theme.holding)
            }
        } else {
            Text(full)
                .foregroundStyle(theme.holding)
        }
    }

    /// 电流段：幅值（mA → A，两位小数）+ 方向词（currentDirection 纯函数，
    /// 规格 §7.2；方向词 nil = 外接停充 → 只显幅值不标方向；方向词经
    /// CellarL10n 词条解析，native/amber 同值不 B 化——WP4 §4.3）。
    private func currentSegment(_ snapshot: BatterySnapshot) -> some View {
        let amperage = Double(abs(snapshot.amperageMA)) / 1000
        let ampText = String(format: "%.2f A", amperage)
        let direction = currentDirection(
            isCharging: snapshot.isCharging,
            externalConnected: snapshot.externalConnected
        )
        let word = direction.map {
            switch $0 {
            case .charging: return CellarL10n.s("direction.charging")
            case .discharging: return CellarL10n.s("direction.discharging")
            }
        }
        return segment(caption: CellarL10n.s("statusline.current")) {
            Text(word.map { "\($0) \(ampText)" } ?? ampText)
        }
    }

    /// 电压段：一位小数。
    private func voltageSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: CellarL10n.s("statusline.voltage")) {
            Text(String(format: "%.1f V", Double(snapshot.voltageMV) / 1000))
        }
    }

    /// 温度段：一位小数。温度暂停态追加「 · 暂停中」注词——词经 CellarL10n
    /// （用户可见新词不走字面量，方案 §2.5）；「40.2°C · 暂停中」形态，注词与
    /// 数值同段同字体（monospacedDigit 由 segment 统一施加）。段标签随风格
    /// （word(.tempLabel)——amber「窖温」，demo）。
    private func temperatureSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: theme.word(.tempLabel)) {
            let base = String(format: "%.1f °C", snapshot.temperatureC)
            Text(tempPauseActive ? "\(base) · \(CellarL10n.s("statusline.tempPaused"))" : base)
        }
    }

    /// 循环次数 + WP2' 健康度（batteryHealthPercent：Nominal/Design 官方口径；
    /// nominal 缺席 → rawMax 兜底；两级缺席 → 仅循环零回归）。「健康」标签随风格
    /// （word(.healthLabel)——en: Health，WP2' catalog 先行）。
    private func cycleSegment(_ snapshot: BatterySnapshot) -> some View {
        let health = batteryHealthPercent(
            nominal: snapshot.nominalChargeCapacityMAh ?? snapshot.rawMaxCapacityMAh,
            design: snapshot.designCapacityMAh
        )
        return segment(caption: CellarL10n.s("statusline.cycle")) {
            if let health {
                Text("\(snapshot.cycleCount) · \(theme.word(.healthLabel)) \(health)%")
            } else {
                Text("\(snapshot.cycleCount)")
            }
        }
    }

    /// 适配器段：W（adapter.watts 实时数据，规格 §7.2）+ 名称；均缺席 → 整段
    /// 隐藏（调用处判定）。名称过长限宽自然换行——零截断，不复用原流式布局的
    /// 压缩截断手段。
    private func adapterSegment(_ adapter: AdapterInfo) -> some View {
        segment(caption: CellarL10n.s("statusline.adapter")) {
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