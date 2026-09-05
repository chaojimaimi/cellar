/// 诊断报告类型（WP5 规格 §2/§3）：报告生成（纯函数，CellarCore 可测）与渲染
/// （可执行层只渲染）严格分离；exitCode 计算落 CellarCore。
///
/// 严重序：pass < info < warn < fail；info 不参与 worstStatus 与退出码——
/// 健康机器无 sudo 跑 doctor 即 0 分，脚本化可区分"仅非 root"与"真异常"（评审 P1-3）。

/// 检查状态四级。
public enum CheckStatus: String, Equatable, Sendable {
    case pass, info, warn, fail
}

/// 单项检查结果。
public struct DoctorCheck: Equatable, Sendable {
    public let name: String
    public let status: CheckStatus
    public let detail: String

    public init(name: String, status: CheckStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// doctor 报告：固定顺序检查（身份 → SMC 服务 → 后端 → 控制键 → 电池 → 共存 → 写权限
/// → 第 8 项 daemon）+ 汇总。第 8 项在调用方已探测（daemonProbeAttempted）时渲染：
/// 运行中 → PASS；已探测但未运行 → INFO；未探测（既有输入形态）→ 不渲染。
public struct DoctorReport: Equatable, Sendable {
    public let checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.checks = checks
    }

    /// 最严重状态（fail > warn > pass）；info 不参与（不抬升，评审 P1-3）。
    public var worstStatus: CheckStatus {
        var worst: CheckStatus = .pass
        for check in checks where check.status != .info {
            switch check.status {
            case .fail:
                return .fail
            case .warn:
                worst = .warn
            case .pass, .info:
                break
            }
        }
        return worst
    }

    /// 退出码：fail→2；warn→1；其余→0（评审 P1-4，CellarCore 可测）。
    public var exitCode: Int {
        switch worstStatus {
        case .fail: return 2
        case .warn: return 1
        case .pass, .info: return 0
        }
    }
}

/// 后端探测结果（结构化失败分类，评审 P1-1；失败携带原始错误，非字符串）。
public enum ProbeOutcome: Equatable, Sendable {
    case detected(name: String, keyNames: [String])
    /// `.noBackendAvailable`（预期降级只读，非故障）。
    case noneAvailable
    /// `makeDefault` 失败：serviceNotFound / openFailed。
    case serviceUnavailable
    /// 探测传输故障（结构化，原样保留 SMCError）。
    case failed(SMCError)
}

/// doctor 检查输入（可执行层组装，报告生成纯函数消费）。
public struct DoctorInputs: Sendable {
    /// 检查 1/7：运行是否 root。
    public let isRoot: Bool
    /// 检查 2：AppleSMC 打开成功。
    public let smcConnected: Bool
    /// 检查 3。
    public let probe: ProbeOutcome
    /// 检查 4：控制键状态（读取失败时为 nil，原因见 chargingError）。
    public let chargingEnabled: Bool?
    /// 检查 4 失败原因。
    public let chargingError: SMCError?
    /// 检查 5。
    public let snapshot: BatterySnapshot?
    /// 检查 5 失败原因（结构化）。
    public let snapshotError: BatteryMonitorError?
    /// 检查 6。
    public let conflict: ConflictScanResult
    /// 检查 8：daemon 运行状态（XPC getStatus 结果；未安装/未运行 → nil）。
    public let daemonStatus: DaemonStatus?
    /// 检查 8 是否已探测（区分"未探测"与"已探测但未运行"：后者渲染 INFO 行、
    /// 前者不渲染——既有 DoctorInputs 构造点（用例 65–68）零改动保持 7 项）。
    public let daemonProbeAttempted: Bool
    /// 检查 3 键世代标注（CHTE/CHIE/CH0B 在位矩阵；nil = 未探测，不标注——
    /// 兼容性约束：新字段全缺省值 + 条件渲染，评审 P0-3）。
    public let keyPresence: KeyPresence?
    /// 检查 6 进程层命中（「进程名[PID]」；nil = 未扫描——缺省形态零渲染）。
    public let processHits: [String]?
    /// 检查 9：launchctl print 解析的 daemon 注册态（nil = 解析失败）。
    public let btmState: BTMState?
    /// 检查 9 是否已探测（解析失败亦渲染 INFO——不静默；未探测不渲染）。
    public let btmProbeAttempted: Bool
    /// 检查 10：版本矩阵（CLI/daemon/App 三方；nil = 未探测不渲染）。
    public let versionMatrix: VersionMatrix?
    /// 检查 11：放电能力探测（nil = 未探测不渲染）。
    public let dischargeProbe: DischargeProbe?
    /// 检查 12（Phase 5 v1.1）：风扇控制只读探测（键在位矩阵 + F0Md/F0Tg 现态 +
    /// daemon 配置现态；nil = 未探测不渲染——异常现态可见化，配合 §6.5 残留窗口）。
    public let fanProbe: FanDoctorProbe?
    /// 检查 13（Phase 5 v1.5）：热暂停配置现态（daemon 回读；nil = 旧 daemon 未
    /// 上报/未运行——`thermalProbeAttempted` 区分「未探测」与「已探测但不可得」，
    /// 后者渲染 INFO 行、前者不渲染——检查 8/9 同款条件渲染兼容约束）。
    public let thermal: ThermalStatus?
    /// 检查 13 是否已探测（DoctorCommand 恒 true——getStatus 总会尝试）。
    public let thermalProbeAttempted: Bool

