import CellarCore
import Foundation

// Phase 5 v1.2：时间估算场景域（方案 §3.6，R1 P1-3 十一场景：充电/放电外推、
// holding 不适用、短窗/无变化不可信、钳制上下界、跨 gap 重开剔除、
// 态切换清环（跳变断段）、斜率反向拒绝、恰好到达上限）。纯函数直接构造，
// 无真机依赖；与 MainEntry 的既有场景域同构（FailureCounter + check 助手）。
//
// 造数纪律：percent 为 Int，线性斜坡经取整成台阶——台阶量化会使最小二乘
// 斜率偏离名义值（Δ 越小偏差占比越大）。各场景 Δ 取大（≥5%/窗），量化
// 偏差 ≪ 1%，断言值取整后确定（先经本机实测钉死）。

/// 线性样本构造：从 base 起每秒一点、共 count 点，percent 自 startPercent
/// 线性走向 endPercent（span = count − 1 秒；端点是精确的，中间点整数取整）。
private func linearSamples(
    base: TimeInterval,
    count: Int,
    startPercent: Int,
    endPercent: Int
) -> [TimeSample] {
    (0..<count).map { index in
        let percent = startPercent + Int(
            (Double(endPercent - startPercent) * Double(index) / Double(count - 1)).rounded()
        )
        return TimeSample(
            date: Date(timeIntervalSince1970: base + Double(index)),
            percent: percent
        )
    }
}

/// 定值样本（无变化的对比形态）。
private func flatSamples(base: TimeInterval, count: Int, percent: Int) -> [TimeSample] {
    (0..<count).map {
        TimeSample(date: Date(timeIntervalSince1970: base + Double($0)), percent: percent)
    }
}

/// 容差断言（仅估算8/估算9 使用）：末段斜坡 Δ 小（5%/300s），整数取整的台阶
/// 量化使最小二乘斜率偏离名义值 ≈2%——断言的是「只认末段」规则而非斜率算术，
/// 故允许 ±2 分钟（量化偏差上界，实测确定性成立；顺带防未来实现漂移的脆断言）。
private func expectClose(
    _ actual: Int?,
    _ expected: Int,
    tolerance: Int,
    _ scenario: String,
    _ message: String
) {
    if let actual, abs(actual - expected) <= tolerance {
        check(true, scenario, message)
    } else {
        check(false, scenario, "\(message)（实际 \(actual.map(String.init) ?? "nil")，期望 ≈\(expected)±\(tolerance)）")
    }
}

