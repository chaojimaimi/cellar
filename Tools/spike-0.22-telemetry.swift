#!/usr/bin/env swift
// Cellar 0.22.0 能耗遥测 spike（方案 §5.1）——只读观察期工具，用户真机执行。
//
// 背景（SMC-NOTES §11.7/§11.8）：主通道累加器 = 能量表（系统通道 K=1.101 递增、
// BatteryDischarge K≈0.825 递减、AccumulatedBatteryPower 剔除、计数回退 = 复位
// 判据）。本工具 = 观察期实验④主工具（充电窗前后各采一对：BatteryDischarge
// 递增符号/标度 + WallEnergy 差值语义）+ IPD 域 mini-spike（判据：IPDInputPower
// vs SystemPowerIn 偏差量级、IPDChargingAllowed/IPDWattageOverride 语义观察、
// IPD 可否作适配器输入功率旁证源——结论只登记不产品化）。
//
// 实现纪律（§11.7 N4）：`ioreg -a` XML 按结构解析（PropertyListSerialization），
// 不文本 grep。**零写入零状态变更**（红色线沿袭）：无 defaults 写、无 SMC 写、
// 无 notify post——仅 ioreg 只读子进程 ×2。
//
// 用法：
//   swift Tools/spike-0.22-telemetry.swift acc   # PTD 全累加器族+计数+瞬时六键+DailyMin/MaxSoc（kv 行）
//   swift Tools/spike-0.22-telemetry.swift ipd   # PowerDistribution（IPD 域六键）+ PTD 瞬时对照
//
// 实验④采样指引（充电窗判谳——拔电→插电各跑一次 `acc`，间隔 ≥10 min）：
//   对 (t0, t1)：ΔAcc_BatteryDischarge > 0 = 充电窗递增（符号定谳输入②）；
//   ΔAcc_WallEnergyEstimate vs ΔAcc_SystemEnergyConsumed 差值 = 效率损失语义
//   （待办④）；计数 BatteryDischargeAccumulatorCount 节奏（0.83/s 假设复验）。

import Foundation

// ── 只读子进程捕获（ioreg XML 输出）────────────────────────────────────

