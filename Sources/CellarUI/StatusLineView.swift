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
    /// CPU 表面温度 °C（0.18 T5 D-5c 第三行；nil = 探测未命中/未采样——格隐藏）。
    /// 默认 nil 向后兼容——既有 StatusLine golden 构造不动即缺席路径 golden 证据。
    public let cpuSkinTempC: Double?
    /// 左风扇转速 rpm（nil = F0Ac 缺席——风扇格隐藏）。
    public let fanLRPM: Double?
    /// 右风扇转速 rpm（nil = F1Ac 缺席/单风扇——左值在场时两格合一「风扇 X rpm」）。
    public let fanRRPM: Double?
    /// 风扇来源标注词（0.18.1 T7：转速后小字——「系统/Cellar」策略来源澄清；
    /// nil = 不显后缀，缺席路径输出与既有构造逐字节一致——既有 golden 零 diff）。
    public let fanSource: String?
    @Environment(\.cellarTheme) private var theme

    public init(
        snapshot: BatterySnapshot?,
        tempPauseActive: Bool = false,
        cpuSkinTempC: Double? = nil,
        fanLRPM: Double? = nil,
        fanRRPM: Double? = nil,
        fanSource: String? = nil
    ) {
        self.snapshot = snapshot
        self.tempPauseActive = tempPauseActive
        self.cpuSkinTempC = cpuSkinTempC
        self.fanLRPM = fanLRPM
        self.fanRRPM = fanRRPM
        self.fanSource = fanSource
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
                    if let adapter = snapshot.adapter, !adapterParts(adapter, telemetry: snapshot.telemetry).isEmpty {
                        adapterSegment(adapter, telemetry: snapshot.telemetry)
                    }
                }
                // 0.18 T5 D-5c 观察增强第三行（仅面板消费；全 nil → 不渲染，
                // 网格保持 2×3 与现状逐字节一致）。
                if cpuSkinTempC != nil || fanLRPM != nil || fanRRPM != nil {
                    GridRow {
                        thirdRowSegments
                    }
                }
            }
        } else {
            Text(CellarL10n.s("statusline.unavailable"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 单段统一样式（规格 §7.2：caption 标签 + monospacedDigit 值）。数值字体
    /// design 随 token（UD-5：工业等宽读出感，六段全施加——语汇词 mono 可接受；
    /// A/B token 为 nil 落回 .default = 与裸 .caption 等价，golden 零扰动）。
    private func segment(caption: String, @ViewBuilder value: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
            value()
                .font(.system(.caption, design: theme.numericFontDesign ?? .default))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// 电源段：外接（充电中/已停充/电池补入）或电池供电，词随风格（§3.5 对账表——
    /// statusChargingExternal / statusHoldingExternal / statusBattery；0.19.4 §1.2
    /// 新增 statusAssistExternal）。0.19.4 §1：判定由 `flowModel(of:).kind` 派生
    /// （FlowDiagramKind 统一接管——旧 isCharging 二元分支删除；遥测缺席走 ②
    /// 回退路径，结论与旧二元版逐字节一致，既有 golden 零 diff）。
    private func powerSegment(_ snapshot: BatterySnapshot) -> some View {
        segment(caption: CellarL10n.s("statusline.power")) {
            switch flowModel(of: snapshot).kind {
            case .charging:
                Text(theme.word(.statusChargingExternal))
            case .holding:
                holdingWord(theme.word(.statusHoldingExternal), color: theme.holding)
            case .assist:
                holdingWord(theme.word(.statusAssistExternal), color: theme.warning)
            case .battery:
                Text(theme.word(.statusBattery))
            }
        }
    }

    /// 停充/补入段：语汇串按「·」拆两段渲染——前缀普通色 + 状态词强调色
    /// （规格 §2.4 语义保持；0.19.4 §1.2 R1 P2-7 抽参化：holding 传 theme.holding
    /// 原值零变化，assist 传 theme.warning）；串内无「·」时整串强调（回退
    /// 安全，不丢语义）。
    @ViewBuilder
    private func holdingWord(_ word: String, color: Color) -> some View {
        if let separator = word.firstIndex(of: "·") {
            HStack(spacing: 0) {
                Text(String(word[...separator]))
                Text(String(word[word.index(after: separator)...]))
                    .foregroundStyle(color)
            }
        } else {
            Text(word)
                .foregroundStyle(color)
        }
    }

    /// 电流段：幅值（mA → A，两位小数）+ 方向词（0.19.4 §1.1：currentDirection
    /// kind 版纯函数——方向词与流向形态同源裁决；holding → nil 只显幅值不标
    /// 方向；方向词经 CellarL10n 词条解析，native/amber 同值不 B 化——WP4 §4.3）。
    private func currentSegment(_ snapshot: BatterySnapshot) -> some View {
        let amperage = Double(abs(snapshot.amperageMA)) / 1000
        let ampText = String(format: "%.2f A", amperage)
        let direction = currentDirection(kind: flowModel(of: snapshot).kind)
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

    /// 适配器段：telemetry 在场 → 实时 W（SystemPowerIn/1000 一位小数）+ 额定副注
    /// （v1.11 T1）；缺席 → 额定 W（现状形态——输出逐字节一致，既有 golden 零修改
    /// 的机械保证：fixture 均无 PowerTelemetryData 键）+ 名称；均缺席 → 整段隐藏
    /// （调用处判定）。名称过长限宽自然换行——零截断。
    private func adapterSegment(_ adapter: AdapterInfo, telemetry: PowerTelemetry?) -> some View {
        segment(caption: CellarL10n.s("statusline.adapter")) {
            Text(adapterParts(adapter, telemetry: telemetry).joined(separator: " · "))
                .frame(maxWidth: 140, alignment: .leading)
        }
    }

    private func adapterParts(_ adapter: AdapterInfo, telemetry: PowerTelemetry?) -> [String] {
        var parts: [String] = []
        if let systemPowerMW = telemetry?.systemPowerInMW {
            // 实时 W（一位小数）+ 额定副注（复合键）；额定缺席 → 仅实时值（裸 W 形态
            // 与既有 "\(watts) W" 同语汇）。
            let liveText = String(format: "%.1f", Double(systemPowerMW) / 1000)
            if let rated = adapter.watts {
                parts.append(CellarL10n.s("statusline.adapter.live", liveText, rated))
            } else {
                parts.append("\(liveText) W")
            }
        } else if let watts = adapter.watts {
            parts.append("\(watts) W")
        }
        if let name = adapter.name {
            parts.append(name)
        }
        return parts
    }

    // MARK: - 第三行（0.18 T5 D-5c：CPU 表面温度 ｜ 风扇 L ｜ 风扇 R）

    /// 第三行三格（缺席格隐藏，D-5e：Ts 探测失败 → CPU 格隐藏；F1Ac 缺席
    /// （单风扇）→ 左右两格合一「风扇 X rpm」；F0Ac 缺席 → 风扇格隐藏）。
    /// 0.18.1 T7：风扇格转速后附来源标注小字（fanSource nil = 不显——缺席路径
    /// 渲染走与既有构造相同的裸 Text 分支，golden 逐字节零 diff 机械保证）。
    @ViewBuilder
    private var thirdRowSegments: some View {
        if let cpuSkinTempC {
            segment(caption: CellarL10n.s("statusline.cpuSkin")) {
                // 一位小数与温度段（temperatureSegment）同口径。
                Text(String(format: "%.1f °C", cpuSkinTempC))
            }
        }
        if let fanLRPM, let fanRRPM {
            segment(caption: CellarL10n.s("statusline.fanL")) {
                fanValueText(rpm: fanLRPM)
            }
            segment(caption: CellarL10n.s("statusline.fanR")) {
                fanValueText(rpm: fanRRPM)
            }
        } else if let single = fanLRPM ?? fanRRPM {
            segment(caption: CellarL10n.s("statusline.fan")) {
                fanValueText(rpm: single)
            }
        }
    }

    /// 风扇格值：nil 来源 → 裸转速 Text（与既有形态逐字节一致）；非 nil →
    /// 转速 + 来源小字（caption2 + tertiaryText——层级低于数值，「1344 rpm ·系统」
    /// 语汇不加中点，来源词独立着色区分）。
    @ViewBuilder
    private func fanValueText(rpm: Double) -> some View {
        if let fanSource {
            HStack(spacing: 4) {
                Text("\(Int(rpm.rounded())) rpm")
                Text(fanSource)
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }
        } else {
            Text("\(Int(rpm.rounded())) rpm")
        }
    }
}