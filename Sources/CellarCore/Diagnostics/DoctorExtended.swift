import Foundation

/// WP5 §2.1 检查 9–11 类型 + daemon 注册态解析（CellarCore 纯函数层，可测）。
///
/// 兼容性约束（方案 §2 评审 P0-3）：DoctorInputs 新字段全带缺省值，新增检查仅在
/// 对应探测字段非缺省时渲染——用例 65（count==7）/69（count==8）零改动成立。
/// 子进程调用（launchctl print）在 CLI 收集层，本文件只含解析/判定纯函数（评审
/// P2-1 分层）。

// MARK: - 检查 9：守护进程注册态（launchctl print 同域可见 BTM/手工两路线——标签按语义命名）

/// daemon 注册态（`launchctl print system/com.cellar.daemon` 解析结果）。
public enum BTMState: Equatable, Sendable {
    /// launchd 已加载且运行中。
    case running
    /// 注册在但启动失败（BTM 缓存失效/程序缺失；last exit code 78 EX_CONFIG 等）。
    case spawnFailed
    /// 未注册（手工路线正常形态 / 托管路线注册掉落）。
    case unregistered
}

extension BTMState {
    /// launchctl print 输出 → 注册态（纯函数；宽松匹配，缺字段不崩）。
    ///
    /// 判定（2026-09-02 实测样本定版）：
    /// - 未注册："Could not find service" 或空输出（print 非零退出且无输出头）。
    /// - 运行中：`state = running`，或含 program identifier / program = 且无失败特征。
    /// - 启动失败：初始化失败特征行（"Could not find and/or execute program
    ///   specified by service" / "Service could not initialize: copy_bundle_path" /
    ///   "exited due to exit(" / "job state = spawn failed" / "last exit code =
    ///   78: EX_CONFIG"）。
    /// - 其余（有输出但无任何特征行）→ nil = 解析失败（调用方按 info 呈现，不误报）。
    ///
    /// 优先级：运行中优先于残留失败特征——运行中的服务会保留上次崩溃的
    /// last exit code，仅凭 exit code 判定会把健康服务误报为失败。
    public static func parseLaunchctlPrint(_ output: String) -> BTMState? {
        var stateRunning = false
        var spawnFailed = false
        var hasProgramIdentifier = false
        var unregistered = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("Could not find service") { unregistered = true }
            if line == "state = running" { stateRunning = true }
            if line.hasPrefix("program identifier") || line.hasPrefix("program = ") {
                hasProgramIdentifier = true
            }
            if line.contains("Could not find and/or execute program specified by service")
                || line.contains("Service could not initialize: copy_bundle_path")
                || line.contains("exited due to exit(")
                || line.contains("job state = spawn failed")
                || line.contains("last exit code = 78: EX_CONFIG") {
                spawnFailed = true
            }
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unregistered }
        if unregistered { return .unregistered }
        if stateRunning { return .running }
        if spawnFailed { return .spawnFailed }
        if hasProgramIdentifier { return .running }
        return nil
    }
}

// MARK: - 检查 3 键在位矩阵

/// 控制键在位矩阵（检查 3 detail 世代标注输入；nil = 该项探测失败——标注跳过不误报）。
public struct KeyPresence: Equatable, Sendable {
    public let chte: Bool?
    public let chie: Bool?
    public let ch0b: Bool?

    public init(chte: Bool?, chie: Bool?, ch0b: Bool?) {
        self.chte = chte
        self.chie = chie
        self.ch0b = ch0b
    }
}

// MARK: - 检查 10 版本矩阵

/// 版本矩阵输入（检查 10；daemon/app 缺席 = 对应探测失败，按 info 呈现）。
public struct VersionMatrix: Equatable, Sendable {
    /// CLI 编译期版本（与 DaemonXPC.daemonVersion 同源）。
    public let cliVersion: String
    /// daemon 回包版本（XPC getStatus；nil = daemon 未运行）。
    public let daemonVersion: String?
    /// App 版本（/Applications/Cellar.app 的 CFBundleShortVersionString；nil = 未安装）。
    public let appVersion: String?