func runCapture(_ path: String, _ args: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

/// 注册表节点属性（N4 纪律：-a XML → plist 结构解析；缺席/解析失败 → nil）。
func registryEntry(named name: String) -> [String: Any]? {
    guard let data = runCapture("/usr/sbin/ioreg", ["-a", "-rw0", "-n", name]),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          let entries = plist as? [[String: Any]] else { return nil }
    return entries.first
}

/// 嵌套子字典（PTD / BatteryData / PowerDistribution 同款取值面）。
func subdict(_ dict: [String: Any]?, _ key: String) -> [String: Any]? {
    dict?[key] as? [String: Any]
}

/// 值格式化：数值按 objCType 分流取位（负值 NSNumber 直呼 uint64Value 会 trap
/// ——本机 BatteryPower 实测负值）；位型回绕负值 raw + Int64(bitPattern:) 对照
/// 输出（B-4 纪律）；其余类型 description 直出。
func describe(_ value: Any?) -> String {
    guard let value else { return "ABSENT" }
    if let number = value as? NSNumber {
        // CFBoolean 也是 NSNumber——布尔先判（true/false 语境不输出数值形态）。
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let encoding = String(cString: number.objCType)
        let raw: UInt64
        if encoding == "Q" || encoding == "I" || encoding == "L"
            || encoding == "C" || encoding == "S" || encoding == "B" {
            raw = number.uint64Value          // 无符号存储
        } else {
            raw = UInt64(bitPattern: number.int64Value)   // 有符号存储按位保留
        }
        let signed = Int64(bitPattern: raw)
        return raw > UInt64(Int64.max) ? "\(raw)(w→\(signed))" : "\(raw)"
    }
    return String(describing: value)
}

func kv(_ key: String, _ value: Any?) {
    print("\(key)=\(describe(value))")
}

// ── 子命令 ───────────────────────────────────────────────────────────────

let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "acc"

switch cmd {
case "acc":
    // AppleSmartBattery 顶层：PowerTelemetryData 全字典（累加器族 + 计数 + 瞬时
    // 六键——§11.7 N3 实测 26 键全形；未知新键随 generic dump 自然收录）。
    guard let battery = registryEntry(named: "AppleSmartBattery") else {
        print("acc.verdict=registry-entry-not-found")
        exit(3)
    }
    let ptd = subdict(battery, "PowerTelemetryData")
    print("acc.ptd.present=\(ptd != nil)")
    // 状态对照（实验④判读语境：AC/电池态决定通道语义）。
    kv("acc.ExternalConnected", battery["ExternalConnected"])
    kv("acc.IsCharging", battery["IsCharging"])
    kv("acc.CurrentCapacity", battery["CurrentCapacity"])
    // 瞬时六键（v1.11 定名；产品化解析面同源）。
    for key in ["SystemPowerIn", "SystemLoad", "BatteryPower",
                "AdapterEfficiencyLoss", "SystemVoltageIn", "SystemCurrentIn"] {
        kv("acc.instant.\(key)", ptd?[key])
    }
    // 全累加器族 + 计数（generic dump——已知键名仅作顺序提示，未知键不漏）。
    if let ptd {
        let sortedKeys = ptd.keys.sorted()
        for key in sortedKeys where key.hasPrefix("Accumulated")
            || key.hasPrefix("Accum")
            || key.hasSuffix("AccumulatorCount")
            || key == "WallEnergyEstimate" || key == "SystemEnergyConsumed"
            || key == "SystemEffectiveTotalLoad" || key == "PowerTelemetryErrorCount" {
            kv("acc.family.\(key)", ptd[key])
        }
        print("acc.family.key_count=\(sortedKeys.count)")
    }
    // Pack 层 DailyMin/MaxSoc（§11.7：AppleSmartBatteryPack → BatteryData，
    // 非 root 可读；重置时机未知——展示如实标注）。
    if let pack = registryEntry(named: "AppleSmartBatteryPack") {
        let packBatteryData = subdict(pack, "BatteryData")
        kv("acc.pack.DailyMinSoc", packBatteryData?["DailyMinSoc"])
        kv("acc.pack.DailyMaxSoc", packBatteryData?["DailyMaxSoc"])
    } else {
        print("acc.pack.present=false")
    }
    print("acc.verdict=done(只读——ioreg×2，零写入)")
case "ipd":
    // PowerDistribution（IPD 域，§11.7 N3 顶层新键）+ PTD 瞬时对照（AC 态判据：
    // IPDInputPower vs SystemPowerIn 偏差量级——适配器输入功率旁证源候选）。
    guard let battery = registryEntry(named: "AppleSmartBattery") else {
        print("ipd.verdict=registry-entry-not-found")
        exit(3)
    }
    let ipd = subdict(battery, "PowerDistribution")
    print("ipd.present=\(ipd != nil)")
    if let ipd {
        for key in ["IPDInputPower", "IPDInputVoltage", "IPDInputCurrent",
                    "IPDWattageOverride", "IPDRatio", "IPDChargingAllowed"] {
            kv("ipd.\(key)", ipd[key])
        }
        print("ipd.key_count=\(ipd.keys.count)")
    }
    // PTD 瞬时对照（同帧——偏差量级判据的直接输入）。
    let ptd = subdict(battery, "PowerTelemetryData")
    kv("ipd.ref.SystemPowerIn", ptd?["SystemPowerIn"])
    kv("ipd.ref.SystemLoad", ptd?["SystemLoad"])
    kv("ipd.ref.BatteryPower", ptd?["BatteryPower"])
    kv("ipd.ref.ExternalConnected", battery["ExternalConnected"])
    print("ipd.verdict=done(只读——判据：AC 态 IPDInputPower vs SystemPowerIn 偏差；IPDChargingAllowed/IPDWattageOverride 语义观察)")
default:
    print("用法：spike-0.22-telemetry.swift acc | ipd")
    exit(2)
}