    public init(
        isRoot: Bool,
        smcConnected: Bool,
        probe: ProbeOutcome,
        chargingEnabled: Bool?,
        chargingError: SMCError?,
        snapshot: BatterySnapshot?,
        snapshotError: BatteryMonitorError?,
        conflict: ConflictScanResult,
        daemonStatus: DaemonStatus? = nil,
        daemonProbeAttempted: Bool = false,
        keyPresence: KeyPresence? = nil,
        processHits: [String]? = nil,
        btmState: BTMState? = nil,
        btmProbeAttempted: Bool = false,
        versionMatrix: VersionMatrix? = nil,
        dischargeProbe: DischargeProbe? = nil,
        fanProbe: FanDoctorProbe? = nil,
        thermal: ThermalStatus? = nil,
        thermalProbeAttempted: Bool = false
    ) {
        self.isRoot = isRoot
        self.smcConnected = smcConnected
        self.probe = probe
        self.chargingEnabled = chargingEnabled
        self.chargingError = chargingError
        self.snapshot = snapshot
        self.snapshotError = snapshotError
        self.conflict = conflict
        self.daemonStatus = daemonStatus
        self.daemonProbeAttempted = daemonProbeAttempted
        self.keyPresence = keyPresence
        self.processHits = processHits
        self.btmState = btmState
        self.btmProbeAttempted = btmProbeAttempted
        self.versionMatrix = versionMatrix
        self.dischargeProbe = dischargeProbe
        self.fanProbe = fanProbe
        self.thermal = thermal
        self.thermalProbeAttempted = thermalProbeAttempted
    }
}

/// 检查 12 输入：风扇键只读探测（CLI DoctorCommand 组装；只读——不写任何键）。
public struct FanDoctorProbe: Equatable, Sendable {
    /// 在位键列表（F0Tg/F0Md/F0Ac/F0Mn/F0Mx 探测结果；按探测顺序）。
    public let keysPresent: [String]
    /// F0Md 现态（0=系统自动；nil = 读取失败/缺席）。
    public let mdValue: UInt8?
    /// F0Tg 现态 rpm（LE 解码；nil = 读取失败/缺席）。
    public let tgRPM: Float?
    /// daemon 风扇配置现态（FanStatus；nil = 旧 daemon 未上报/未运行）。
    public let config: FanStatus?

