import CellarCore
import SwiftUI

/// 细粒度 pending 字段（v0.19.7 §3.1）：与节内控件一一对应——仅被提交的控件呈
/// pending（禁用），节内其余控件全程可用。threshold 控件按源分流 wire 键
/// `threshold`/`cpuThreshold`，pending 同为 .threshold——显式字段 > wire 键推导
/// （双键分流使推导不可靠）。
public enum FanPendingField: Equatable, Sendable {
    case enabled
    case strategy
    case source
    case threshold
    case speed
    case stage2
    case stage2Rise
}

/// 风扇智能降温区（Phase 5 v1.1 §7；**参数驱动**——CellarUICheck 仅 import
/// CellarCore/CellarUI，App 侧薄包装桥接 StatusController；照 CalibrationSectionView
/// 先例）：
/// - 开关 Toggle（opt-in 默认关）+ 开启两步内嵌确认块（**不用 confirmationDialog
///   ——会收起 MenuBarExtra 窗口，项目踩过**，照自动放电确认块模式）；
/// - 策略 Picker 三项：恒速降温/两级分段/全速应急；
/// - 温度源 Picker（v1.11 T3 双源：电池温度【默认】/CPU 表面温度——门控三态见
///   sourceSection 注记）+ 当前源温度行（currentTempC App 层注入）；
/// - 阈值 Slider 步进 0.5，值域随源联动（battery 30–55°C / cpuSkin 40–70°C）；
///   速度 Slider 40...100%；twoStage 参数仅策略为两级分段时显形；
/// - 脚注固定文案：与充电热暂停配置（通用页可调）相互独立（v1.5 起热暂停
///   阈值可配置，脚注不再钉死数值）；
/// - 状态行八态（fan.status.*）：已关闭/探测中/自动/加速中→N rpm/保持/已暂停介入
///   （采样异常）/本机不支持/检测到其他风扇控制写入者。
///
/// 变更即应用（onApply(FanWire, FanPendingField)——缺席字段 = daemon 保持现值，
/// 第二参钉细粒度 pending）；本地滑杆态在 init 从 daemon 状态播种（照
/// CalibrationSectionView 的参数注入先例，快照矩阵可直接构造），v0.19.7 起 fan
/// nil→non-nil 到达沿全量回灌（修启动期先渲染后回包的显示陈旧）。
public struct FanSectionView: View {
    /// daemon 风扇状态（nil = 旧 daemon 未上报 → 控件禁用 + 升级提示）。
    public let fan: FanStatus?
    /// 细粒度 pending（v0.19.7）：仅被提交的控件呈禁用态，节内其余控件（含勾选框）
    /// 全程可用；nil = 无在途提交。默认 nil——既有构造点机械更新即可零扰动。
    public let pendingField: FanPendingField?
    /// 应用回调（App 侧桥接 setFan；缺席字段保持现值；第二参 = 提交字段，控制器
    /// 据此钉细粒度 pending）。
    public let onApply: (FanWire, FanPendingField) -> Void
    /// 快照矩阵注入：初始展开确认块（渲染 inactive 形态的确认态；生产恒默认 false）。
    public let initialConfirmVisible: Bool
    /// 快照矩阵注入：状态行词覆盖（生产用 fan.state；矩阵可钉死特定态）。
    public let stateOverride: FanStateWord?
    /// 首行标题开关（v1.2 视觉打磨 SR-2）：App 通用页由节头承担标题时传 false，
    /// 防同文重复；默认 true——快照矩阵两处构造不传此参 → 渲染字节不变，92 张
    /// golden 零 regen 全靠该默认路径（对比模式机械证明）。
    public let showsTitle: Bool
    /// 当前源温度 °C（v1.11 T3 新增温度行；数据源 = App 层注入（D-3f 定版）——
    /// battery 源取 batterySnapshot.temperatureC / cpuSkin 源取 FanStatus.cpuSkinTempC；
    /// nil = 无数据显示「—」。默认 nil——不传的既有调用点零扰动）。
    public let currentTempC: Double?

    @State private var showConfirm: Bool
    @State private var strategy: FanStrategy
    /// 温度源（v1.11 T3；init 播种 + 源切换 onChange 重播种阈值滑杆）。
    @State private var temperatureSource: FanTemperatureSource
    @State private var thresholdC: Double
    @State private var speedPercent: Double
    @State private var stage2Percent: Double
    @State private var stage2RiseC: Double

    @Environment(\.cellarTheme) private var theme

