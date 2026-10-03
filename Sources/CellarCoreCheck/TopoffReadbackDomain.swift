// CellarCoreCheck —— 0.21.3 §1 执法链全区间扩展场景域（方案 phase6-0.21.3 §4.1）
//
// 覆盖清单（门禁钉死项；review 修法已并入）：
// ① owned 扩展矩阵（§1.1）：编排关 79/80/81 边界 / 编排开 ∧ ≥80 不进 owned /
//    全开窗（chargingDisabled/fullOnce）∧ 编排关 ∧ ≥80 不进 owned（R1-P1-1）/
//    窗 ∧ degraded 组合钉死 / 26 恒 false
// ② 违规拍域读回三分支（§1.2 G7b）：TopoffWriter.read 语义（含 review P2：
//    看门狗击杀白名单外退出码 → fail-open）/ 覆写 → 重写 + 清零不耗 strike /
//    一致 → 正常计数 / 读失败 fail-open / 覆写循环不降级
// ③ suppressionConsecutive 计数/锁存/10 min 限频/限频拍清零不计数/解除
//    （§1.3；含 review P1：锁存期非违规拍补采样——一致读回解除半死态、仍覆写
//    走限频自愈对称臂）+ sub80MechanismSuppressed / 两窗 wire 三键 round-trip
//    + 旧 JSON 缺席
//
// 全部纯函数面（run 闭包注入 / 直接构造），不触碰真实 plist、不起 daemon。

import CellarCore
import Foundation