func runTimeEstimatorDomainScenarios() {
    // 场景 1：充电外推——10 分钟窗内 +10%（名义斜率 60%/h）→ 至上限还需 10 分钟。
    let chargingRamp = linearSamples(base: 1_700_000_000, count: 601, startPercent: 60, endPercent: 70)
    let chargeEstimate = TimeEstimator.estimateMinutes(
        samples: chargingRamp, state: .charging, upperLimit: 80
    )
    expectEqual(chargeEstimate, 10, "估算1", "充电外推（+10%/10min，上限 80，当前 70）= 10 分钟")

    // 场景 2：放电外推——10 分钟窗内 −10%（名义斜率 −60%/h）→ 预计可用 62 分钟。
    let drainRamp = linearSamples(base: 1_700_000_000, count: 601, startPercent: 72, endPercent: 62)
    let batteryEstimate = TimeEstimator.estimateMinutes(
        samples: drainRamp, state: .battery, upperLimit: 80
    )
    expectEqual(batteryEstimate, 62, "估算2", "放电外推（−10%/10min，当前 62）= 62 分钟")

    // 场景 3：holding 无时间语义——任何样本集一律 nil。
    let holdingEstimate = TimeEstimator.estimateMinutes(
        samples: chargingRamp, state: .holding, upperLimit: 80
    )
    check(holdingEstimate == nil, "估算3", "holding（直供）恒 nil")

    // 场景 4：短窗不可信——窗长 239s < 5 分钟 → nil。
    let shortWindow = linearSamples(base: 1_700_000_000, count: 240, startPercent: 70, endPercent: 71)
    let shortEstimate = TimeEstimator.estimateMinutes(
        samples: shortWindow, state: .charging, upperLimit: 80
    )
    check(shortEstimate == nil, "估算4", "有效窗 <5 分钟 → nil（斜率不可信）")

    // 场景 5：无变化不可信——窗内 |Δpercent| == 0 < 1 → nil。
    let flat = flatSamples(base: 1_700_000_000, count: 301, percent: 60)
    let flatEstimate = TimeEstimator.estimateMinutes(
        samples: flat, state: .battery, upperLimit: 80
    )
    check(flatEstimate == nil, "估算5", "窗内 |Δpercent| < 1 → nil（无变化）")

    // 场景 6：钳制下限——陡充电（+30%/10min，名义斜率 180%/h）外推 0.33 分钟 →
    // 向下钳制到 1 分钟。
    let steepRamp = linearSamples(base: 1_700_000_000, count: 601, startPercent: 49, endPercent: 79)
    let lowerClamp = TimeEstimator.estimateMinutes(
        samples: steepRamp, state: .charging, upperLimit: 80
    )
    expectEqual(lowerClamp, 1, "估算6", "陡斜率外推 <1 分钟 → 钳制下限 1 分钟")

    // 场景 7：钳制上限——放电数据集末端单点跳变（50×300s → 48，|Δ|≤2 不断段）
    // 使最小二乘斜率失真（≈ −0.47%/h），外推 ≈ 6000 分钟 → 钳制上限 48 小时。
    var spikeSamples = flatSamples(base: 1_700_000_000, count: 300, percent: 50)
    spikeSamples.append(TimeSample(
        date: Date(timeIntervalSince1970: 1_700_000_000 + 300), percent: 48
    ))
    let upperClamp = TimeEstimator.estimateMinutes(
        samples: spikeSamples, state: .battery, upperLimit: 80
    )
    expectEqual(upperClamp, 2880, "估算7", "异常小斜率外插 → 钳制上限 48 小时")

    // 场景 8：跨 gap 重开——前段 10 分钟（70→60）+ 5 分钟中断 + 末段 5 分钟
    // （50→45）：只认末段（名义斜率 −60%/h）→ ≈45 分钟；前段混合会拟合出
    // 完全不同的斜率。
    var gapSamples = linearSamples(base: 1_700_000_000, count: 601, startPercent: 70, endPercent: 60)
    gapSamples.append(contentsOf: linearSamples(
        base: 1_700_000_000 + 900, count: 301, startPercent: 50, endPercent: 45
    ))
    let gapEstimate = TimeEstimator.estimateMinutes(
        samples: gapSamples, state: .battery, upperLimit: 80
    )
    expectClose(gapEstimate, 45, tolerance: 2, "估算8", "跨 gap 仅末段参与拟合（50→45/5min → ≈45 分钟）")

    // 场景 9：态切换清环（跳变断段）——调用方未清环的异态样本（充电段 60→62
    // 后秒级跳 +3 到 65 直入放电段 65→60）：估算器按跳变断段只认放电末段
    // （名义斜率 −60%/h）→ 60 分钟，异态混合不进入斜率。
    var flipSamples = linearSamples(base: 1_700_000_000, count: 600, startPercent: 60, endPercent: 62)
    flipSamples.append(contentsOf: linearSamples(
        base: 1_700_000_000 + 600, count: 301, startPercent: 65, endPercent: 60
    ))
    let flipEstimate = TimeEstimator.estimateMinutes(
        samples: flipSamples, state: .battery, upperLimit: 80
    )
    expectClose(flipEstimate, 60, tolerance: 2, "估算9", "电量跳变断段 → 只认放电末段（65→60/5min → ≈60 分钟）")

    // 场景 10：斜率反向拒绝——充电态遇负斜率 / 电池态遇正斜率 → nil。
    let reverseCharging = TimeEstimator.estimateMinutes(
        samples: drainRamp, state: .charging, upperLimit: 80
    )
    let reverseBattery = TimeEstimator.estimateMinutes(
        samples: chargingRamp, state: .battery, upperLimit: 80
    )
    check(reverseCharging == nil && reverseBattery == nil, "估算10", "斜率符号与电源段相悖 → nil")

    // 场景 11：恰好到达上限——当前电量 == upperLimit → nil（已满无需估算）。
    let reachedLimit = linearSamples(base: 1_700_000_000, count: 601, startPercent: 78, endPercent: 80)
    let reachedEstimate = TimeEstimator.estimateMinutes(
        samples: reachedLimit, state: .charging, upperLimit: 80
    )
    check(reachedEstimate == nil, "估算11", "percent == upperLimit → nil")

    // 场景 12：新鲜度截断独立生效（P3-4）——932 点全程 1s 连续（无时间 gap、
    // 无跳变断段，gap/跳变两条断段规则均不参与），但总跨度 931s > 15min：
    // 距最新 >15min 的最前 31s 异常陡升段（50→60，名义 1200%/h）被剔除，
    // 估算只来自其后 15 分钟平缓段（61→70，名义 36%/h）→ ≈17 分钟；
    // 若截断缺席，混合全窗斜率 ≈77%/h → ≈8 分钟——区分度明确，验证截断
    // 规则不被 gap 规则主导遮蔽。
    let freshnessSamples: [TimeSample] = (0...931).map { index in
        let percent = index <= 30
            ? 50 + Int((Double(10) * Double(index) / 30).rounded())
            : 61 + Int((Double(9 * (index - 31)) / 900).rounded())
        return TimeSample(
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            percent: percent
        )
    }
    let freshnessEstimate = TimeEstimator.estimateMinutes(
        samples: freshnessSamples, state: .charging, upperLimit: 80
    )
    expectClose(freshnessEstimate, 17, tolerance: 1, "估算12",
                "连续无间隙跨 >15min：新鲜度截断独立生效（剔 31s 陡升段 → ≈17 分钟）")
}