    public init(keysPresent: [String], mdValue: UInt8?, tgRPM: Float?, config: FanStatus?) {
        self.keysPresent = keysPresent
        self.mdValue = mdValue
        self.tgRPM = tgRPM
        self.config = config
    }
}

/// 检查/报告生成器：纯函数，输入 → 检查报告（顺序与判定规则见规格 §3；第 8 项 daemon
/// 在 daemonProbeAttempted 时追加在末尾——既有 0..6 下标断言不受影响）。
public enum DoctorReportGenerator {
    public static func generate(_ inputs: DoctorInputs) -> DoctorReport {
        var checks = [
            identity(inputs),
            smcService(inputs),
            backendProbe(inputs),
            chargingKey(inputs),
            batteryReading(inputs),
            coexistence(inputs),
            writePermission(inputs),
        ]
        if let daemonCheck = daemon(inputs) {
            checks.append(daemonCheck)
        }
        // WP5 新增 9–11：与检查 8 同款条件渲染（对应探测字段非缺省时追加在末尾；
        // 缺省形态零渲染——用例 65 count==7 / 69 count==8 断言不动，评审 P0-3）。
        if let btmCheck = btmRegistration(inputs) {
            checks.append(btmCheck)
        }
        if let versionCheck = versionMatrixCheck(inputs) {
            checks.append(versionCheck)
        }
        if let dischargeCheck = dischargeCapability(inputs) {
            checks.append(dischargeCheck)
        }
        // Phase 5 v1.1 检查 12：风扇控制（条件渲染同 9-11——fanProbe 缺省零渲染）。
        if let fanCheck = fanControl(inputs) {
            checks.append(fanCheck)
        }
        // Phase 5 v1.5 检查 13：热暂停配置（已探测但 daemon 缺席 → INFO 行，照检查
        // 8/9 先例；未探测缺省形态零渲染——既有 count 断言不受影响）。
        if let thermalCheck = thermalConfig(inputs) {
            checks.append(thermalCheck)
        }
        return DoctorReport(checks: checks)
    }

    // MARK: - 检查 1：运行身份

    private static func identity(_ inputs: DoctorInputs) -> DoctorCheck {
        if inputs.isRoot {
            return DoctorCheck(name: "运行身份", status: .pass, detail: "具备写入能力")
        }
        return DoctorCheck(name: "运行身份", status: .info, detail: "读取可用；写入需 root（限充控制经 daemon）")
    }

    // MARK: - 检查 2：SMC 服务

    private static func smcService(_ inputs: DoctorInputs) -> DoctorCheck {
        if inputs.smcConnected {
            return DoctorCheck(name: "SMC 服务", status: .pass, detail: "AppleSMC 连接正常")
        }
        return DoctorCheck(name: "SMC 服务", status: .fail, detail: "AppleSMC 连接失败（服务未找到或打开失败）")
    }

    // MARK: - 检查 3：后端探测

    private static func backendProbe(_ inputs: DoctorInputs) -> DoctorCheck {
        switch inputs.probe {
        case .detected(let name, let keyNames):
            var detail = "探测到 \(name) 后端（控制键：\(keyNames.joined(separator: ", "))）"
            // 键世代 info 标注（检查 3 并入，不改 status）：键在位矩阵非缺省时附加。
            if let matrix = inputs.keyPresence {
                var annotations: [String] = []
                if matrix.chte == true { annotations.append("CHTE 世代") }
                if matrix.ch0b == true { annotations.append("CH0B 世代") }
                if matrix.chie == true { annotations.append("CHIE 在位（支持放电）") }
                if !annotations.isEmpty {
                    detail += "（" + annotations.joined(separator: "；") + "）"
                }
            }
            return DoctorCheck(name: "后端探测", status: .pass, detail: detail)
        case .noneAvailable:
            return DoctorCheck(
                name: "后端探测", status: .info,
                detail: "只读模式：未探测到可用控制后端（非 root 时结论仅供参考）"
            )
        case .serviceUnavailable:
            return DoctorCheck(
                name: "后端探测", status: .fail,
                detail: "SMC 服务不可用，无法探测控制后端"
            )
        case .failed(let error):
            return DoctorCheck(name: "后端探测", status: .fail, detail: "\(error)")
        }
    }