    public init(
        fan: FanStatus?,
        pendingField: FanPendingField? = nil,
        onApply: @escaping (FanWire, FanPendingField) -> Void,
        initialConfirmVisible: Bool = false,
        stateOverride: FanStateWord? = nil,
        showsTitle: Bool = true,
        currentTempC: Double? = nil
    ) {
        self.fan = fan
        self.pendingField = pendingField
        self.onApply = onApply
        self.initialConfirmVisible = initialConfirmVisible
        self.stateOverride = stateOverride
        self.showsTitle = showsTitle
        self.currentTempC = currentTempC
        _showConfirm = State(initialValue: initialConfirmVisible)
        // 六值 @State 播种调 seedAll 等价逻辑（静态纯函数 seedValues——与 seedAll
        // 回灌共用单一真相）。⚠️ init 内不得直接调 seedAll：未安装态对 @State
        // wrappedValue 赋值 = 运行时「constantly changing initial value」未定义
        // 行为（实测 ImageRenderer 渲染出占位值/空 Picker），State(initialValue:)
        // 形态是既有 golden 逐字节零扰动的机械保证。
        let seeds = Self.seedValues(from: fan)
        _strategy = State(initialValue: seeds.strategy)
        _temperatureSource = State(initialValue: seeds.source)
        _thresholdC = State(initialValue: seeds.thresholdC)
        _speedPercent = State(initialValue: seeds.speedPercent)
        _stage2Percent = State(initialValue: seeds.stage2Percent)
        _stage2RiseC = State(initialValue: seeds.stage2RiseC)
    }

    /// 播种值计算（纯函数；init 播种与 seedAll 回灌的单一真相）。
    private static func seedValues(from fan: FanStatus?) -> (
        strategy: FanStrategy, source: FanTemperatureSource, thresholdC: Double,
        speedPercent: Double, stage2Percent: Double, stage2RiseC: Double
    ) {
        let base = fan ?? FanStatus(
            enabled: false, strategy: .constantSpeed, state: .off,
            targetRPM: nil, currentRPM: nil, thresholdCentiC: FanPolicy.default.thresholdCentiC,
            conflictFlag: false
        )
        // 温度源播种（D-3f：线值 nil/0 → battery——旧 daemon 按 battery 口径）；
        // 阈值滑杆播种随源（battery 域 threshold / cpuSkin 域 cpuSkinThreshold——
        // 双阈值回显 = 播种单一真相，R1 P1-4）。
        let source = wiredSource(base)
        return (
            strategy: base.strategy,
            source: source,
            thresholdC: Double(seedThresholdCentiC(fan: base, source: source)) / 100,
            speedPercent: Double(base.speedPercent),
            stage2Percent: Double(base.stage2Percent),
            stage2RiseC: Double(base.stage2RiseCentiC) / 100
        )
    }

