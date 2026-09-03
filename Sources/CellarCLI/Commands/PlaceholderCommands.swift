import ArgumentParser
import CellarCore
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// WP6 写路径回填（规格 §5）：set/enable/disable 经 raw XPC 由 root daemon 执行
// （写入路径唯一——Phase 1 不存在 CLI 直写 SMC 的双写者形态）；
// install/uninstall 为 root 安装器。全部命令要求 root（非 root → "请使用 sudo" + 退出 1）。
//
// XPC 失败矩阵（评审 E-3，不静默）：timeout/connectionFailed → "daemon 未安装或未运行
// （sudo cellar install）"+ 退出 69；daemonError → 打印原文 + 退出 1。

/// 写路径命令共用助手（本文件的命令与 status/doctor 共用）。
enum DaemonCommandHelpers {
    /// 固定指引文案（规格 §5）：XPC 不可达的统一呈现。
    static let daemonUnavailableMessage = "daemon 未安装或未运行（sudo cellar install）"

    /// root 前置检查：非 root → 提示并抛 ExitCode(1)。
    static func requireRoot(_ operation: String) throws {
        guard RuntimeProbe.isRunningAsRoot else {
            print("请使用 sudo cellar \(operation)")
            throw ExitCode(1)
        }
    }

    /// 路由查询（防线 c）：launchctl print system/com.cellar.daemon 输出 → route 纯函数。
    /// launchctl print 对已加载系统服务任意身份可读（2026-09-01 实测）——root/非 root
    /// 同路径；同时识别手工格式（program 行）与 SMAppService/BTM 托管格式（managed_by 行）。
    static func queryDaemonRoute() -> DaemonRoute {
        let printResult = DaemonInstaller.runLaunchctl(["print", "system/com.cellar.daemon"])
        return DaemonRoute.route(fromPrintOutput: printResult.outputText)
    }

    /// install 托管态守卫（§2.7）：检测到 App 托管 daemon → 拒绝并指引（App 面板管理）。
    static func guardInstallNotAppManaged() throws {
        guard queryDaemonRoute() != .appManaged else {
            print("❌ 检测到 App 托管（SMAppService）的守护进程，已中止手工安装")
            print("   请在 Cellar 菜单栏面板中管理；确需切换手工路线时请先在面板卸载")
            throw ExitCode(1)
        }
    }

    /// uninstall 托管态守卫（§2.7）：检测到 App 托管 daemon → 拒绝并指引孤儿态出口
    /// （BTM 注册只有属主 App 与系统设置两条撤销路）。
    static func guardUninstallNotAppManaged() throws {
        guard queryDaemonRoute() != .appManaged else {
            print("❌ 检测到 App 托管（SMAppService）的守护进程，已中止手工卸载")
            print("   请在 Cellar 面板卸载；若 App 已删除：系统设置 → 通用 → 登录项与扩展 → 移除")
            throw ExitCode(1)
        }
    }

    /// XPC 调用与失败矩阵：成功 → 打印状态；timeout/connectionFailed → 指引 + 69；
    /// daemonError → 原文 + 1。
    static func runDaemonCall(_ body: () throws -> DaemonStatus) throws {
        do {
            let status = try body()
            printStatus(status)
        } catch DaemonClientError.timeout, DaemonClientError.connectionFailed {
            print(daemonUnavailableMessage)
            throw ExitCode(69)
        } catch DaemonClientError.daemonError(let message) {
            print(message)
            throw ExitCode(1)
        } catch {
            // 理论不可达（DaemonXPCClient 只抛上述三态）；兜底按 daemonError 呈现，不静默。
            print("daemon 调用失败：\(error)")
            throw ExitCode(1)
        }
    }

