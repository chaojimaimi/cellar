import ArgumentParser
import CellarCore
import Foundation

/// cellar status —— 状态一览：daemon 段（XPC getStatus，任意身份可调）+ 本地只读读数段。
///
/// daemon 段：XPC 成功 → 模式/策略/最近动作；XPC 失败（未安装/未运行）→ 打印固定指引，
/// 不阻断本地只读信息（降级视图）。退出码：本地读数全部成功 0；任一本地产失败 1
/// （评审 P1-8：不静默——daemon 缺失不影响本地诊断可见性，本地故障必须显式非零）。
/// Phase 5 v1.6（UD-9）：`--json` 机器可读输出（键名对齐 DaemonStatus 字段名 +
/// 本地读数段；旧 daemon 缺席的可选字段按存在与否输出——合成 Codable encodeIfPresent；
/// 退出码约定不变）。
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "状态一览：daemon 段 + 后端、电量、充放状态、控制键状态、电压等"
    )

    /// UD-9：--json 结构化输出（脚本化第一步，方案 §3.4）。
    @Flag(name: .long, help: "以 JSON 输出（脚本化；daemon/route/local 三段，键名对齐 DaemonStatus）")
    var json = false

    func run() throws {
        if json {
            try runJson()
            return
        }
        let identity = RuntimeProbe.isRunningAsRoot
            ? "root（具备写入能力）"
            : "非 root（读取可用；写入需 root，限充控制经 daemon）"
        print("运行身份：\(identity)")
        printDaemonSection()

        // 本地只读段：任一失败 → 退出码 1（daemon 缺失时本地成功仍 0——降级视图）。
        var localFailed = false
        do {
            try printBackendSection()
        } catch {
            localFailed = true
        }
        do {
            try printBatterySection()
        } catch {
            localFailed = true
        }
        if localFailed {
            throw ExitCode(1)
        }
    }

    // MARK: - --json（UD-9）

    /// 结构化输出（单行紧凑 JSON + sortedKeys，jq 等脚本工具直读）：
    /// `{"daemon": {…DaemonStatus 全字段…}, "route": "appManaged"|"manual"|"unknown",
    ///   "local": {…电池读数…}}；route 键仅在 daemon 可达时存在（缺席 = 不可达）。`。
    /// - daemon 段 = DaemonStatus 直接 encode（键名对齐零漂移；可选字段 nil 省略
    ///   ——旧 daemon 的 scheduleJson/scheduleActiveId/fan/calSched 三键/therm
    ///   两键按存在与否输出；scheduleJson 为嵌套 JSON 串，脚本侧二次解析即得配置）；
    /// - daemon 不可达 → `"daemon": null` + `"error"` 原文（本地段照常输出——
    ///   与人读路径同口径的降级视图，不阻断本地诊断）；
    /// - 本地读数失败 → `"local": null` + 退出码 1（评审 P1-8 不静默同口径）；
    /// - SMC 后端/控制键段不进 JSON（v1.6 脚本面收敛于 daemon + 电池读数——
    ///   充放状态经 local.charging/external 表达，方案 §3.4）。
    private func runJson() throws {
        var root: [String: Any] = [:]
        do {
            let status = try DaemonXPCClient().getStatus()
            // secondsSince1970：脚本友好的 epoch 秒（timestamp 一致口径）。
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(status)
            root["daemon"] = try JSONSerialization.jsonObject(with: data)
            root["route"] = daemonRouteName(DaemonCommandHelpers.queryDaemonRoute())
        } catch DaemonClientError.timeout, DaemonClientError.connectionFailed {
            root["daemon"] = NSNull()
            root["error"] = DaemonCommandHelpers.daemonUnavailableMessage
        } catch DaemonClientError.daemonError(let message) {
            root["daemon"] = NSNull()
            root["error"] = message
        }

        var localFailed = false
        do {
            root["local"] = try localReadings()
        } catch {
            localFailed = true
            root["local"] = NSNull()
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "{}")
        if localFailed {
            throw ExitCode(1)
        }
    }

    /// 路由词（DaemonRoute → 稳定 camelCase 串 appManaged/manual/unknown——脚本分支依据，不本地化）。
    private func daemonRouteName(_ route: DaemonRoute) -> String {
        switch route {
        case .appManaged: return "appManaged"
        case .manual: return "manual"
        case .unknown: return "unknown"
        }
    }

    /// 本地电池读数段（IOKit；键名对齐 BatterySnapshot 字段语义——percent/
    /// charging/external/temperature/voltage/amperage/cycle/designCapacity 等的可
    /// 选段按存在与否输出）。
    private func localReadings() throws -> [String: Any] {
        let snapshot = try BatteryMonitor.makeDefault().snapshot()
        var local: [String: Any] = [
            "percent": snapshot.percent,
            "charging": snapshot.isCharging,
            "external": snapshot.externalConnected,
            "temperature": snapshot.temperatureC,
            "voltage": snapshot.voltageMV,
            "amperage": snapshot.amperageMA,
            "cycle": snapshot.cycleCount,
            "designCapacity": snapshot.designCapacityMAh,
            "timestamp": Int(snapshot.timestamp.timeIntervalSince1970),
        ]
        if let max = snapshot.maxCapacityPercent {
            local["maxCapacity"] = max
        }
        // 健康度（WP2' 口径：Nominal/Design 同源；缺席/异常源 → 字段省略）。
        if let health = batteryHealthPercent(
            nominal: snapshot.nominalChargeCapacityMAh, design: snapshot.designCapacityMAh
        ) {
            local["health"] = health
        }
        if let adapter = snapshot.adapter {
            var adapterObject: [String: Any] = [:]
            if let watts = adapter.watts { adapterObject["watts"] = watts }
            if let voltage = adapter.voltageMV { adapterObject["voltage"] = voltage }
            if let current = adapter.currentMA { adapterObject["current"] = current }
            if let name = adapter.name { adapterObject["name"] = name }
            local["adapter"] = adapterObject
        }
        return local
    }

    // MARK: - daemon 段（XPC，尽力而为）

    /// XPC 失败不抛错：打印固定指引（spec §5 失败矩阵与 set/enable/disable 同文案）。
    /// WP2 双路由化（§2.7）：XPC 可达 → 附加路由行；不可达 → 按手工 plist 是否存在分支
    /// （已安装未运行 / 未安装 + 双路由安装指引）。
    private func printDaemonSection() {
        do {
            let status = try DaemonXPCClient().getStatus()
            DaemonCommandHelpers.printStatus(status)
            printFanLine(status)
            printRouteLine()
        } catch DaemonClientError.timeout, DaemonClientError.connectionFailed {
            if FileManager.default.fileExists(atPath: DaemonInstaller.plistPath) {
                print("daemon：已安装未运行（手工路线）")
                print("提示：请查看 /Library/Logs/Cellar/daemon.log 与 launchctl print system/com.cellar.daemon")
            } else {
                print("daemon：未安装")
                print("安装指引：sudo cellar install（手工路线），或从 Cellar 菜单栏面板安装（托管）")
            }
        } catch DaemonClientError.daemonError(let message) {
            print("daemon 状态查询失败：\(message)")
        } catch {
            print("daemon 状态查询失败：\(error)")
        }
    }

    /// 路由行（§2.7）：XPC 可达时附加「App 托管」/「手工路线」（daemonRoute 纯函数判定）。
    private func printRouteLine() {
        switch DaemonCommandHelpers.queryDaemonRoute() {
        case .appManaged:
            print("安装路线：App 托管（请在 Cellar 面板中管理）")
        case .manual:
            print("安装路线：手工路线（sudo cellar uninstall 可卸载）")
        case .unknown:
            print("安装路线：未知（服务未加载或 launchctl 输出无法识别）")
        }
    }

    // MARK: - Phase 5 v1.1 风扇行（方案 §8 CLI 段）

    /// 风扇状态行（九态词 + 策略 + 阈值；fan==nil = 旧 daemon 未上报 —— 升级提示）。
    private func printFanLine(_ status: DaemonStatus) {
        guard let fan = status.fan else {
            print("风扇：旧版守护进程未上报（升级后可查看）")
            return
        }
        var parts = [fanStateWord(fan.state, fan: fan)]
        parts.append("策略：" + fanStrategyName(fan.strategy))
        parts.append(String(format: "阈值 %.1f°C", Double(fan.thresholdCentiC) / 100))
        print("风扇：" + parts.joined(separator: " · "))
    }

    private func fanStateWord(_ state: FanStateWord, fan: FanStatus) -> String {
        switch state {
        case .off: return "已关闭"
        case .probing: return "探测中"
        case .automatic: return "自动"
        case .boost:
            let rpm = fan.targetRPM.map { "\(Int($0.rounded()))" } ?? "?"
            return "加速中 →\(rpm)rpm"
        case .hold: return "保持"
        case .degraded: return "已暂停介入（采样异常）"
        case .unsupported: return "本机不支持"
        case .strategyUnsupported: return "暂不支持该策略"
        case .conflict: return "检测到其他风扇控制写入者"
        }
    }

    private func fanStrategyName(_ strategy: FanStrategy) -> String {
        switch strategy {
        case .constantSpeed: return "恒速降温"
        case .minRaise: return "抬升下限"
        case .twoStage: return "两级分段"
        case .emergency: return "全速应急"
        }
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
        print("时间戳：\(formatTimestamp(snapshot.timestamp))")
    }
}
