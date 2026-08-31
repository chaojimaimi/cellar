import ArgumentParser
import CellarCore

/// cellar doctor —— 七项只读诊断（不写任何 SMC 键）。
///
/// 无 sudo 亦可给出可信结论（SMC-NOTES §1.1：LE 字节序定版后读路径普通用户稳定）；
/// 退出码：0 健康 / 1 警告 / 2 失败。
/// 报告生成（DoctorReportGenerator）为 CellarCore 纯函数，本命令只做
/// 输入组装与渲染（“报告即数据”）：每行 `[PASS]/[INFO]/[WARN]/[FAIL] 检查名：detail`。
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "诊断报告：七项只读检查（退出码 0 健康 / 1 警告 / 2 失败）"
    )

    func run() throws {
        let report = DoctorReportGenerator.generate(collectInputs())
        for check in report.checks {
            print("[\(check.status.rawValue.uppercased())] \(check.name)：\(check.detail)")
        }
        throw ExitCode(Int32(report.exitCode))
    }

    /// 组装 DoctorInputs（规格 §0.1）：每路读取失败都结构化落入对应字段，绝不静默。
    private func collectInputs() -> DoctorInputs {
        // 检查 2/3/4：SMC 服务连接 → 后端探测 → 控制键状态。
        var smcConnected = false
        var probe: ProbeOutcome = .serviceUnavailable
        var chargingEnabled: Bool?
        var chargingError: SMCError?

        do {
            let client = try SMCClient.makeDefault()
            smcConnected = true

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
            } catch BackendError.noBackendAvailable {
                probe = .noneAvailable
            } catch let error as SMCError {
                probe = mapProbeError(error)
            }
        } catch let error as SMCError {
            probe = mapProbeError(error)
        } catch {
            // makeDefault 现实只抛 SMCError（serviceNotFound/openFailed）；兜底保持 serviceUnavailable。
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

        // 检查 6：共存检测（四目录扫描，只读）。
        let conflict = ConflictScan.scan()

        return DoctorInputs(
            isRoot: RuntimeProbe.isRunningAsRoot,
            smcConnected: smcConnected,
            probe: probe,
            chargingEnabled: chargingEnabled,
            chargingError: chargingError,
            snapshot: snapshot,
            snapshotError: snapshotError,
            conflict: conflict
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
}