/// 0.21.3 §1 执法链扩展场景域入口（Main.main 调用）。
func runTopoffReadbackDomainScenarios() {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func tick(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * 30) }   // 30s tick 节奏

    // ---- ① owned 扩展矩阵（§1.1 域承载全区间——G7 根治面）----

    // 全域-1：编排关边界 79/80/81 全 owned（79 = sub80 承载原臂；80/81 = 域承载
    // 扩展臂——编排关 ∧ ≥80 ∧ 非全开窗）。desired 恒 nil（编排静默——域独占）。
    do {
        for upper in [79, 80, 81] {
            let route = Topoff.convergenceRoute(
                modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
                upperLimit: upper, sub80Capable: true, actionActive: false,
                degraded: false, healProbeActive: false)
            check(route.topoffOwned && route.orchestrationDesired == nil
                    && route.convergenceTarget == upper,
                  "全域-1", "编排关 ∧ target \(upper) → owned（域承载全区间）∧ desired nil（79 原臂 / 80·81 扩展臂）")
        }
    }

    // 全域-2：编排开 ∧ ≥80 不进 owned（通道语义——MCL 主导区间的域违规非通道失效
    // 证据；degraded 钳 80 会伤害健康的 MCL 执法。周期防线 = §2.1 expectation
    // 编排行对账）。<80 承载原臂不变。
    do {
        for upper in [80, 81, 85, 100] {
            let route = Topoff.convergenceRoute(
                modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
                upperLimit: upper, sub80Capable: true, actionActive: false,
                degraded: false, healProbeActive: false)
            check(!route.topoffOwned && route.orchestrationDesired == upper,
                  "全域-2", "编排开 ∧ target \(upper) → 不进 owned（MCL 主导语义保持——desired=target 原链）")
        }
        let sub80 = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: true, chargingDisabledWindow: false,
            upperLimit: 79, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(sub80.topoffOwned && sub80.orchestrationDesired == nil,
              "全域-2", "编排开 ∧ target 79 → owned 原臂不变（<80 topoff 承载——互斥钉死）")
    }

    // 全域-3：全开窗排除（R1-P1-1）——编排关 ∧ ≥80 ∧ 窗在（fullOnce /
    // chargingDisabled 两型）→ 不进 owned（convergenceTarget 强制 100；窗内回落
    // §3.6 卫生分支写 100 无执法——窗语义即完全放开；进 owned 会路由 healTick
    // 探针写 100 + 超时臂回写 80，违反「域值随汇聚目标」不变量）。
    do {
        let fullOnce = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false, fullOnceWindow: true)
        check(!fullOnce.topoffOwned && fullOnce.convergenceTarget == 100,
              "全域-3", "fullOnce 窗 ∧ 编排关 ∧ 85 → 不进 owned（窗覆盖优先——汇聚 100 卫生分支承载）")
        let scheduleWindow = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: true,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: false, healProbeActive: false)
        check(!scheduleWindow.topoffOwned && scheduleWindow.convergenceTarget == 100,
              "全域-3", "chargingDisabled 日程窗 ∧ 编排关 ∧ 85 → 不进 owned（同上——窗语义即完全放开）")
    }

    // 全域-4：窗 ∧ degraded 组合钉死——降级态 + 窗在 → 仍不进 owned（窗覆盖优先于
    // degraded 状态机——窗内不路由 healTick 探针；窗后回落 degraded 稳态承载）。
    // 无窗 ∧ 编排关 ∧ ≥80 ∧ degraded → owned（healTick 降级自愈链承载——域通道
    // 死亡时 80 钳 + 每小时重探在域侧自洽）。
    do {
        let windowDegraded = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false, fullOnceWindow: true)
        check(!windowDegraded.topoffOwned && windowDegraded.convergenceTarget == 100,
              "全域-4", "fullOnce 窗 ∧ 编排关 ∧ 85 ∧ degraded → 不进 owned（窗覆盖优先——降级状态机不路由探针）")
        let degradedOwned = Topoff.convergenceRoute(
            modeActive: true, orchestrationEnabled: false, chargingDisabledWindow: false,
            upperLimit: 85, sub80Capable: true, actionActive: false,
            degraded: true, healProbeActive: false)
        check(degradedOwned.topoffOwned && degradedOwned.orchestrationDesired == nil,
              "全域-4", "无窗 ∧ 编排关 ∧ 85 ∧ degraded → owned（healTick 自愈链承载；desired nil——编排关静默，MCL 80 兜底归 §2.1 行 7）")
    }

    // 全域-5：26 红线——sub80Capable=false 全矩阵恒 false（owned 扩展在 sub80 门内，
    // 26 零触及；0.19.20 既有链逐值不变）。
    do {
        for orchestration in [true, false] {
            for upper in [75, 80, 85, 100] {
                let route = Topoff.convergenceRoute(
                    modeActive: true, orchestrationEnabled: orchestration,
                    chargingDisabledWindow: false, upperLimit: upper,
                    sub80Capable: false, actionActive: false,
                    degraded: false, healProbeActive: false)
                check(!route.topoffOwned,
                      "全域-5", "26 ∧ 编排\(orchestration ? "开" : "关") ∧ target \(upper) → owned 恒 false（红线零触及）")
            }
        }
    }

    // ---- ② 违规域读回三分支（§1.2 G7b）----

    // 读回-1：TopoffWriter.read 语义——exit 0 解析（尾随空白容忍）；键缺席
    //（exit 1，含域文件不存在）→ 内层 nil；子进程启动失败（负退出码）→ 外层
    // nil（读失败 fail-open）。
    do {
        let ok = TopoffWriter.read { _, _ in ("75\n", 0) }
        check(ok?.limit == 75, "读回-1", "defaults read exit 0 → 解析 Int（尾随换行 trim）")
        let absent = TopoffWriter.read { _, _ in ("Domain ... does not exist", 1) }
        check(absent?.limit == nil && absent?.featureState == nil,
              "读回-1", "键/域缺席（exit 1）→ 内层双 nil（缺席本身参与覆写签名——域文件被删即外部覆写形态）")
        let launchFail = TopoffWriter.read { _, _ in ("", -1) }
        check(launchFail == nil, "读回-1", "子进程启动失败（负退出码）→ 外层 nil（读失败——调用方 fail-open）")
        let mixed = TopoffWriter.read { _, args in
            args.contains(Topoff.limitKey) ? ("80", 0) : ("", 1)
        }
        check(mixed?.limit == 80 && mixed?.featureState == nil,
              "读回-1", "limit 在 ∧ FeatureState 缺席 → (80, nil)（单键缺席独立呈现——featureState≠1 命中覆写签名）")
    }

    // 读回-2：覆写签名命中（UI-100 三键覆写形态：limit=100 ≠ lastWritten=75 ∧
    // featureState=0 ≠ 1）→ 重写意图（writeLimit=target）+ violationTicks 清零 +
    // **不耗 strike** + suppressionConsecutive +1（覆写非通道失效——证据类型区分）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: (limit: 100, featureState: 0))
        check(plan.writeLimit == 75 && plan.state.violationTicks == 0
                && plan.state.strikes == 0 && plan.state.suppressionConsecutive == 1,
              "读回-2", "覆写签名命中 → 重写 75 自愈 + 清零不耗 strike（suppressionConsecutive=1）")
        check(!plan.strikeFired && !plan.notifyOnly,
              "读回-2", "覆写拍无边沿/轻量重申（走域写路径自带通知——三机制分离）")
        // 单键命中臂：limit 一致 ∧ featureState=0 → 同样覆写（双键口径任一命中）。
        var s2 = TopoffChannelState()
        s2.activeTarget = 80
        s2.lastWrittenLimit = 80
        s2.lastWriteAt = tick(0)
        let featureOnly = Topoff.channelTick(
            state: s2, target: 80, now: tick(1),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: (limit: 80, featureState: 0))
        check(featureOnly.writeLimit == 80 && featureOnly.state.suppressionConsecutive == 1,
              "读回-2", "FeatureState 单键覆写（limit 一致 ∧ state=0）→ 同样命中（双键口径 ∨）")
    }

    // 读回-3：签名一致（agent 无视域——percent 越限 ∧ 域值未被外部动过）→ 正常
    // 违规计数（既有链）+ suppressionConsecutive 清零（锁存解除 = 读回一致——
    // 0.21.3 §1.3 钉死）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        s.suppressionConsecutive = 5   // 锁存态（≥2）进入
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.violationTicks == 1 && plan.state.suppressionConsecutive == 0
                && plan.writeLimit == nil && plan.notifyOnly,
              "读回-3", "签名一致 → 锁存解除（清零）+ 正常违规计数（首拍轻量重申 notifyOnly——既有链原样）")
    }

    // 读回-4：读失败（nil——daemon 预判命中但 defaults read 启动失败）→ fail-open
    // 既有计数；suppressionConsecutive 不动（无读回证据不清零不累加）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        s.suppressionConsecutive = 2
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: nil)
        check(plan.state.violationTicks == 1 && plan.state.suppressionConsecutive == 2,
              "读回-4", "读失败 → fail-open 既有计数（suppressionConsecutive 保持——读失败不构成一致/覆写证据）")
    }

    // 读回-5：覆写循环不降级钉死——连续 25 拍（> 验证窗 20）全覆写命中 → strikes
    // 恒 0 ∧ degraded false（覆写证据不进 strike 链；降级对覆写形态无益，升级走
    // suppressed 可见链）。同时钉死 strike 语义纯化：只计 agent 无视。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        var plan: TopoffTickPlan?
        for n in 1...25 {
            plan = Topoff.channelTick(
                state: s, target: 75, now: tick(n),
                percent: 90, externalConnected: true, isCharging: true,
                domainReadback: (limit: 100, featureState: 0))
            s = plan!.state
            if plan!.writeLimit != nil {   // daemon 簿记模拟：锁存前逐拍重写成功
                s.lastWrittenLimit = plan!.writeLimit
                s.lastWriteAt = tick(n)
            }
        }
        check(s.strikes == 0 && !s.degraded && s.suppressionConsecutive == 25,
              "读回-5", "25 拍连续覆写 → 零 strike 零降级（覆写循环不降级钉死；suppressionConsecutive 持续累加）")
    }

    // 读回-6（review P2）：看门狗击杀形态——defaults read 子进程被 0.20.1 看门狗
    // SIGTERM terminate（terminationStatus=15，白名单 {0,1} 外）→ 外层 nil（读
    // 失败 fail-open）——误归「键缺席→覆写签名」会虚增 suppressionConsecutive
    //（两次挂起 = 假锁存，与锁存半死态叠加）。
    do {
        let killed = TopoffWriter.read { _, _ in ("", 15) }
        check(killed == nil, "读回-6", "exit 15（看门狗 SIGTERM 击杀）→ 外层 nil（fail-open 不计覆写）")
        let negative = TopoffWriter.read { _, _ in ("", -1) }
        check(negative == nil, "读回-6", "exit -1（启动失败）→ 外层 nil（既有语义保持）")
        let normalAbsent = TopoffWriter.read { _, _ in ("does not exist", 1) }
        check(normalAbsent != nil && normalAbsent?.limit == nil,
              "读回-6", "exit 1（键/域缺席——defaults 正常退出码）→ 内层 nil 参与签名（白名单内不误判）")
        let singleKeyKilled = TopoffWriter.read { _, args in
            args.contains(Topoff.limitKey) ? ("75", 0) : ("", 15)
        }
        check(singleKeyKilled == nil,
              "读回-6", "单键击杀（limit 成功 ∧ FeatureState exit 15）→ 整体 nil（任一键读失败即 fail-open）")
    }

    // ---- ③ suppressionConsecutive 锁存/限频/解除 + wire（§1.3）----

    // 压制-1：常量 + 计数/锁存——第 2 拍覆写命中 → ≥ Topoff.suppressionThreshold
    //（suppressed 派生 true——wire sub80MechanismSuppressed 数据源）。
    do {
        check(Topoff.suppressionThreshold == 2, "压制-1", "锁存阈值 = 2（方案 §1.3 钉死）")
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        var latched = false
        for n in 1...2 {
            let plan = Topoff.channelTick(
                state: s, target: 75, now: tick(n),
                percent: 90, externalConnected: true, isCharging: true,
                domainReadback: (limit: 100, featureState: 0))
            s = plan.state
            if plan.writeLimit != nil { s.lastWrittenLimit = plan.writeLimit; s.lastWriteAt = tick(n) }
            latched = s.suppressionConsecutive >= Topoff.suppressionThreshold
        }
        check(s.suppressionConsecutive == 2 && latched,
              "压制-1", "第 2 拍覆写命中 → suppressionConsecutive=2 ≥ 阈值 → suppressed 锁存（重写限频生效前提）")
    }

    // 压制-2：锁存后重写限频（复用 reassertionCooldown 10 min）——锁存拍起
    // lastWriteAt 近（30s < 600s）→ writeLimit=nil；10 min 后 → 重写 target。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.suppressionConsecutive = 2   // 已锁存进入
        s.lastWriteAt = tick(0)        // 上次重写 30s 内
        let throttled = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: (limit: 100, featureState: 0))
        check(throttled.writeLimit == nil && throttled.state.suppressionConsecutive == 3
                && throttled.state.violationTicks == 0,
              "压制-2", "锁存后限频拍（30s < 10 min）→ 不重写（writeLimit=nil）——防持续覆写 30s churn")
        let due = Topoff.channelTick(
            state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.reassertionCooldown + 30),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: (limit: 100, featureState: 0))
        check(due.writeLimit == 75 && due.state.suppressionConsecutive == 3,
              "压制-2", "冷却到期（≥10 min）→ 重写 75 自愈（锁存不阻断低频重写——Cellar 正在自动恢复的执行面）")
    }

    // 压制-3：**限频拍证据归类唯一化（R2-P2）**——锁存后限频拍读回仍覆写签名 →
    // 一律清零不计数（限频只封 writeLimit，不改变证据归类）。连打 40 拍（20 min
    // > 验证窗）全覆写 → 零 strike 零降级（否则限频拍计数 20 tick 后 strike→
    // degraded 违背「覆写不降级」钉死语义）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        for n in 1...40 {
            let plan = Topoff.channelTick(
                state: s, target: 75, now: tick(n),
                percent: 90, externalConnected: true, isCharging: true,
                domainReadback: (limit: 100, featureState: 0))
            s = plan.state
            if plan.writeLimit != nil { s.lastWrittenLimit = plan.writeLimit; s.lastWriteAt = tick(n) }
            check(s.violationTicks == 0,
                  "压制-3", "限频拍（第 \(n) 拍）violationTicks 恒 0——覆写证据不进验证窗（R2-P2 归类唯一化）")
        }
        check(s.strikes == 0 && !s.degraded && s.suppressionConsecutive == 40,
              "压制-3", "40 拍全覆写（含锁存后限频拍）→ 零 strike 零降级（覆写不降级语义在限频拍同样成立）")
    }

    // 压制-4：锁存解除 = 读回一致清零（覆盖失败重试后用户在系统设置改回具体值的
    // 恢复路径；wire sub80MechanismSuppressed 随下拍回 false——App 警示行/doctor
    // FAIL 自然回落）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        s.suppressionConsecutive = 7
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 90, externalConnected: true, isCharging: true,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsecutive == 0
                && plan.state.suppressionConsecutive < Topoff.suppressionThreshold,
              "压制-4", "读回一致 → suppressionConsecutive 清零（锁存解除——≥7 深锁存同样一步解除）")
        // 非违规拍且无注入（未锁存期非违规拍 daemon 不采样 / 采样缺席防御臂）→
        // 计数保持（锁存期的补采样注入见压制-6——review P1）。
        let idlePlan = Topoff.channelTick(
            state: s, target: 75, now: tick(2),
            percent: 75, externalConnected: true, isCharging: false)
        check(idlePlan.state.suppressionConsecutive == 7 && idlePlan.writeLimit == nil,
              "压制-4", "非违规拍且无读回注入 → 计数保持（未锁存期非违规拍零采样——健康稳态零子进程）")
    }

    // 压制-6（review P1 锁存半死态根治钉面）：锁存期**非违规拍**补采样（daemon
    // 预判 = isViolationTick ∨ suppressed 锁存）注入读回一致 → 解除——覆写源停止
    // 且再无违规拍的形态下，锁存仍可经本路径下一拍解除（wire「随轮询自然消失」
    // 兑现；否则唯一清零点在违规拍 = 永久滞留假 FAIL）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        s.suppressionConsecutive = 4   // 锁存态（≥2）；覆写源已停止（域回 75/1）
        let plan = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 75, featureState: 1))
        check(plan.state.suppressionConsecutive == 0
                && plan.state.suppressionConsecutive < Topoff.suppressionThreshold
                && plan.writeLimit == nil && plan.state.violationTicks == 0,
              "压制-6", "锁存期非违规拍读回一致 → 清零解除（writeLimit=nil 静默解锁——半死态根治）")
    }

    // 压制-7（review P1 对称臂）：锁存期非违规拍补采样读回**仍覆写**（覆写源驻留
    // 但当前电量未越限）→ 同走覆写自愈臂（+1 + 限频重写——域值错误与充电态无关，
    // 重写即自愈；不计验证窗不耗 strike）。
    do {
        var s = TopoffChannelState()
        s.activeTarget = 75
        s.lastWrittenLimit = 75
        s.lastWriteAt = tick(0)
        s.suppressionConsecutive = 3
        let throttled = Topoff.channelTick(
            state: s, target: 75, now: tick(1),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(throttled.writeLimit == nil && throttled.state.suppressionConsecutive == 4
                && throttled.state.violationTicks == 0 && throttled.state.strikes == 0,
              "压制-7", "锁存期非违规拍覆写（冷却未到）→ +1 限频不写（不计数不耗 strike）")
        let due = Topoff.channelTick(
            state: s, target: 75, now: tick(0).addingTimeInterval(Topoff.reassertionCooldown + 30),
            percent: 75, externalConnected: true, isCharging: false,
            domainReadback: (limit: 100, featureState: 0))
        check(due.writeLimit == 75 && due.state.suppressionConsecutive == 4,
              "压制-7", "锁存期非违规拍覆写（冷却到期）→ 重写 75 自愈（驻留覆写源的低频对抗）")
    }

    // 压制-5：wire 三键 round-trip + 旧 JSON 缺席（sub80MechanismSuppressed /
    // fullOnceWindowActive / chargingDisabledWindowActive——decodeIfPresent 追加式
    // 兼容先例；旧 daemon 回包/旧客户端解码天然兼容）。
    do {
        let status = DaemonStatus(
            version: "t", mode: "active", upperLimit: 75, hysteresis: 2,
            sub80State: .active, sub80MechanismSuppressed: true,
            fullOnceWindowActive: false, chargingDisabledWindowActive: true)
        let round = DaemonXPC.encodeStatus(status).flatMap { try? DaemonXPC.decodeStatus($0) }
        check(round?.sub80MechanismSuppressed == true
                && round?.fullOnceWindowActive == false
                && round?.chargingDisabledWindowActive == true,
              "压制-5", "三新键 round-trip 全保留（sub80MechanismSuppressed / 两窗——27 恒填面）")
        let legacyJSON = """
        {"version":"t","mode":"active","upperLimit":75,"hysteresis":2,"timestamp":0}
        """
        let legacy = try? JSONDecoder().decode(DaemonStatus.self, from: Data(legacyJSON.utf8))
        check(legacy?.sub80MechanismSuppressed == nil && legacy?.fullOnceWindowActive == nil
                && legacy?.chargingDisabledWindowActive == nil,
              "压制-5", "旧 daemon 回包（三键缺席）→ nil 天然兼容（无此特性语义）")
        check(DaemonStatus(version: "t", mode: "active", upperLimit: 75, hysteresis: 2)
                .sub80MechanismSuppressed == nil,
              "压制-5", "init 缺省 nil（既有构造点零 diff——合成 Codable 先例）")
    }
}
