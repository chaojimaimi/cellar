import Foundation

/// 一条电池采样（samples 表一行的值投影；亦是 StatsBucketing 聚合的输入单元）。
///
/// `powerMW` 在构造点即定案为推导值（powerMilliwatts）——库层只存不推导，
/// 符号纪律在类型构造处一次性锁死。
public struct StatsSample: Equatable, Sendable {
    /// 采样时刻（入库截为 Unix epoch 秒整——Schema v1 主键 ts）。
    public let timestamp: Date
    /// 电量百分比（CurrentCapacity 直读）。
    public let percent: Int
    /// 电池温度（厘摄氏度，快照原值）。
    public let temperatureCentiC: Int
    /// 电池侧功率（毫瓦；推导值，符号源 isCharging）。
    public let powerMW: Int
    /// 外部电源是否连接。
    public let externalConnected: Bool
    /// 是否充电中。
    public let isCharging: Bool
    /// 循环次数。
    public let cycleCount: Int
    /// 当前最大容量 %（快照缺席 → nil，入库 NULL——R-6 缺席机型容错）。
    public let maxCapacityPercent: Int?
    /// 标称容量 mAh（缺席 → nil）。
    public let nominalChargeCapacityMAh: Int?
    /// 设计容量 mAh（Schema v1 同为可空列；快照域该字段非可选，恒有值）。
    public let designCapacityMAh: Int?
    // MARK: 0.22.0 §2.2 能耗统计六列（Schema v2 全可空；旧行/键缺席机型 → nil
    // ——配对差分要求两端非 NULL，NULL 行自然不参与能耗计算）。
    /// 系统负载能量累加器 mW·s（AccumulatedSystemLoad；缺席 → nil）。
    public let accSystemLoadMWs: Int?
    /// 累加器样本计数（SystemLoadAccumulatorCount；计数回退 = 复位判据）。
    public let accSystemLoadCount: Int?
    /// 电池放电能量累加器 mW·s（AccumulatedBatteryDischarge；放电期递减）。
    public let accBatteryDischarge: Int?
    /// 放电累加器样本计数（BatteryDischargeAccumulatorCount）。
    public let accBatteryDischargeCount: Int?
    /// 今日最低电量 %（Pack 层系统键；重置时机未知——展示如实标注）。
    public let dailyMinSoc: Int?
    /// 今日最高电量 %（同上）。
    public let dailyMaxSoc: Int?

    public init(
        timestamp: Date,
        percent: Int,
        temperatureCentiC: Int,
        powerMW: Int,
        externalConnected: Bool,
        isCharging: Bool,
        cycleCount: Int,
        maxCapacityPercent: Int?,
        nominalChargeCapacityMAh: Int?,
        designCapacityMAh: Int?,
        accSystemLoadMWs: Int? = nil,
        accSystemLoadCount: Int? = nil,
        accBatteryDischarge: Int? = nil,
        accBatteryDischargeCount: Int? = nil,
        dailyMinSoc: Int? = nil,
        dailyMaxSoc: Int? = nil
    ) {
        self.timestamp = timestamp
        self.percent = percent
        self.temperatureCentiC = temperatureCentiC
        self.powerMW = powerMW
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.cycleCount = cycleCount
        self.maxCapacityPercent = maxCapacityPercent
        self.nominalChargeCapacityMAh = nominalChargeCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.accSystemLoadMWs = accSystemLoadMWs
        self.accSystemLoadCount = accSystemLoadCount
        self.accBatteryDischarge = accBatteryDischarge
        self.accBatteryDischargeCount = accBatteryDischargeCount
        self.dailyMinSoc = dailyMinSoc
        self.dailyMaxSoc = dailyMaxSoc
    }

    /// 快照 → 采样（字段映射 + 功率推导集中在此，App 层采样器零重复）。
    /// 0.22.0：累加器/SOC 六字段随遥测透传（快照缺席 → nil 入库 NULL）。
    public init(snapshot: BatterySnapshot) {
        self.init(
            timestamp: snapshot.timestamp,
            percent: snapshot.percent,
            temperatureCentiC: snapshot.temperatureCentiC,
            powerMW: Self.powerMilliwatts(
                voltageMV: snapshot.voltageMV,
                amperageMA: snapshot.amperageMA,
                isCharging: snapshot.isCharging
            ),
            externalConnected: snapshot.externalConnected,
            isCharging: snapshot.isCharging,
            cycleCount: snapshot.cycleCount,
            maxCapacityPercent: snapshot.maxCapacityPercent,
            nominalChargeCapacityMAh: snapshot.nominalChargeCapacityMAh,
            designCapacityMAh: snapshot.designCapacityMAh,
            accSystemLoadMWs: snapshot.telemetry?.accSystemLoadMWs,
            accSystemLoadCount: snapshot.telemetry?.accSystemLoadCount,
            accBatteryDischarge: snapshot.telemetry?.accBatteryDischarge,
            accBatteryDischargeCount: snapshot.telemetry?.accBatteryDischargeCount,
            dailyMinSoc: snapshot.dailyMinSoc,
            dailyMaxSoc: snapshot.dailyMaxSoc
        )
    }

    /// 功率推导（R1 P1-2 定案）：|voltageMV| × |amperageMA| / 1000，符号源 =
    /// isCharging（+充 −放）。⚠️ 禁止裸 V×I——BatterySnapshot.amperageMA 符号
    /// 语义未定（真机实测互相矛盾），方向判定一律以 isCharging 为准。
    /// 数值取四舍五入整毫瓦。
    public static func powerMilliwatts(voltageMV: Int, amperageMA: Int, isCharging: Bool) -> Int {
        let magnitude = (Double(abs(voltageMV)) * Double(abs(amperageMA)) / 1000).rounded()
        return isCharging ? Int(magnitude) : -Int(magnitude)
    }
}
