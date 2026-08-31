import ArgumentParser
import CellarCore
import Foundation

/// cellar status —— 状态一览（只读，不写任何 SMC 键）。
///
/// 数据来源：RuntimeProbe.probe（后端与控制键）+ BatteryMonitor.snapshot
/// （电量/充放状态/电压等，AppleSmartBattery 只读，无需 root）。
/// 读取失败：打印对应错误并以退出码 1 退出，绝不静默。
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "状态一览（只读）：后端、电量、充放状态、控制键状态、电压等"
    )

    func run() throws {
        let identity = RuntimeProbe.isRunningAsRoot
            ? "root（具备写入能力）"
            : "非 root（读取可用；写入需 root，限充控制经 daemon）"
        print("运行身份：\(identity)")
        try printBackendSection()
        try printBatterySection()
    }

    // MARK: - 后端与控制键（SMC 路径）

    /// 读失败（连接/探测/控制键）→ 打印对应错误并抛 ExitCode(1)。
    private func printBackendSection() throws {
        let client: SMCClient
        do {
            client = try SMCClient.makeDefault()
        } catch {
            print("❌ AppleSMC 连接失败：\(error)")
            throw ExitCode(1)
        }

        // 探测顺序 CHTE → CH0B（RuntimeProbe）；两者皆无 = 只读模式（确定性结论，非失败）。
        let backend: any ChargingBackend
        do {
            backend = try RuntimeProbe.probe(client: client)
        } catch BackendError.noBackendAvailable {
            print("后端：不可用（只读模式：未探测到控制后端，监测仍可用）")
            return
        } catch {
            print("❌ 后端探测失败：\(error)")
            throw ExitCode(1)
        }
        print("后端：\(backend.name)（控制键：\(backend.keyNames.joined(separator: ", "))）")

        do {
            let enabled = try backend.chargingEnabled()
            print("充电控制：\(enabled ? "充电使能" : "已停充")")
        } catch {
            print("❌ 控制键状态读取失败：\(error)")
            throw ExitCode(1)
        }
    }

    // MARK: - 电池读数（IOKit 路径）

    private func printBatterySection() throws {
        let snapshot: BatterySnapshot
        do {
            snapshot = try BatteryMonitor.makeDefault().snapshot()
        } catch {
            print("❌ 电池读数失败：\(error)")
            throw ExitCode(1)
        }

        let chargingState = snapshot.isCharging ? "充电中" : "未充电"
        let external = snapshot.externalConnected ? "外部电源已连接" : "外部电源未连接"
        print("电量：\(snapshot.percent)%（\(chargingState) · \(external)）")
        print("电压：\(snapshot.voltageMV) mV · 电流：\(snapshot.amperageMA) mA")
        print("温度：\(String(format: "%.2f", snapshot.temperatureC)) °C · 循环次数：\(snapshot.cycleCount) · 设计容量：\(snapshot.designCapacityMAh) mAh")
        if let max = snapshot.maxCapacityPercent {
            print("当前最大容量：\(max)%")
        }
        if let adapter = snapshot.adapter {
            var parts: [String] = []
            if let watts = adapter.watts { parts.append("\(watts) W") }
            if let voltage = adapter.voltageMV { parts.append("\(voltage) mV") }
            if let current = adapter.currentMA { parts.append("\(current) mA") }
            if let name = adapter.name { parts.append(name) }
            print("适配器：\(parts.isEmpty ? "（空）" : parts.joined(separator: " · "))")
        }
        print("时间戳：\(snapshot.timestamp)")
    }
}