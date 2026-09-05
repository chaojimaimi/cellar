import ArgumentParser
import CellarCore
import Foundation

/// cellar doctor —— 十二项只读诊断（不写任何 SMC 键）。
///
/// 无 sudo 亦可给出可信结论（LE 字节序定版后读路径普通用户稳定，2026-08-31 实测）；
/// 退出码：0 健康 / 1 警告 / 2 失败。
/// 报告生成（DoctorReportGenerator）为 CellarCore 纯函数，本命令只做
/// 输入组装与渲染（"报告即数据"）：每行 `[PASS]/[INFO]/[WARN]/[FAIL] 检查名：detail`。
/// `--devices`：只输出设备信息单行（key=value，docs/DEVICES.md 字段表；不渲染报告）。
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "诊断报告：十二项只读检查（退出码 0 健康 / 1 警告 / 2 失败）"
    )

    /// 设备信息单行（--devices；字段白名单与字段序见 CellarCore DeviceInfo）。
    @Flag(name: .customLong("devices"), help: "输出设备信息单行（key=value，机器可解析）")
    var devices = false

    func run() throws {
        if devices {
            print(DeviceInfo.line(collectDeviceRow()))
            return
        }
        let report = DoctorReportGenerator.generate(collectInputs())
        for check in report.checks {
            print("[\(check.status.rawValue.uppercased())] \(check.name)：\(check.detail)")
        }
        throw ExitCode(Int32(report.exitCode))
    }

    /// 组装 DoctorInputs（规格 §0.1）：每路读取失败都结构化落入对应字段，绝不静默。
    private func collectInputs() -> DoctorInputs {
        // 检查 2/3/4/11 + 键矩阵：SMC 服务连接 → 后端探测 → 控制键状态。
        var smcConnected = false
        var probe: ProbeOutcome = .serviceUnavailable
        var chargingEnabled: Bool?
        var chargingError: SMCError?
        var keyPresence: KeyPresence?
        var dischargeProbe: DischargeProbe?
        // Phase 5 v1.1：检查 12 风扇键只读探测（F0Tg/F0Md/F0Ac/F0Mn/F0Mx 在位 +
        // F0Md/F0Tg 现态；只读——不写任何键）。
        var fanKeysPresent: [String] = []
        var fanMdValue: UInt8?
        var fanTgRPM: Float?

        do {
            let client = try SMCClient.makeDefault()
            smcConnected = true

            // 检查 3 键世代标注矩阵（传输错误 → 对应键置 nil——标注跳过，不误报）。
            keyPresence = KeyPresence(
                chte: try? client.keyExists("CHTE"),
                chie: try? client.keyExists("CHIE"),
                ch0b: try? client.keyExists("CH0B")
            )

            // 检查 12：风扇键在位/现态（keyExists 失败按缺席；F0Md/F0Tg 读取失败 → nil）。
            for key in ["F0Tg", "F0Md", "F0Ac", "F0Mn", "F0Mx"] {
                if (try? client.keyExists(key)) == true {
                    fanKeysPresent.append(key)
                }
            }
            fanMdValue = (try? client.read("F0Md"))?.first
            fanTgRPM = (try? client.read("F0Tg")).flatMap(FanSMC.decodeRPM)

            do {
                let backend = try RuntimeProbe.probe(client: client)
                probe = .detected(name: backend.name, keyNames: backend.keyNames)
                do {
                    chargingEnabled = try backend.chargingEnabled()
                } catch let error as SMCError {
                    chargingError = error
                } catch {
                    // BackendError（未知状态/双键分裂等）不适配 SMCError? 字段：
                    // 检查 4 按"状态未知"失败呈现（generate 兜底），不伪造错误类型。
                }
                // 检查 11：放电能力（supportsDischarge + CHIE 现值回读；读取失败 → info）。
                let supported = RuntimeProbe.supportsDischarge(backend: backend, client: client)
                var chieState: Bool?
                var chieReadFailed = false
                if supported {
                    do {
                        chieState = try backend.adapterEnabled()
                    } catch {
                        // 传输/键不可见（非 root 键可见性不稳定）：按 info 降级，不误报。
                        chieReadFailed = true
                    }
                }
                dischargeProbe = DischargeProbe(
                    supported: supported, chieState: chieState, readFailed: chieReadFailed
                )
            } catch BackendError.noBackendAvailable {
                probe = .noneAvailable
                dischargeProbe = DischargeProbe(supported: false, chieState: nil, readFailed: false)
            } catch let error as SMCError {
                probe = mapProbeError(error)
                dischargeProbe = DischargeProbe(supported: false, chieState: nil, readFailed: false)
            }
        } catch let error as SMCError {
            probe = mapProbeError(error)
            dischargeProbe = DischargeProbe(supported: false, chieState: nil, readFailed: false)
        } catch {
            // makeDefault 现实只抛 SMCError（serviceNotFound/openFailed）；兜底保持 serviceUnavailable。
            dischargeProbe = DischargeProbe(supported: false, chieState: nil, readFailed: false)
        }

        // 检查 5：电池读数（AppleSmartBattery 只读，无需 root）。
        var snapshot: BatterySnapshot?
        var snapshotError: BatteryMonitorError?
        do {
            snapshot = try BatteryMonitor.makeDefault().snapshot()
        } catch let error as BatteryMonitorError {
            snapshotError = error
        } catch {
            // 解析层只抛 BatteryMonitorError（现实不可达）。
        }

        // 检查 6：共存检测——四目录扫描 + 进程层扫描（层 1 knownIdentifiers；
        // self（cellar / cellar-daemon）排除；命中带「进程名[PID]」）。
        let conflict = ConflictScan.scan()
        let processHits = ConflictScan.scanProcesses(exclude: ["cellar", "cellar-daemon"]).exact

        // 检查 8：daemon 状态（XPC getStatus，任意身份可调；失败 = 未安装/未运行）。
        // daemonProbeAttempted 恒 true：已探测但未运行才渲染 INFO 行（"cellar install 可启用限充"）。
        var daemonStatus: DaemonStatus?
        do {
            daemonStatus = try DaemonXPCClient().getStatus()
        } catch {
            daemonStatus = nil
        }

        // 检查 13：热暂停配置现态（daemon 回读 therm 两键；未运行或旧 daemon 缺键
        // → nil → INFO 行渲染，Phase 5 v1.5）。
        let thermalStatus: ThermalStatus?
        if let thermPause = daemonStatus?.thermPauseCentiC,
           let thermHysteresis = daemonStatus?.thermHysteresisCentiC {
            thermalStatus = ThermalStatus(pauseCentiC: thermPause, hysteresisCentiC: thermHysteresis)
        } else {
            thermalStatus = nil
        }

        // 检查 9：BTM 注册态（launchctl print 子进程；非 root 亦可读基本字段——
        // 2026-09-02 spike 实证；解析纯函数在 CellarCore，评审 P2-1 分层）。
        let btmOutput = runProcessCapture("/bin/launchctl", ["print", "system/com.cellar.daemon"]).output
        let btmState = BTMState.parseLaunchctlPrint(btmOutput)

        // 检查 10：版本矩阵（CLI 编译期常量 + daemon XPC 版本 + App Info.plist）。
        let versionMatrix = VersionMatrix(
            cliVersion: DaemonXPC.daemonVersion,
            daemonVersion: daemonStatus?.version,
            appVersion: Self.readAppVersion()
        )

        return DoctorInputs(
            isRoot: RuntimeProbe.isRunningAsRoot,
            smcConnected: smcConnected,
            probe: probe,
            chargingEnabled: chargingEnabled,
            chargingError: chargingError,
            snapshot: snapshot,
            snapshotError: snapshotError,
            conflict: conflict,
            daemonStatus: daemonStatus,
            daemonProbeAttempted: true,
            keyPresence: keyPresence,
            processHits: processHits,
            btmState: btmState,
            btmProbeAttempted: true,
            versionMatrix: versionMatrix,
            dischargeProbe: dischargeProbe,
            fanProbe: FanDoctorProbe(
                keysPresent: fanKeysPresent,
                mdValue: fanMdValue,
                tgRPM: fanTgRPM,
                config: daemonStatus?.fan
            ),
            thermal: thermalStatus,
            thermalProbeAttempted: true
        )
    }

    /// RuntimeProbe.probe 失败形态映射（规格 §0.1）：
    /// serviceNotFound/openFailed → serviceUnavailable；
    /// 其余 SMCError → failed（原文保留）。
    private func mapProbeError(_ error: SMCError) -> ProbeOutcome {
        switch error {
        case .serviceNotFound, .openFailed:
            return .serviceUnavailable
        default:
            return .failed(error)
        }
    }

    /// App 版本（/Applications/Cellar.app 的 CFBundleShortVersionString；缺席 → nil，
    /// 检查 10 按 info 呈现）。只读 plist，绝不触发任何安装/调整。
    private static func readAppVersion() -> String? {
        guard let dictionary = NSDictionary(contentsOfFile: "/Applications/Cellar.app/Contents/Info.plist") else {
            return nil
        }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    // MARK: - --devices 设备行采集

    /// 设备行采集（字段白名单固定——隐私护栏：不读/不输出任何白名单外字段，
    /// 见 CellarCore DeviceInfo 文件头注记）。
    private func collectDeviceRow() -> DeviceRow {
        // SMC 后端 + 键矩阵 + CHTE 停充回读（limit.verify 判据入参）。
        var backendName: String?
        var keyCHTE: Bool?
        var keyCHIE: Bool?
        var keyCH0B: Bool?
        var dischargeSupported: Bool?
        var chargingEnabled: Bool?
        do {
            let client = try SMCClient.makeDefault()
            keyCHTE = try? client.keyExists("CHTE")
            keyCHIE = try? client.keyExists("CHIE")
            keyCH0B = try? client.keyExists("CH0B")
            if let backend = try? RuntimeProbe.probe(client: client) {
                backendName = backend.name
                dischargeSupported = RuntimeProbe.supportsDischarge(backend: backend, client: client)
                chargingEnabled = try? backend.chargingEnabled()
            }
        } catch {
            // SMC 不可用：全部保持 nil（渲染 unknown），不误报。
        }

        var daemonStatus: DaemonStatus?
        do {
            daemonStatus = try DaemonXPCClient().getStatus()
        } catch {
            daemonStatus = nil
        }

        let swVersOutput = runProcessCapture("/usr/bin/sw_vers", []).output
        let (product, build) = DeviceInfo.swVersVersions(from: swVersOutput)
        var macos: String?
        if let product, let build {
            macos = "\(product) (\(build))"
        } else {
            macos = product
        }

        return DeviceRow(
            model: DeviceInfo.sysctlString("hw.model"),
            chip: DeviceInfo.sysctlString("machdep.cpu.brand_string"),
            macos: macos,
            firmware: DeviceInfo.firmwareRomVersion(),
            backend: backendName,
            keyCHTE: keyCHTE,
            keyCHIE: keyCHIE,
            keyCH0B: keyCH0B,
            discharge: dischargeSupported,
            limitVerify: DeviceInfo.limitVerify(status: daemonStatus, chargingEnabled: chargingEnabled),
            dischargeVerify: DeviceInfo.dischargeVerify(status: daemonStatus)
        )
    }

    // MARK: - 子进程工具

    /// 子进程 stdout+stderr 合并捕获（launchctl / sw_vers；退出码一并返回）。
    /// stderr 并入输出：未注册服务的报错行（Could not find service...）走 stderr，
    /// 是检查 9 的判定输入，不能丢弃。
    private func runProcessCapture(_ executablePath: String, _ arguments: [String]) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return ("", -1)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }
}