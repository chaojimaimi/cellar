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
        designCapacityMAh: Int?
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
    }

    /// 快照 → 采样（字段映射 + 功率推导集中在此，App 层采样器零重复）。
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
            designCapacityMAh: snapshot.designCapacityMAh
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