    /// daemon 状态段渲染（status/install/set/enable/disable 共用）。
    static func printStatus(_ status: DaemonStatus) {
        let modeText = status.mode == "active" ? "限充管理中" : "已停用"
        print("daemon：运行中 · 模式：\(modeText)")
        print("策略：上限 \(status.upperLimit)% · 滞回 \(status.hysteresis)%（恢复阈值 \(status.upperLimit - status.hysteresis)%）")
        // WP2' 自动放电行（flag == nil = 旧 daemon 未上报，不渲染该行）。
        if let autoDischargeEnabled = status.autoDischargeEnabled {
            print("自动放电：\(autoDischargeEnabled ? "已开启" : "已关闭")")
        }
        if let action = status.lastAction {
            print("最近动作：\(action)")
        }
        // WP3：校准动作活跃 → 校准行（相位词与面板 l10n 同源——CLI 输出恒中文，
        // 与既有限充管理中/最近动作等字面量同一惯例，不本地化）。
        if status.isCalibrationAction {
            let phaseWord: String
            switch status.calibrationPhase {
            case .chargeFull: phaseWord = "充满中"
            case .hold: phaseWord = "静置平衡中"
            case .discharge: phaseWord = "放电中"
            case nil: phaseWord = "未知"
            }
            print("校准：\(phaseWord)")
        }
        if let percent = status.lastPercent {
            print("最近电量：\(percent)%")
        }
        print("daemon 版本：\(status.version)")
    }

    /// LimitPolicyError 的人类可读描述（复用 60 地板校验的呈现层）。
    static func describePolicyError(_ error: LimitPolicyError) -> String {
        switch error {
        case .upperLimitBelowFloor(let minimum):
            return "上限不能低于 \(minimum)%（硬下限）"
        case .upperLimitAboveCeiling(let maximum):
            return "上限不能高于 \(maximum)%"
        case .hysteresisOutOfRange(let range):
            return "滞回幅度须在 \(range.lowerBound)...\(range.upperBound) 之间"
        }
    }
}

/// cellar set —— 设置限充上限（经 daemon 执行；CLI 与 XPC setLimits 双重 60 地板核验）。
struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "设置限充上限百分比（经 daemon 执行，需 root）"
    )

    /// 限充上限百分比（60...100）。
    @Argument var threshold: Int?
    /// 滞回幅度（1...20；恢复阈值 = 上限 - 滞回）。
    @Option(name: .customLong("hysteresis")) var hysteresis: Int = 2

    func run() throws {
        try DaemonCommandHelpers.requireRoot("set")
        guard let upper = threshold else {
            print("用法：cellar set <上限百分比> [--hysteresis <1...20>]")
            throw ExitCode(2)
        }
        // 复用 LimitPolicy 构造校验（60 地板第三层防线；daemon 侧 setLimits 再核验一次）。
        do {
            _ = try LimitPolicy(upperLimit: upper, hysteresis: hysteresis)
        } catch let error as LimitPolicyError {
            print("参数无效：\(DaemonCommandHelpers.describePolicyError(error))")
            throw ExitCode(1)
        }
        try DaemonCommandHelpers.runDaemonCall {
            try DaemonXPCClient().setLimits(upperLimit: upper, hysteresis: hysteresis)
        }
    }
}

/// cellar enable —— 恢复限充管理（经 daemon 执行）。
struct EnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "恢复限充管理（经 daemon 执行，需 root）"
    )

    func run() throws {
        try DaemonCommandHelpers.requireRoot("enable")
        try DaemonCommandHelpers.runDaemonCall {
            try DaemonXPCClient().enable()
        }
    }
}

/// cellar disable —— 停止限充并恢复默认充电（经 daemon 执行）。
struct DisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "停止限充并恢复默认充电（经 daemon 执行，需 root）"
    )

    func run() throws {
        try DaemonCommandHelpers.requireRoot("disable")
        try DaemonCommandHelpers.runDaemonCall {
            try DaemonXPCClient().disable()
        }
    }
}

/// cellar calibrate —— 电池校准（WP3 手动触发版：四相状态机由 daemon 执行）。
/// start 前置拒绝（mode/外接/能力/在轨动作）→ daemonError 原文；cancel 幂等。
struct CalibrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "电池校准（充满 → 静置平衡 → 放电至 10% → 恢复限充；经 daemon 执行，需 root）",
        subcommands: [CalibrateStartCommand.self, CalibrateCancelCommand.self]
    )
}