    public init(cliVersion: String, daemonVersion: String?, appVersion: String?) {
        self.cliVersion = cliVersion
        self.daemonVersion = daemonVersion
        self.appVersion = appVersion
    }
}

// MARK: - 检查 11 放电能力

/// 放电能力探测输入（检查 11；CHIE 值与后端协议同源，见 Discharge.adapterState）。
public struct DischargeProbe: Equatable, Sendable {
    /// supportsDischarge（后端 tahoe ∧ CHIE 在位）。
    public let supported: Bool
    /// CHIE 现值语义（true = 适配器使能 0x00；false = 禁用 0x08；nil = 读取失败/键不可见）。
    public let chieState: Bool?
    /// CHIE 读取失败标志（键可见性不稳定/非 root——按 info 降级不误报）。
    public let readFailed: Bool
    /// 0.20 M1a：CHIE 放电控制面探测结论（§2.3 doctor 27 分支——26 探测成功形态
    /// / 既有构造点缺省 nil 零渲染，兼容性约束同 DoctorInputs 新字段纪律）。
    public let controlPlane: RuntimeProbe.DischargeControlPlane?

    public init(
        supported: Bool, chieState: Bool?, readFailed: Bool,
        controlPlane: RuntimeProbe.DischargeControlPlane? = nil
    ) {
        self.supported = supported
        self.chieState = chieState
        self.readFailed = readFailed
        self.controlPlane = controlPlane
    }
}

// MARK: - 检查 18：topoffprotection 域状态（0.20 M1a §2.3/work-order——root 只读展示）

/// topoffprotection 偏好域状态（WP2 <80% 限充通道的执法域；
/// `/var/root/Library/Preferences/com.apple.smartcharging.topoffprotection`——
/// SMC-NOTES §11.5 实测键：MCLFeatureState / mclLimitValue）。**仅展示/残留诊断
/// 用**（R2-P2：域存在性不作为 sub80 能力上报条件；写通道与卫生条款 M1b 落地）。
public struct TopoffDomainDoctorProbe: Equatable, Sendable {
    /// 域是否在位（干净 27 机器未首写时缺席——展示「干净形态」而非故障）。
    public let domainPresent: Bool
    /// MCLFeatureState（nil = 键缺席/读失败）。
    public let featureState: Int?
    /// mclLimitValue（nil = 键缺席/读失败）。
    public let mclLimit: Int?
    /// 读取失败/受限详情（nil = 成功读取——非 root / 域缺席也落此字段）。
    public let readDetail: String?

    public init(domainPresent: Bool, featureState: Int?, mclLimit: Int?, readDetail: String?) {
        self.domainPresent = domainPresent
        self.featureState = featureState
        self.mclLimit = mclLimit
        self.readDetail = readDetail
    }

    /// topoff 域 defaults 路径（root 用户域；defaults 按路径定位 plist 文件）。
    public static let defaultsPath = "/var/root/Library/Preferences/com.apple.smartcharging.topoffprotection"

