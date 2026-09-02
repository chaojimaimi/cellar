#if canImport(Darwin)
import Darwin
#endif
#if canImport(IOKit)
import IOKit
#endif
import Foundation

/// WP5 §3：设备信息行（docs/DEVICES.md 字段表；`cellar doctor --devices` 数据源）。
///
/// **隐私护栏**：字段为固定白名单（本文件 DeviceRow 全字段）；固件只读 IODeviceTree
/// 固定键 `rom-version` 单键属性——禁止整 IOPlatformExpertDevice 字典 dump（同字典
/// 含设备个人标识字段，红线）。新增字段必须同步 docs/DEVICES.md 字段表。

/// 设备信息行字段（缺省 nil = 采集失败，渲染 unknown；字段序由 DeviceInfo.line 固定）。
public struct DeviceRow: Equatable, Sendable {
    /// 机型标识（sysctl hw.model）。
    public var model: String?
    /// 芯片型号（machdep.cpu.brand_string）。
    public var chip: String?
    /// macOS 版本（productVersion + build）。
    public var macos: String?
    /// 固件（IODeviceTree 固定键 rom-version）。
    public var firmware: String?
    /// 控制后端名（tahoe / legacy）。
    public var backend: String?
    /// CHTE 键在位。
    public var keyCHTE: Bool?
    /// CHIE 键在位。
    public var keyCHIE: Bool?
    /// CH0B 键在位。
    public var keyCH0B: Bool?
    /// discharge 能力（supportsDischarge）。
    public var discharge: Bool?
    /// 限充执法一致性（pass / unknown；判据见 DeviceInfo.limitVerify）。
    public var limitVerify: String?
    /// 放电完成路径（pass / unknown；判据见 DeviceInfo.dischargeVerify）。
    public var dischargeVerify: String?

    public init(
        model: String? = nil,
        chip: String? = nil,
        macos: String? = nil,
        firmware: String? = nil,
        backend: String? = nil,
        keyCHTE: Bool? = nil,
        keyCHIE: Bool? = nil,
        keyCH0B: Bool? = nil,
        discharge: Bool? = nil,
        limitVerify: String? = nil,
        dischargeVerify: String? = nil
    ) {
        self.model = model
        self.chip = chip
        self.macos = macos
        self.firmware = firmware
        self.backend = backend
        self.keyCHTE = keyCHTE
        self.keyCHIE = keyCHIE
        self.keyCH0B = keyCH0B
        self.discharge = discharge
        self.limitVerify = limitVerify
        self.dischargeVerify = dischargeVerify
    }
}

/// 设备行渲染与采集纯函数。
public enum DeviceInfo {
    /// 单行 key=value（字段序固定 11 项，与 docs/DEVICES.md 字段表一致；
    /// 缺值=unknown）。**值内空格以 "_" 占位**：保「空格分隔令牌」机器可解析
    /// 契约（chip 如 "Apple M4 Pro" → "Apple_M4_Pro"）。
    public static func line(_ row: DeviceRow) -> String {
        let stringValue: (String?) -> String = { $0 ?? "unknown" }
        let boolValue: (Bool?) -> String = { $0.map { $0 ? "yes" : "no" } ?? "unknown" }
        func token(_ key: String, _ value: String) -> String {
            "\(key)=\(value.replacingOccurrences(of: " ", with: "_"))"
        }
        return [
            token("device.model", stringValue(row.model)),
            token("device.chip", stringValue(row.chip)),
            token("device.macos", stringValue(row.macos)),
            token("device.firmware", stringValue(row.firmware)),
            token("device.backend", stringValue(row.backend)),
            token("device.keys.chte", boolValue(row.keyCHTE)),
            token("device.keys.chie", boolValue(row.keyCHIE)),
            token("device.keys.ch0b", boolValue(row.keyCH0B)),
            token("device.discharge", boolValue(row.discharge)),
            token("device.limit.verify", stringValue(row.limitVerify)),
            token("device.discharge.verify", stringValue(row.dischargeVerify)),
        ].joined(separator: " ")
    }

    /// sysctl 字符串取值（hw.model / machdep.cpu.brand_string；失败 → nil）。
    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // buffer 为 NUL 结尾的 C 字符串：截断到首个 NUL 再按 UTF-8 解码
        // （数组形态 init(cString:) 已弃用，走显式截断）。
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// IODeviceTree 固定键 rom-version（隐私护栏：仅取单键属性，禁止整字典 dump）。
    /// 值形态：CFData（字节 → 大写 hex）或 CFString（原样）。
    public static func firmwareRomVersion() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODeviceTree"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "rom-version" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        if let string = value as? String {
            return string
        }
        if let data = value as? Data {
            let hex = data.map { String(format: "%02X", $0) }.joined()
            return hex.isEmpty ? nil : hex
        }
        return nil
    }

    /// sw_vers 输出 → （productVersion, buildVersion）（纯函数；输出形态
    /// "ProductVersion:\t26.6" / "BuildVersion:\t26B2064"，制表符分隔）。
    public static func swVersVersions(from output: String) -> (product: String?, build: String?) {
        var product: String?
        var build: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ProductVersion:"), product == nil {
                product = value(after: "ProductVersion:", in: line)
            } else if line.hasPrefix("BuildVersion:"), build == nil {
                build = value(after: "BuildVersion:", in: line)
            }
        }
        return (product, build)
    }

    /// 限充执法一致性（方案 §3 判据公式）：pass ⟺ mode==active ∧ 外接 ∧ 电量≥上限
    /// ∧ CHTE 停充回读（瞬时执法一致性）；否则 unknown（任一入参缺席即 unknown）。
    public static func limitVerify(status: DaemonStatus?, chargingEnabled: Bool?) -> String {
        guard let status,
              status.mode == "active",
              status.lastExternalConnected == true,
              let percent = status.lastPercent,
              percent >= status.upperLimit,
              let chargingEnabled,
              chargingEnabled == false
        else { return "unknown" }
        return "pass"
    }

    /// 放电完成路径（方案 §3 判据公式）：pass ⟺ lastAction == "dischargeToLimit:done"
    /// （daemon 侧已完成含回读校验的放电）；否则 unknown（瞬态，几乎恒 unknown 属预期）。
    public static func dischargeVerify(status: DaemonStatus?) -> String {
        status?.lastAction == "\(Discharge.dischargeToLimitKind):done" ? "pass" : "unknown"
    }

    private static func value(after prefix: String, in line: String) -> String? {
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}