/// cellar calibrate start —— 开始校准。
struct CalibrateStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "开始自动校准（建议睡前插电启动，全程约 6–10 小时）"
    )

    func run() throws {
        try DaemonCommandHelpers.requireRoot("calibrate start")
        try DaemonCommandHelpers.runDaemonCall {
            try DaemonXPCClient().startCalibration()
        }
    }
}

/// cellar calibrate cancel —— 取消进行中的校准。
struct CalibrateCancelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "取消进行中的校准（幂等，无动作亦成功）"
    )

    func run() throws {
        try DaemonCommandHelpers.requireRoot("calibrate cancel")
        try DaemonCommandHelpers.runDaemonCall {
            try DaemonXPCClient().cancelCalibration()
        }
    }
}

/// cellar install —— 安装 LaunchDaemon（root；规格 §4）。
struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "安装充电管理守护进程（LaunchDaemon，需 root）"
    )

    func run() throws {
        try DaemonCommandHelpers.requireRoot("install")
        // 托管态守卫（第一条业务语句）：App 托管 daemon 注册在册时，后续 step 5 的
        // 无条件 bootout system/com.cellar.daemon 会杀掉 App 托管 job 制造脏态——前置拦截。
        try DaemonCommandHelpers.guardInstallNotAppManaged()
        try DaemonInstaller.install()
    }
}

/// cellar uninstall —— 卸载 LaunchDaemon（root；规格 §4）。
struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "卸载充电管理守护进程并恢复默认充电（需 root）"
    )

    func run() throws {
        try DaemonCommandHelpers.requireRoot("uninstall")
        // 托管态守卫（第一条业务语句）：BTM 注册只有属主 App 与系统设置两条撤销路——
        // 检测到托管态必须指引，不能直接 bootout（孤儿态出口）。
        try DaemonCommandHelpers.guardUninstallNotAppManaged()
        try DaemonInstaller.uninstall()
    }
}

/// 安装/卸载（规格 §4；本文件内聚——安装器蓝图 Tools/com.cellar.daemon.plist）。
enum DaemonInstaller {
    static let helperSource = ".build/release/cellar-daemon"   // 相对当前工作目录
    static let helperPath = "/Library/PrivilegedHelperTools/com.cellar.daemon"
    static let plistSource = "Tools/com.cellar.daemon.plist"   // 相对当前工作目录
    static let plistPath = "/Library/LaunchDaemons/com.cellar.daemon.plist"
    static let policyDirectory = "/Library/Application Support/Cellar"
    static let logDirectory = "/Library/Logs/Cellar"

    static func install() throws {
        // 1. 校验 daemon 产物（target 名即 cellar-daemon）。
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: helperSource), fileManager.isExecutableFile(atPath: helperSource) else {
            print("❌ 未找到编译产物 \(helperSource)（相对当前工作目录解析）")
            print("   请先运行 swift build -c release，再执行 cellar install")
            throw ExitCode(1)
        }