    /// `defaults read` 整数输出解析（纯函数）：trim 后整数字符串 → Int；其余
    /// （含空/多行/文本）→ nil。
    public static func parseInt(_ output: String) -> Int? {
        Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 域状态采集（IO 经 `run` 注入——CellarCoreCheck 场景域可测；生产接线传
    /// DoctorCommand.runProcessCapture 同款闭包）。三次只读 `defaults read`：
    /// 域整体（存在性）→ 两键现值。非 root → 受限形态（诚实标注，不误报）。
    public static func collect(
        isRoot: Bool,
        defaultsPath: String = TopoffDomainDoctorProbe.defaultsPath,
        run: (_ executablePath: String, _ arguments: [String]) -> (output: String, exitCode: Int32)
    ) -> TopoffDomainDoctorProbe {
        guard isRoot else {
            return TopoffDomainDoctorProbe(
                domainPresent: false, featureState: nil, mclLimit: nil,
                readDetail: "非 root 不可读（sudo cellar doctor 复核）"
            )
        }
        let domainRead = run("/usr/bin/defaults", ["read", defaultsPath])
        guard domainRead.exitCode == 0 else {
            return TopoffDomainDoctorProbe(
                domainPresent: false, featureState: nil, mclLimit: nil,
                readDetail: "域未创建（干净形态——<80 限充首用时由 daemon 写入）"
            )
        }
        func keyInt(_ key: String) -> Int? {
            let keyRead = run("/usr/bin/defaults", ["read", defaultsPath, key])
            guard keyRead.exitCode == 0 else { return nil }
            return parseInt(keyRead.output)
        }
        return TopoffDomainDoctorProbe(
            domainPresent: true,
            featureState: keyInt("MCLFeatureState"),
            mclLimit: keyInt("mclLimitValue"),
            readDetail: nil
        )
    }
}

// MARK: - 检查 9/10/11 生成器（DoctorReportGenerator 跨文件扩展）

extension DoctorReportGenerator {
    /// 检查 9：daemon 注册态。已探测（btmProbeAttempted）才渲染：
    /// running=PASS；spawnFailed=FAIL（附 README「更新 App」节恢复指引）；
    /// unregistered=INFO（双路线文案：手工路线正常形态 / 托管路线注册掉落）；
    /// 解析失败=INFO（不误报）。
    static func btmRegistration(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.btmProbeAttempted else { return nil }
        switch inputs.btmState {
        case .running:
            return DoctorCheck(name: "守护进程注册", status: .pass, detail: "daemon 已注册且运行中")
        case .spawnFailed:
            return DoctorCheck(
                name: "守护进程注册", status: .fail,
                detail: "daemon 注册存在但启动失败（更新 App 后 BTM 缓存失效的典型形态）——见 README「更新 App」节：重启或 sudo cellar install 恢复"
            )
        case .unregistered:
            return DoctorCheck(
                name: "守护进程注册", status: .info,
                detail: "daemon 未注册——手工路线为正常形态（sudo cellar install 安装）；托管路线为注册掉落（请在面板重装或重启系统）"
            )
        case nil:
            return DoctorCheck(
                name: "守护进程注册", status: .info,
                detail: "注册态解析失败（launchctl print 输出不可识别）——以 XPC 连通性（检查 8）为准"
            )
        }
    }

    /// 检查 10：版本矩阵。daemon 缺席 → INFO（无从比对）；daemon≠CLI → FAIL（stale
    /// 既有语义）；App≠其他 → WARN；App 缺席 → INFO；三方一致 → PASS。
    static func versionMatrixCheck(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard let matrix = inputs.versionMatrix else { return nil }
        guard let daemonVersion = matrix.daemonVersion else {
            return DoctorCheck(name: "版本矩阵", status: .info, detail: "daemon 未运行，版本无法比对")
        }
        if daemonVersion != matrix.cliVersion {
            return DoctorCheck(
                name: "版本矩阵", status: .fail,
                detail: "daemon \(daemonVersion) ≠ CLI \(matrix.cliVersion)——陈旧 daemon，请重跑 sudo cellar install 升级"
            )
        }
        guard let appVersion = matrix.appVersion else {
            return DoctorCheck(name: "版本矩阵", status: .info, detail: "App 未安装（/Applications/Cellar.app 缺席）")
        }
        if appVersion != matrix.cliVersion {
            return DoctorCheck(
                name: "版本矩阵", status: .warn,
                detail: "App \(appVersion) ≠ CLI/daemon \(matrix.cliVersion)——App 版本滞后，替换 /Applications/Cellar.app 后重启"
            )
        }
        return DoctorCheck(name: "版本矩阵", status: .pass, detail: "CLI/daemon/App 三方一致（\(matrix.cliVersion)）")
    }