    /// 全量回灌（v0.19.7 §3.2.3 自 init 播种抽取）：六值 @State 自 fan 覆写——
    /// strategy/temperatureSource/thresholdC/speedPercent/stage2Percent/
    /// stage2RiseC。**不动 showConfirm**——确认块开合是用户会话态，重连沿复位它
    /// 会凭空收起打开中的确认块（R2 P3）。调用点 = fan 到达沿（仅沿触发、不逐值
    /// 回灌——防细粒度 pending 期它字段回包 clobber 用户正在拖动的 @State）。
    /// 已安装态（视图存活期）的 wrappedValue 赋值是 onChange 通路的标准形态。
    private func seedAll(from fan: FanStatus?) {
        let seeds = Self.seedValues(from: fan)
        strategy = seeds.strategy
        temperatureSource = seeds.source
        thresholdC = seeds.thresholdC
        speedPercent = seeds.speedPercent
        stage2Percent = seeds.stage2Percent
        stage2RiseC = seeds.stage2RiseC
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题条件渲染（SR-2）：App 通用页节头承担标题 → 传 false 防同文重复；
            // 默认 true = 快照构造路径字节不变（92 张 golden 零 regen 的机械保证）。
            if showsTitle {
                Text(CellarL10n.s("fan.title"))
                    .font(.caption2)
                    .foregroundStyle(theme.tertiaryText)
            }

            Toggle(isOn: Binding(
                get: { fan?.enabled == true },
                set: { toggle($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CellarL10n.s("fan.desc"))
                        .font(.caption)
                    if staleDaemon {
                        Text(CellarL10n.s("fan.upgradeHint"))
                            .font(.caption2)
                            .foregroundStyle(theme.warning)
                    }
                }
            }
            .disabled(pendingField == .enabled || staleDaemon)

            if showConfirm && !staleDaemon {
                confirmBlock
            }

            if fan != nil && !staleDaemon {
                // v1.12 D5：双槽在位（secondFanPresent）→ 左/右两行各自带标签与
                // 状态词（两扇独立状态机，词可不同——D3 诚实隔离）；nil（旧 daemon
                // /单风扇）→ 原单行形态字节不变（存量零回归）。
                if fan?.secondFanPresent == true {
                    fanStatusRow(
                        label: CellarL10n.s("fan.fan.left"),
                        word: effectiveState, targetRPM: fan?.targetRPM)
                    fanStatusRow(
                        label: CellarL10n.s("fan.fan.right"),
                        word: fan?.secondFanState ?? .off, targetRPM: fan?.secondFanTargetRPM)
                } else {
                    statusRow
                }
            }

            if fan != nil && !staleDaemon {
                strategyPicker
            }

            // v1.11 T3：温度源 Picker + 当前源温度行 + 阈值滑杆（值域随源联动）。
            if fan != nil && !staleDaemon {
                sourceSection
                thresholdRow
                speedRow
                if strategy == .twoStage {
                    stage2Rows
                }
            }

            Text(CellarL10n.s("fan.footnote"))
                .font(.caption2)
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 回灌（v0.19.7 G1）：App 冷启动先渲染通用页时 init 按 FanPolicy.default
        // 播种（fan 尚未回包）——不回灌则控件停留陈旧默认值，陈旧期交互会把默认
        // 值单键写回（历史配置被真实重置的成因通道）。仅 false→true 到达沿全量重
        // 播种（断连沿控件随 fan==nil 隐藏，无需处置）；onChange 不参与静态渲染
        // ——既有 golden 零扰动。
        .onChange(of: fan != nil) { arrived in
            guard arrived, let fan else { return }
            seedAll(from: fan)
        }
    }

    // MARK: - 子区

    /// 开启两步内嵌确认块（boost 是可感知行为——需明示确认；关是安全方向直通）。
    private var confirmBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CellarL10n.s("fan.warning"))
                .font(.caption)
                .foregroundStyle(theme.warning)
            HStack(spacing: 8) {
                Button(CellarL10n.s("fan.confirm")) {
                    showConfirm = false
                    onApply(FanWire(enabled: 1), .enabled)
                }
                .controlSize(.small)
                .disabled(pendingField == .enabled)
                Button(CellarL10n.s("panel.action.back")) {
                    showConfirm = false
                }
                .controlSize(.small)
            }
        }
    }

    /// 状态行八态（word + boost 目标 rpm；冲突词整行高优先级呈现）。
    private var statusRow: some View {
        fanStatusRow(label: nil, word: effectiveState, targetRPM: fan?.targetRPM)
    }

    /// 状态行本体（v1.12 参数化：label 非 nil = 双槽形态的左/右前缀——与面板
    /// 第三行 L/R 指称统一；nil = 既有单行形态零回归）。
    private func fanStatusRow(label: String?, word: FanStateWord, targetRPM: Float?) -> some View {
        let baseText = Self.stateText(word, targetRPM: targetRPM)
        return HStack(spacing: 4) {
            Image(systemName: Self.stateSymbol(word))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Self.stateColor(word, theme: theme))
            Text(label.map { "\($0) \(baseText)" } ?? baseText)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var effectiveState: FanStateWord {
        stateOverride ?? fan?.state ?? .off
    }

    /// 八态词/符号/色（v1.12 抽静态函数——左/右双行共用单一真相，防两行词表漂移）。
    private static func stateSymbol(_ word: FanStateWord) -> String {
        switch word {
        case .off, .automatic, .probing: return "fan"
        case .boost: return "fan.fill"
        case .hold: return "slider.horizontal.3"
        case .degraded: return "exclamationmark.triangle"
        case .unsupported: return "questionmark.circle"
        case .conflict: return "exclamationmark.triangle"
        }
    }

    private static func stateColor(_ word: FanStateWord, theme: CellarTheme) -> Color {
        switch word {
        case .conflict, .degraded: return theme.alert
        case .boost: return theme.accent
        case .unsupported: return theme.warning
        case .off, .probing, .automatic, .hold: return theme.secondaryText
        }
    }

    private static func stateText(_ word: FanStateWord, targetRPM: Float?) -> String {
        switch word {
        case .off: return CellarL10n.s("fan.status.off")
        case .probing: return CellarL10n.s("fan.status.probing")
        case .automatic: return CellarL10n.s("fan.status.automatic")
        case .boost:
            let rpm = targetRPM.map { "\(Int($0.rounded()))" } ?? "?"
            return CellarL10n.s("fan.status.boost", rpm)
        case .hold: return CellarL10n.s("fan.status.hold")
        case .degraded: return CellarL10n.s("fan.status.degraded")
        case .unsupported: return CellarL10n.s("fan.status.unsupported")
        case .conflict: return CellarL10n.s("fan.status.conflict")
        }
    }

    /// 策略 Picker（目录三项直渲——退役值不在 allCases，无从选中）。
    private var strategyPicker: some View {
        Picker(CellarL10n.s("fan.strategy"), selection: $strategy) {
            ForEach(FanStrategy.allCases, id: \.self) { s in
                Text(strategyLabel(s)).tag(s)
            }
        }
        .pickerStyle(.menu)
        .disabled(pendingField == .strategy)
        .onChange(of: strategy) { _ in
            onApply(FanWire(strategy: FanWire.wireValue(strategy)), .strategy)
        }
    }

    private func strategyLabel(_ s: FanStrategy) -> String {
        switch s {
        case .constantSpeed: return CellarL10n.s("fan.strategy.constantSpeed")
        case .twoStage: return CellarL10n.s("fan.strategy.twoStage")
        case .emergency: return CellarL10n.s("fan.strategy.emergency")
        }
    }

    /// 温度源区（v1.11 T3 D-3f）：源 Picker + 门控注记 + 当前源温度行。
    /// 门控三态（0.19.10 WP-C 收敛）：cpuSkinSupported == true → 可切；false →
    /// **Picker 可用**（menu picker 选项级 disabled 不可靠——社区共识，R1 P1；改
    /// 「接受误选 + daemon setFan 前置拒绝上屏」fail-visible 形态）+「本机不支持」
    /// 注记；nil（旧 daemon 温度源键缺席）→ disabled + 升级提示（照 staleDaemon
    /// disabled+hint 形态——旧 daemon 静默忽略 fanSource 回成功包，不禁用即静默错配）。
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(CellarL10n.s("fan.sourcePicker"), selection: $temperatureSource) {
                Text(CellarL10n.s("fan.source.battery")).tag(FanTemperatureSource.battery)
                Text(CellarL10n.s("fan.source.cpuSkin")).tag(FanTemperatureSource.cpuSkin)
            }
            .pickerStyle(.menu)
            // 仅升级提示（nil）态整体禁用；false（本机不支持）态解锁——用户可切
            // 电池源自救，误选 cpuSkin 由 daemon setFan 前置拒绝（FanSetError.
            // cpuSkinUnsupported）错误原文经 XPC errorReply 上屏：不静默、不回弹造假。
            .disabled(pendingField == .source || sourceGateIsUpgradeHint)
            .onChange(of: temperatureSource) { newSource in
                // 源切换重播种（新逻辑）：滑杆值域/阈值随源切换；回写经 FanWire
                // source 键（阈值键由 applyThreshold 随源分流）。
                thresholdC = reseededThreshold(for: newSource)
                onApply(FanWire(source: FanWire.wireValue(newSource)), .source)
            }
            if let note = sourceGateNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(sourceGateIsUpgradeHint ? theme.warning : theme.secondaryText)
            }
            HStack {
                Text(CellarL10n.s("fan.sourceTempLabel"))
                Spacer()
                Text(currentTempC.map { String(format: "%.1f°C", $0) } ?? CellarL10n.s("common.nodata"))
                    .monospacedDigit()
            }
            .font(.caption)
        }
    }

    /// 源 Picker 门控注记（nil = 可用无注记）。
    private var sourceGateNote: String? {
        guard let supported = fan?.cpuSkinSupported else { return CellarL10n.s("fan.upgradeHint") }
        return supported ? nil : CellarL10n.s("fan.sourceUnsupported")
    }

    private var sourceGateIsUpgradeHint: Bool { fan?.cpuSkinSupported == nil }

    // MARK: - 温度源播种/值域（v1.11 T3）

    /// 线值 → 源（nil/0 = battery——旧 daemon 温度源键缺席按 battery 播种，D-3f）。
    private static func wiredSource(_ fan: FanStatus) -> FanTemperatureSource {
        fan.temperatureSource == 1 ? .cpuSkin : .battery
    }

    /// 播种阈值（厘摄氏度）随源分流（旧 daemon/回显缺席 → 默认兜底）。
    private static func seedThresholdCentiC(fan: FanStatus, source: FanTemperatureSource) -> Int {
        switch source {
        case .battery: return fan.thresholdCentiC
        case .cpuSkin: return fan.cpuSkinThresholdCentiC ?? FanPolicy.default.cpuSkinThresholdCentiC
        }
    }

    /// 滑杆值域随源（定版：battery 30–55°C / cpuSkin 40–70°C——Ts 表面温度贴近
    /// die、静息基线高于电池温度，域独立）。
    private static func sliderRange(for source: FanTemperatureSource) -> ClosedRange<Double> {
        source == .cpuSkin ? 40...70 : 30...55
    }

    private var thresholdRange: ClosedRange<Double> { Self.sliderRange(for: temperatureSource) }

    /// 源切换重播种（clamp 进目标域——存量阈值跨域越界时钳制显示）。
    private func reseededThreshold(for source: FanTemperatureSource) -> Double {
        let centiC = fan.map { Self.seedThresholdCentiC(fan: $0, source: source) }
            ?? FanPolicy.default.thresholdCentiC
        let range = Self.sliderRange(for: source)
        return min(max(Double(centiC) / 100, range.lowerBound), range.upperBound)
    }

    private var thresholdRow: some View {
        Group {
            HStack {
                Text(CellarL10n.s("fan.threshold"))
                Spacer()
                Text(String(format: "%.1f°C", thresholdC))
                    .monospacedDigit()
            }
            .font(.caption)
            // 松手提交（P1-3）：onChange 逐档直发会按 0.5°C 步进洪水式触发 XPC——
            // 照 PanelView 松手提交先例，仅 onEditingChanged(false) 时应用一次。
            Slider(value: $thresholdC, in: thresholdRange, step: 0.5, onEditingChanged: { editing in
                if !editing { applyThreshold() }
            })
                .disabled(pendingField == .threshold)
        }
    }

    /// 阈值应用（松手提交）——回写键随源分流（battery → fanThreshold / cpuSkin →
    /// fanCpuThreshold，v1.11 T3）。
    private func applyThreshold() {
        let centiC = UInt64(Int((thresholdC * 100).rounded()))
        switch temperatureSource {
        case .battery: onApply(FanWire(threshold: centiC), .threshold)
        case .cpuSkin: onApply(FanWire(cpuThreshold: centiC), .threshold)
        }
    }

    private var speedRow: some View {
        Group {
            HStack {
                Text(CellarL10n.s("fan.speed"))
                Spacer()
                Text("\(Int(speedPercent))%")
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $speedPercent, in: 40...100, step: 1, onEditingChanged: { editing in
                if !editing { onApply(FanWire(speed: UInt64(Int(speedPercent))), .speed) }
            })
                .disabled(pendingField == .speed)
        }
    }

    /// twoStage 专属参数（仅策略 = 两级分段时显形）。
    private var stage2Rows: some View {
        Group {
            HStack {
                Text(CellarL10n.s("fan.stage2"))
                Spacer()
                Text("\(Int(stage2Percent))%")
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $stage2Percent, in: 60...100, step: 1, onEditingChanged: { editing in
                if !editing { onApply(FanWire(stage2: UInt64(Int(stage2Percent))), .stage2) }
            })
                .disabled(pendingField == .stage2)
            HStack {
                Text(CellarL10n.s("fan.stage2Rise"))
                Spacer()
                Text(String(format: "%.1f°C", stage2RiseC))
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(value: $stage2RiseC, in: 1...5, step: 0.5, onEditingChanged: { editing in
                if !editing { onApply(FanWire(stage2Rise: UInt64(Int((stage2RiseC * 100).rounded()))), .stage2Rise) }
            })
                .disabled(pendingField == .stage2Rise)
        }
    }

    // MARK: - 开关

    private var staleDaemon: Bool {
        fan == nil
    }

    /// 开关动作：开启 → 展开确认块（两步）；关闭直通（关是安全方向）。
    private func toggle(_ enabled: Bool) {
        guard !staleDaemon else { return }
        if enabled {
            showConfirm = true
        } else {
            showConfirm = false
            onApply(FanWire(enabled: 0), .enabled)
        }
    }
}