        // 2. 校验 /Library/PrivilegedHelperTools：root:wheel 且非组/其他可写（评审 A-5）。
        do {
            let attributes = try fileManager.attributesOfItem(atPath: "/Library/PrivilegedHelperTools")
            let ownerID = (attributes[FileAttributeKey.ownerAccountID] as? NSNumber)?.intValue ?? -1
            let groupID = (attributes[FileAttributeKey.groupOwnerAccountID] as? NSNumber)?.intValue ?? -1
            let permissions = (attributes[FileAttributeKey.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard ownerID == 0, groupID == 0, permissions & 0o022 == 0 else {
                print("❌ /Library/PrivilegedHelperTools 属主或权限不符合安全要求（须 root:wheel，且非组/其他可写）")
                throw ExitCode(1)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            print("❌ /Library/PrivilegedHelperTools 不存在")
            throw ExitCode(1)
        } catch {
            print("❌ 校验 /Library/PrivilegedHelperTools 失败：\(error)")
            throw ExitCode(1)
        }

        // 3. 复制 daemon（root:wheel / 0755）+ 落位自检（文件存在 + 可执行位）。
        do {
            if fileManager.fileExists(atPath: helperPath) {
                try fileManager.removeItem(atPath: helperPath)
            }
            try fileManager.copyItem(atPath: helperSource, toPath: helperPath)
            chown(helperPath, 0, 0)
            chmod(helperPath, 0o755)
            guard fileManager.fileExists(atPath: helperPath), fileManager.isExecutableFile(atPath: helperPath) else {
                print("❌ daemon 落位自检失败（文件缺失或不可执行）")
                throw ExitCode(1)
            }
        } catch {
            print("❌ 复制 daemon 失败：\(error)")
            throw ExitCode(1)
        }
        print("已安装 helper：\(helperPath)")

        // 4. 以模板为蓝本写 plist + 创建日志/策略目录（root:wheel 0755）。
        do {
            let template = try String(contentsOfFile: plistSource, encoding: .utf8)
            try fileManager.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: policyDirectory, withIntermediateDirectories: true)
            // 归一化 root:wheel 0755（createDirectory 组继承父目录 admin——曾导致
            // F-3 校验自否）。⚠️ 只对**既有 root 属主**目录归一化（R1 审查 P1-1）：
            // 父目录组可写时非 root 可预创建目录并植入 .policy.json.tmp symlink，
            // 无条件 chown 会把投毒目录洗白成合规态——uid≠0 的既有目录直接拒绝，
            // 由用户人工处置；新建目录（stat 不存在）与本进程 root 身份同主，安全。
            for directory in [logDirectory, policyDirectory] {
                var st = stat()
                if stat(directory, &st) == 0, st.st_uid != 0 {
                    print("❌ 数据目录已存在且非 root 属主（疑似预创建），拒绝安装：\(directory)——请人工核查后删除或改属主")
                    throw ExitCode(1)
                }
                chown(directory, 0, 0)
                chmod(directory, 0o755)
            }
            // 0.4.1 安全审计 F-3（纵深防御）：数据目录须 root 属主且无组/其他可写位
            // （对齐上方 PrivilegedHelperTools 的属主校验纪律），不合规即中止安装。
            for directory in [logDirectory, policyDirectory]
            where !verifyRootOwnedDirectory(path: directory) {
                print("❌ 数据目录属主/权限校验失败（须 root 属主且无组/其他可写位）：\(directory)")
                throw ExitCode(1)
            }
            try template.write(toFile: plistPath, atomically: true, encoding: .utf8)
            chown(plistPath, 0, 0)
            chmod(plistPath, 0o644)
        } catch {
            print("❌ 写入 LaunchDaemon plist 失败：\(error)")
            throw ExitCode(1)
        }
        print("已写入 plist：\(plistPath)")

        // 5. 先容忍清理旧实例，再 bootstrap（失败 → 中止并打印 launchctl 原始错误）。
        let cleanup = runLaunchctl(["bootout", "system/com.cellar.daemon"])
        if cleanup.status != 0 {
            print("launchctl bootout 提示（容忍，旧实例不存在）：\(cleanup.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "退出码 \(cleanup.status)" : cleanup.errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let bootstrap = runLaunchctl(["bootstrap", "system", plistPath])
        guard bootstrap.status == 0 else {
            print("❌ launchctl bootstrap 失败（原始输出）：")
            let raw = bootstrap.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            print(raw.isEmpty ? "（launchctl 无输出，退出码 \(bootstrap.status)）" : raw)
            throw ExitCode(1)
        }
        print("✅ launchctl bootstrap 成功")

        // 6. 校验：XPC getStatus 重试 5×1s + version 核对（评审 F-3）。
        var lastError = ""
        for attempt in 1...5 {
            do {
                let status = try DaemonXPCClient().getStatus()
                guard status.version == DaemonXPC.daemonVersion else {
                    print("❌ daemon 版本核对失败：期望 \(DaemonXPC.daemonVersion)，实际 \(status.version)（stale daemon？）")
                    throw ExitCode(1)
                }
                print("✅ daemon 已启动并通过版本核对")
                DaemonCommandHelpers.printStatus(status)
                return
            } catch DaemonClientError.timeout, DaemonClientError.connectionFailed {
                lastError = "第 \(attempt) 次重试未响应"
                Thread.sleep(forTimeInterval: 1)
            } catch DaemonClientError.daemonError(let message) {
                lastError = message
                break
            } catch {
                lastError = "\(error)"
                break
            }
        }
        print("❌ daemon 启动校验失败（5 次重试）：\(lastError)")
        print("   请检查 /Library/Logs/Cellar/daemon.log 与 launchctl print system/com.cellar.daemon")
        throw ExitCode(1)
    }

    static func uninstall() throws {
        let fileManager = FileManager.default

        // 1. bootout（job 未加载视为幂等，容忍失败）。
        let bootout = runLaunchctl(["bootout", "system/com.cellar.daemon"])
        if bootout.status != 0 {
            print("launchctl bootout 提示（容忍）：\(bootout.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "退出码 \(bootout.status)" : bootout.errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // 2. 验证 daemon 已停（评审 B-2/P1：XPC 仍可达 → 中止非零——
        //    防直写与存活 daemon 心跳打架）。bootout 到进程退出有退出时间窗，最多等 5 秒。
        for _ in 0..<5 {
            do {
                _ = try DaemonXPCClient().getStatus()
                Thread.sleep(forTimeInterval: 1)   // 仍可达：等待其退出
            } catch DaemonClientError.timeout, DaemonClientError.connectionFailed {
                break                                // 已不可达 ✓
            } catch {
                break                                // 非预期错误也按不可达处理（不再继续卸载的阻力）
            }
        }
        do {
            _ = try DaemonXPCClient().getStatus()
            print("❌ daemon 仍在运行（XPC 可达），中止卸载")
            print("   请先排查：launchctl print system/com.cellar.daemon")
            throw ExitCode(1)
        } catch DaemonClientError.timeout, DaemonClientError.connectionFailed {
            print("✅ daemon 已停止")
        } catch {
            // daemonError 等：一台已停的 daemon 不可能回包，此分支理论不可达；
            // 按可达中止，保持 B-2 约束严格。
            print("❌ daemon 校验异常：\(error)，中止卸载")
            throw ExitCode(1)
        }

        // 3. 恢复默认充电（daemon 已停，root 直写 CHTE=00000000）。
        do {
            let client = try SMCClient.makeDefault()
            let backend = try RuntimeProbe.probe(client: client)
            try backend.setChargingEnabled(true)
            let confirmed = try backend.chargingEnabled()
            guard confirmed else {
                print("❌ 恢复默认充电失败（回读仍为停充）")
                throw ExitCode(1)
            }
            print("✅ 已恢复默认充电（\(backend.name) 后端）")
        } catch BackendError.noBackendAvailable {
            print("未探测到控制后端，跳过恢复充电（本机无可控制键）")
        } catch {
            print("❌ 恢复默认充电失败：\(error)")
            throw ExitCode(1)
        }

        // 4. 删除文件（幂等，缺失容忍）。
        for path in [plistPath, helperPath] {
            do {
                if fileManager.fileExists(atPath: path) {
                    try fileManager.removeItem(atPath: path)
                }
            } catch {
                print("❌ 删除 \(path) 失败：\(error)")
                throw ExitCode(1)
            }
        }
        do {
            if fileManager.fileExists(atPath: policyDirectory) {
                try fileManager.removeItem(atPath: policyDirectory)
            }
        } catch {
            print("❌ 删除 \(policyDirectory) 失败：\(error)")
            throw ExitCode(1)
        }
        print("✅ 卸载完成")
    }

    // MARK: - launchctl（原始错误透传）

    /// 运行 launchctl 并返回退出码 + stdout（print 走此通道）+ stderr 原文
    /// （bootstrap/bootout 失败必须打印原始错误）。DaemonCommandHelpers.queryDaemonRoute 共用。
    static func runLaunchctl(_ arguments: [String]) -> (status: Int32, outputText: String, errorText: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return (-1, "", "launchctl 无法执行：\(error)")
        }
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: outputData, encoding: .utf8) ?? "",
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}