    /// 检查 11：放电能力（判定表见方案 §2.1，逐字；0.20 M1a 扩 27 控制面臂）：
    /// 不支持=INFO；动作活跃（kind==dischargeToLimit）∧ CHIE=禁用 0x08 → PASS、
    /// 动作活跃其他值 → WARN；无动作 CHIE=使能 0x00 → PASS、CHIE=禁用 0x08 →
    /// FAIL（巡检残留，附恢复指引）；读取失败/非 root → INFO（键可见性不稳定，
    /// 与检查 3 同降级）。
    /// 27 臂（M1a §2.3）：controlPlane == .writable → 与 supported 等效可用（CHIE
    /// 控制面路径）；.unavailable → 「放电控制面不可用」；.writabilityUnknown →
    /// INFO（非 root 可写性未知，不误报）。
    static func dischargeCapability(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard let probe = inputs.dischargeProbe else { return nil }
        let planeAvailable = probe.controlPlane == .writable
        guard probe.supported || planeAvailable else {
            if probe.controlPlane == .unavailable {
                return DoctorCheck(
                    name: "放电能力", status: .info,
                    detail: "放电控制面不可用（CHIE 探针未通过——macOS 27 放电功能不可用属平台事实）"
                )
            }
            if probe.controlPlane == .writabilityUnknown {
                // 可写性未探测（doctor 只读契约 writeProbe: false——P2 评审修法）：
                // 与检查 4 的「在位」口径一致，不落「CHIE 在位」未满足的既有文案
                // （诚实化，检查间不打架）；可写性裁定归 daemon 启动探测。
                return DoctorCheck(
                    name: "放电能力", status: .info,
                    detail: "CHIE 在位但可写性未知（doctor 只读契约）——可写性由 daemon 启动探测裁定"
                )
            }
            return DoctorCheck(
                name: "放电能力", status: .info,
                detail: "放电不可用（需 Tahoe 代后端且 CHIE 在位）"
            )
        }
        guard !probe.readFailed else {
            return DoctorCheck(
                name: "放电能力", status: .info,
                detail: "CHIE 读取不可用（键可见性不稳定，需 root 复核）"
            )
        }
        let discharging = probe.chieState == false   // CHIE=0x08：适配器禁用 = 放电中
        let actionActive = inputs.daemonStatus?.action?.kind == Discharge.dischargeToLimitKind
        if actionActive {
            if discharging {
                return DoctorCheck(name: "放电能力", status: .pass, detail: "放电动作活跃，适配器已禁用（预期态）")
            }
            return DoctorCheck(
                name: "放电能力", status: .warn,
                detail: "放电动作活跃但 CHIE 回读异常（应为禁用 0x08）"
            )
        }
        if !discharging {
            return DoctorCheck(name: "放电能力", status: .pass, detail: "适配器已使能（CHIE=0x00）")
        }
        return DoctorCheck(
            name: "放电能力", status: .fail,
            detail: "CHIE 残留禁用（0x08）——巡检本应 1 tick 内清零，疑似巡检失效或 daemon 未运行；重启系统或重装 daemon（sudo cellar install）恢复"
        )
    }

    // MARK: - 检查 18：topoffprotection 域状态（0.20 M1a；条件渲染同 9-17）

    /// root 只读展示（**info 恒不抬退出码**——R2-P2：域存在性仅诊断展示用，不构
    /// 成健康判定；sub80 能力上报与域存在性解耦）。非 root / 域缺席 / 键缺席均
    /// INFO 诚实呈现，不误报。
    static func topoffDomain(_ inputs: DoctorInputs) -> DoctorCheck? {
        guard inputs.topoffDomainProbeAttempted else { return nil }
        guard let probe = inputs.topoffDomain else {
            return DoctorCheck(
                name: "topoff 域", status: .info,
                detail: "topoffprotection 域状态未采集"
            )
        }
        guard probe.domainPresent else {
            return DoctorCheck(
                name: "topoff 域", status: .info,
                detail: probe.readDetail ?? "域未创建（干净形态）"
            )
        }
        var parts = ["域在位"]
        if let state = probe.featureState {
            parts.append("MCLFeatureState=\(state)")
        } else {
            parts.append("MCLFeatureState 缺席")
        }
        if let limit = probe.mclLimit {
            parts.append("mclLimitValue=\(limit)")
        } else {
            parts.append("mclLimitValue 缺席")
        }
        // 0.20 M1b：通道执法态展示（daemon 回读 sub80State——active/degraded/off
        // 三态；旧 daemon/未运行缺席不渲染）。
        if let channelState = inputs.daemonStatus?.sub80State {
            parts.append("通道态=\(channelState.rawValue)")
        }
        return DoctorCheck(
            name: "topoff 域", status: .info,
            detail: parts.joined(separator: "；") + "（<80% 限充执法域——0.20 起 daemon 管理）"
        )
    }
}