    // MARK: - 检查 4：控制键状态

    private static func chargingKey(_ inputs: DoctorInputs) -> DoctorCheck {
        if let error = inputs.chargingError {
            return DoctorCheck(name: "控制键状态", status: .fail, detail: "\(error)")
        }
        if let enabled = inputs.chargingEnabled {
            return DoctorCheck(
                name: "控制键状态", status: .pass,
                detail: enabled ? "充电使能" : "已停充"
            )
        }
        // 输入域外（错误与值皆缺）：按失败呈现，不静默。
        return DoctorCheck(name: "控制键状态", status: .fail, detail: "控制键状态未知（读取异常）")
    }

    // MARK: - 检查 5：电池读数（检查 5 定版为 FAIL：电池工具无电池读数即失败，评审 P0-3）

    private static func batteryReading(_ inputs: DoctorInputs) -> DoctorCheck {
        if let snapshot = inputs.snapshot {
            return DoctorCheck(
                name: "电池读数", status: .pass,
                detail: "电量 \(snapshot.percent)%（\(snapshot.isCharging ? "充电中" : "未充电")）"
            )
        }
        if let error = inputs.snapshotError {
            return DoctorCheck(name: "电池读数", status: .fail, detail: "\(error)")
        }
        // 输入域外（快照与错误皆缺）：按失败呈现，不静默。
        return DoctorCheck(name: "电池读数", status: .fail, detail: "无电池读数")
    }

    // MARK: - 检查 6：共存检测

    private static func coexistence(_ inputs: DoctorInputs) -> DoctorCheck {
        var entries: [String] = []
        entries.append(contentsOf: inputs.conflict.exact)
        for name in inputs.conflict.generic {
            // 通用词根兜底命中（尤其 power 词根易误报）在报告 detail 标注"疑似"。
            entries.append(name.lowercased().contains("power") ? "\(name)（疑似）" : name)
        }
        // 进程层命中并入（WP5 §2.2）：与目录命中分列来源标注；warn 语义同目录命中
        // （疑似共存提示，非健康失败）。
        let processHits = inputs.processHits ?? []
        if !processHits.isEmpty {
            entries.append("进程命中：" + processHits.joined(separator: "、"))
        }
        guard !entries.isEmpty else {
            return DoctorCheck(name: "共存检测", status: .pass, detail: "未检测到其他充电管理工具")
        }
        return DoctorCheck(
            name: "共存检测", status: .warn,
            detail: "检测到 \(entries.joined(separator: "、"))：控制操作前请退出其他充电管理工具"
        )
    }

    // MARK: - 检查 7：写权限

    private static func writePermission(_ inputs: DoctorInputs) -> DoctorCheck {
        if inputs.isRoot {
            return DoctorCheck(name: "写权限", status: .pass, detail: "具备")
        }
        return DoctorCheck(
            name: "写权限", status: .info,
            detail: "不具备（写入需 root；安装 daemon 后经 XPC 执行）"
        )
    }

    // MARK: - 检查 8：daemon（WP6 增补）

    /// 运行中（mode ∈ {active, disabled}）→ PASS；已探测但未运行 → INFO；
    /// 未探测 → nil（不渲染）。mode 异常（校验域外）→ FAIL（显式暴露，不静默）。
    private static func daemon(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.daemonProbeAttempted else { return nil }
        if let status = inputs.daemonStatus {
            guard status.mode == "active" || status.mode == "disabled" else {
                return DoctorCheck(
                    name: "daemon", status: .fail,
                    detail: "daemon 状态异常（mode=\(status.mode)）"
                )
            }
            return DoctorCheck(
                name: "daemon", status: .pass,
                detail: "运行中（\(status.mode)，上限 \(status.upperLimit)%，滞回 \(status.hysteresis)）"
            )
        }
        return DoctorCheck(
            name: "daemon", status: .info,
            detail: "未安装或未运行（sudo cellar install 或从 Cellar 面板安装可启用限充）"
        )
    }

