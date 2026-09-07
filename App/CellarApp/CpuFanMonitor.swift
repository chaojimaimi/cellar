import CellarCore
import Foundation
import os

/// App 侧 CPU 表面温度 + 双风扇实时转速采样器（0.18 M2 T5 D-5a）。
///
/// 宿主形态照 PowerSourceMonitor（@MainActor ObservableObject、组合根持有）；
/// 采样循环照 StatusController.telemetryTask 先例（while + Task.sleep 门控循环）。
/// 30s 粒度（温度/转速慢变量，与 1s 遥测快变量并行独立），**panelVisible 门控**
/// ——仅面板消费，主窗可见不采样不空转；门控经 StatusController.setPanelVisible
/// 转发驱动（面板表面私有态，转发点唯一）。
///
/// 每跳 SMC 读经 Task.detached 包裹（IOConnectCallStructMethod 同步内核调用，
/// sampleBatteryOnce 先例——主线程永不阻塞）；SMCClient 实例单例复用（R-3：
/// IOServiceOpen 每跳新建有泄漏与开销），App 进程非 root 可读（doctor 先例）。
///
/// SMC 只读纪律（方案 §3 红线 6）：仅读 Ts 探测键（CpuSkinSensor 单一实现，与
/// daemon 同源）+ F0Ac/F1Ac 转速键；零写键。
@MainActor
final class CpuFanMonitor: ObservableObject {
    /// CPU 表面温度 °C（nil = 未采样/探测未命中——CPU 格隐藏，D-5e）。
    @Published private(set) var cpuSkinTempC: Double?
    /// 风扇转速 rpm 序列（[F0Ac] 或 [F0Ac, F1Ac]；nil = F0Ac 缺席/未采样——风扇
    /// 格整体隐藏；单元素 = 单风扇机型，F1Ac 缺席按单值格呈现，R-6）。
    @Published private(set) var fanRPMs: [Double]?

    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "cpu-fan")

    /// 采样粒度（秒）：慢变量 30s 档——1s 遥测档对本数据是纯浪费。
    private static let sampleInterval: TimeInterval = 30

    /// panelVisible 门控态（setPanelVisible 换档；转发源 = StatusController）。
    private var panelVisible = false
    /// 采样循环任务（nil = 停止）。
    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）需取消；属性仅在主 actor 方法或
    /// deinit 中访问（Task.cancel() 本身线程安全，StatusController 同款注记）。
    private nonisolated(unsafe) var sampleTask: Task<Void, Never>?
    /// SMC 客户端（单例复用，懒建于首次可见；nil = 建立失败——不置循环，面板
    /// 重开再试，照 daemon smcClient 缺席窗口先例）。
    /// ⚠️ nonisolated(unsafe)：deinit（非隔离）释放；仅主 actor 方法/deinit 访问。
    private nonisolated(unsafe) var smcClient: SMCClient?
    /// Ts 探测 sticky 缓存（App 侧首次探测即收口——命中记键、未中置 resolved，
    /// 照 daemon FanRuntimeState.cpuSkinSupported sticky 先例，防无 Ts 键机型每
    /// 跳空探 8 次传输调用）。
    private var cpuSkinKey: String?
    private var cpuSkinProbeResolved = false

    deinit {
        // 循环取消 + 连接释放（IOKitSMCTransport.deinit 关连接——SMCClient/Transport
        // 既有 deinit 形态，R-3 无泄漏）。
        sampleTask?.cancel()
        smcClient = nil
    }

    // MARK: - 门控（StatusController.setPanelVisible 转发入口）

    /// 面板可见性换档：可见 → 建客户端（首次）+ 立即补一跳 + 起 30s 循环；
    /// 不可见 → 停循环（@Published 旧值保留——重开面板首跳前显示上轮读数，
    /// 半分钟内的陈旧可接受，不闪空格）。
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        if visible {
            startSampling()
        } else {
            sampleTask?.cancel()
            sampleTask = nil
        }
    }

    /// 启动采样（幂等：循环在途直接返回）。客户端建立失败不置循环——面板重开
    /// 再试（setPanelVisible(false→true) 重走本路径）。
    private func startSampling() {
        guard sampleTask == nil else { return }
        if smcClient == nil {
            smcClient = try? SMCClient.makeDefault()
            guard smcClient != nil else {
                Self.log.error("SMC 客户端建立失败：CPU/风扇格不采样（保持隐藏，面板重开重试）")
                return
            }
        }
        Task { await sampleOnce() }   // 翻档可见即补一跳（refreshCadence 先例）
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sampleInterval))
                guard let self, !Task.isCancelled else { return }
                await self.sampleOnce()
            }
        }
    }

    // MARK: - 单跳采样

    /// 单跳采样：Ts（sticky 探测键）+ F0Ac/F1Ac 三只读键一次后台读齐，回主
    /// actor 写 @Published。读取失败 → 对应值 nil（格级隐藏，D-5e；不告警——
    /// 观察面降级非故障）。
    private func sampleOnce() async {
        guard let client = smcClient else { return }
        let probeNeeded = !cpuSkinProbeResolved
        let knownKey = cpuSkinKey
        let reading = await Task.detached { () -> (temp: Double?, rpms: [Double]?, key: String?, resolved: Bool) in
            // IOConnect 同步内核调用——探测与读值全部后台执行，主线程零阻塞
            //（code-review P2-1：probe 8 次内核往返同样不得落主线程；探测纯只读
            // 无副作用，sticky 态回主 actor 后再写）。
            var key = knownKey
            var resolved = !probeNeeded
            if probeNeeded {
                key = CpuSkinSensor.probe(connection: client)
                resolved = true
                if key == nil {
                    Self.log.info("CPU 表面温度键探测未命中（Ts0C/D/E/P 全不满足）——CPU 格隐藏")
                }
            }
            var rpms: [Double] = []
            if let f0 = Self.readRPM(key: "F0Ac", client: client) { rpms.append(f0) }
            if let f1 = Self.readRPM(key: "F1Ac", client: client) { rpms.append(f1) }
            let temp = key.flatMap { CpuSkinSensor.read(connection: client, key: $0) }
            return (temp, rpms.isEmpty ? nil : rpms, key, resolved)
        }.value
        guard !Task.isCancelled else { return }
        cpuSkinTempC = reading.temp
        fanRPMs = reading.rpms
        cpuSkinKey = reading.key
        cpuSkinProbeResolved = reading.resolved
    }

    /// flt LE 转速读（FanSMC.decodeRPM 先例；键缺席/传输故障/尺寸不符 → nil）。
    /// 非隔离静态（仅触碰 Sendable 参数，Task.detached 内调用）。
    private nonisolated static func readRPM(key: String, client: SMCClient) -> Double? {
        guard let bytes = try? client.read(key), let rpm = FanSMC.decodeRPM(bytes) else { return nil }
        return Double(rpm)
    }
}
