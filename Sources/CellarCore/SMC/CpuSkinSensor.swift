/// CPU 表面温度传感器（0.18 M2 T5 D-5b 共享化）：Ts 探测与 flt 读值的单一真相
/// ——daemon（DaemonCore+Fan.ensureCpuSkinProbeLocked / fanTickLocked）与 App 层
/// （CpuFanMonitor）共用同一实现，杜绝两处漂移（方案 R-4：双实例探测结果不一致
/// 的影响面收敛为各自独立判断，序列/值域门完全同源）。纯只读（方案 §3 红线 6：
/// App 层零写键）。
public struct CpuSkinSensor {
    /// 探测候选键序列（顺序试探；真机实测 Ts0C/D/E/P 有效且 dataType 为 "flt "
    /// 尾随空格——trim 后比对，照 probeFanFacts trim== 先例）。
    public static let candidateKeys = ["Ts0C", "Ts0D", "Ts0E", "Ts0P"]

    private init() {}

    /// 探测：顺序试探候选键，首个满足「keyInfo type **trim 后** == "flt" ∧
    /// size == 4 ∧ 读值 ∈ 10...90°C 合理域」的键名；全不命中 → nil。
    ///
    /// 传输/键域错误按「该键不命中」吞掉继续（try? 语义——探测结论本身即输出，
    /// nil/键名就是结论，非静默吞失败）；sticky 收口语义由调用方持有（daemon =
    /// FanRuntimeState.cpuSkinSupported，App 侧 = CpuFanMonitor 探测缓存）。
    public static func probe(connection: SMCClient) -> String? {
        for key in candidateKeys {
            guard let info = try? connection.keyInfo(key),
                  info.type.trimmingCharacters(in: .whitespaces) == "flt",
                  info.size == 4,
                  let valueC = read(connection: connection, key: key),
                  valueC.isFinite, valueC >= 10, valueC <= 90 else { continue }
            return key
        }
        return nil
    }

    /// 读值：flt LE 解码（FanSMC.decodeTemperatureC 同源——Ts 系键与转速键同一
    /// LE 打包定版），返回摄氏度。
    ///
    /// ⚠️ 单位约定（工单定）：**°C（Double）**——Ts flt 原始值即 °C，不做 ×100
    /// 厘度换算：daemon tick 阈值比较与 App 层显示均为 °C 口径（与
    /// BatterySnapshot.temperatureC 同单位），厘度徒增两端换算面。
    /// nil = 键缺席 / 传输故障 / 字节数 ≠4（非抛——观察面降级由 nil 语义承载，
    /// 不做格式猜测）。
    public static func read(connection: SMCClient, key: String) -> Double? {
        guard let bytes = try? connection.read(key),
              let valueC = FanSMC.decodeTemperatureC(bytes) else { return nil }
        return Double(valueC)
    }
}