    // MARK: - 检查 12：风扇控制（Phase 5 v1.1 增补；条件渲染同 9-11）

    /// 风扇键只读探测 + F0Md/F0Tg 现态 + daemon 配置现态（键缺属性 = 本机不支持，
    /// INFO 不抬退出码；F0Md≠0 = 可能残留禁用，WARN 显式可见化——配合 §6.5
    /// 启动恢复窗口与硬件验收重启项）。
    private static func fanControl(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard let probe = inputs.fanProbe else { return nil }
        let present = probe.keysPresent
        guard present.contains("F0Tg") && present.contains("F0Md") else {
            return DoctorCheck(
                name: "风扇控制", status: .info,
                detail: "本机无风扇控制键（在位：\(present.isEmpty ? "无" : present.joined(separator: "、"))）——功能不可用属预期"
            )
        }
        var status: CheckStatus = .pass
        var parts = ["键在位（" + present.joined(separator: "、") + "）"]
        if let md = probe.mdValue {
            if md != 0 {
                // P3-6：配置开启（enabled）时的 F0Md=1 是合法介入态（boost 两步写
                // 的解锁步行进中）——INFO 措辞，避免硬件验收并发项（§11 项 2/6）
                // 误报；关闭/无配置态 → WARN 残留嫌疑（异常现态可见化，配合 §6.5）。
                let intervening = probe.config?.enabled == true
                status = intervening ? .info : .warn
                parts.append(intervening
                    ? "F0Md=\(md)（策略介入中——风扇加速运行）"
                    : "F0Md=\(md)（非系统自动值——疑似残留，daemon 未运行时可重启清理）")
            } else {
                parts.append("F0Md=0（系统自动）")
            }
        } else {
            parts.append("F0Md 读取失败")
        }
        if let tg = probe.tgRPM {
            parts.append("F0Tg≈\(Int(tg.rounded()))rpm")
        } else {
            parts.append("F0Tg 读取失败")
        }
        if let config = probe.config {
            parts.append("配置=\(config.enabled ? "开启" : "关闭")（\(config.strategy.rawValue)，阈值 "
                + String(format: "%.1f", Double(config.thresholdCentiC) / 100) + "°C）")
        }
        return DoctorCheck(name: "风扇控制", status: status, detail: parts.joined(separator: "；"))
    }

    // MARK: - 检查 13：热暂停配置（Phase 5 v1.5 增补；条件渲染同 9-12）

    /// daemon 回读热暂停配置现态 + 是否默认值（UD-6：文案明示与风扇阈值相互独立；
    /// 恢复点 = 暂停点 − 滞回 派生，不单列）。daemon 未运行 → INFO（沿用检查 8
    /// 的安装提示覆盖，本项显式说明读不到配置）；在线但未上报两键 = 旧 daemon
    ///（R-4）→ INFO 升级提示。
    private static func thermalConfig(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.thermalProbeAttempted else { return nil }
        guard let thermal = inputs.thermal else {
            if inputs.daemonStatus != nil {
                return DoctorCheck(
                    name: "热暂停配置", status: .info,
                    detail: "守护进程在线但未上报热暂停配置（旧版本 daemon，建议重装升级）"
                )
            }
            return DoctorCheck(
                name: "热暂停配置", status: .info,
                detail: "守护进程未运行，无法读取热配置"
            )
        }
        let isDefault = thermal.pauseCentiC == ThermalPolicy.default.pauseCentiC
            && thermal.hysteresisCentiC == ThermalPolicy.default.hysteresisCentiC
        let detail = "热暂停配置：≥"
            + String(format: "%.1f", Double(thermal.pauseCentiC) / 100)
            + "°C 暂停 / 滞回 "
            + String(format: "%.1f", Double(thermal.hysteresisCentiC) / 100)
            + "°C（" + (isDefault ? "默认" : "自定义") + "；与风扇阈值相互独立）"
        return DoctorCheck(name: "热暂停配置", status: .pass, detail: detail)
    }
}