// CellarCoreCheck —— WP5 DEVICES 设备行场景域（方案 §3）
//
// 契约面：字段序固定 11 项（机器可解析）、缺值 unknown、值内空格占位；
// sw_vers 解析纯函数；verify 判据公式（评审 P1-7 定版）。真机采集面
// （sysctl/IODeviceTree/IOPS）无确定性断言，不进用例。

import CellarCore
import Foundation

/// DEVICES 设备行场景域入口（Main.main 调用）。
func runDeviceInfoDomainScenarios() {
    // 设备-1：字段序固定（11 令牌逐一核对；全值形态）。
    do {
        let row = DeviceRow(
            model: "Mac15,9", chip: "Apple M4 Pro", macos: "26.6 (26B2064)",
            firmware: "10151.140.19.0.1", backend: "tahoe",
            keyCHTE: true, keyCHIE: true, keyCH0B: false,
            discharge: true, limitVerify: "pass", dischargeVerify: "unknown"
        )
        let line = DeviceInfo.line(row)
        check(line == "device.model=Mac15,9 device.chip=Apple_M4_Pro device.macos=26.6_(26B2064) device.firmware=10151.140.19.0.1 device.backend=tahoe device.keys.chte=yes device.keys.chie=yes device.keys.ch0b=no device.discharge=yes device.limit.verify=pass device.discharge.verify=unknown",
              "设备-1", "11 字段序固定（key=value 空格分隔；值内空格以 _ 占位保令牌契约）")
    }

    // 设备-2：缺值一律 unknown（空行形态——全缺省 DeviceRow）。
    do {
        let line = DeviceInfo.line(DeviceRow())
        check(line == "device.model=unknown device.chip=unknown device.macos=unknown device.firmware=unknown device.backend=unknown device.keys.chte=unknown device.keys.chie=unknown device.keys.ch0b=unknown device.discharge=unknown device.limit.verify=unknown device.discharge.verify=unknown",
              "设备-2", "全缺省 → 11 个 unknown（字段序与表头不变）")
    }

    // 设备-3：sw_vers 输出解析（制表符分隔形态 + 缺行不崩）。
    do {
        let output = "ProductName:\tmacOS\nProductVersion:\t26.6\nBuildVersion:\t26B2064\n"
        let versions = DeviceInfo.swVersVersions(from: output)
        check(versions.product == "26.6" && versions.build == "26B2064",
              "设备-3", "sw_vers 输出 → (productVersion, buildVersion)")
        let partial = DeviceInfo.swVersVersions(from: "ProductVersion:\t26.6\n")
        check(partial.product == "26.6" && partial.build == nil,
              "设备-3", "缺 BuildVersion 行不崩（build=nil）")
    }

    // 设备-4：limit.verify 判据公式（pass ⟺ mode==active ∧ 外接 ∧ 电量≥上限 ∧ CHTE 停充）。
    func status(
        mode: String = "active", external: Bool? = true,
        percent: Int? = 80, lastAction: String? = "enforce:disableCharging"
    ) -> DaemonStatus {
        DaemonStatus(
            version: "t", mode: mode, upperLimit: 80, hysteresis: 2,
            lastAction: lastAction, lastPercent: percent,
            lastExternalConnected: external, lastChargingEnabled: false
        )
    }
    check(DeviceInfo.limitVerify(status: status(), chargingEnabled: false) == "pass",
          "设备-4", "全条件成立 → pass（瞬时执法一致性）")
    check(DeviceInfo.limitVerify(status: status(), chargingEnabled: true) == "unknown",
          "设备-4", "CHTE 停充回读不符（仍在充电）→ unknown")
    check(DeviceInfo.limitVerify(status: status(percent: 79), chargingEnabled: false) == "unknown",
          "设备-4", "电量未达上限 → unknown")
    check(DeviceInfo.limitVerify(status: status(external: false), chargingEnabled: false) == "unknown",
          "设备-4", "未外接 → unknown")
    check(DeviceInfo.limitVerify(status: status(mode: "disabled"), chargingEnabled: false) == "unknown",
          "设备-4", "mode≠active → unknown")
    check(DeviceInfo.limitVerify(status: nil, chargingEnabled: false) == "unknown",
          "设备-4", "daemon 未运行 → unknown")

    // 设备-5：discharge.verify 判据公式（pass ⟺ lastAction == dischargeToLimit:done）。
    check(DeviceInfo.dischargeVerify(status: status(lastAction: "dischargeToLimit:done")) == "pass",
          "设备-5", "放电动作 done 终态 → pass")
    check(DeviceInfo.dischargeVerify(status: status(lastAction: "dischargeToLimit:start")) == "unknown",
          "设备-5", "放电进行中 → unknown（瞬态属预期）")
    check(DeviceInfo.dischargeVerify(status: nil) == "unknown", "设备-5", "daemon 未运行 → unknown")
}