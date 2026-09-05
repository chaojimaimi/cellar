// CellarCoreCheck —— Phase 5 v1.7 原生限充检测器场景域（方案 §2.2 清单）
//
// 按域拆独立文件（main 不再增长）——CalibrationScheduleDomain 同款分层声明；
// 与其他场景域共用 FailureCounter 与断言助手。daemon 侧接线（守卫/XPC/doctor）
// 归 M2（DaemonXPC.swift 的 NativeLimitStatus 届时定义）——本域把 §2.2 要求的
// wire 映射场景先落为对 reading 三态的形态断言（detectorError 形态 / isEmpty
// 语义 / blocking·manual 口径），M2 接线时自然复用。
//
// 覆盖清单（方案 §2.2 + M1 工单）：
// ① 平层归档解析：单策略/多策略（OBC reason 混入）/terminated 全量保留/结构异常/
//    空 policies/缺 policies 键
// ② CF$UID 包装值解析（soclimit/reason/terminated 为 UID 包装 → 正确解出；
//    平层字面键 + UID 值手工形态——§1「归档内的值可能是 CF$UID 包装」防御场景）
// ③ 策略级异常丢弃（soclimit 非整数/缺键 → 该策略丢弃 + 不整包 nil）
// ④ blockingPolicies 判据：soclimit==100 不拦 / 非 manual reason 也拦 / terminated 不拦
// ⑤ manualSocLimit 双口径：OBC(90)+manual(85) / manual(90)+OBC(85) / 仅 OBC
// ⑥ detectorError 可观测 + isEmpty 语义钉死（三态 wire 形态断言）
// ⑦ load() Data 注入（成功路径 / 读取失败 → unknown）
// ⑧ 位常量钉死（2^24 / 2^59 防回归；D5 hint-only）
// ⑨ BatterySnapshot.notChargingReason：缺席 nil / 有值提取 / 类型不符容错
// ⑩ powerd 路径常量钉死（D4：daemon 只读 /Library 域）

import CellarCore
import Foundation

/// 原生限充场景域入口（Main.main 调用；全部纯 Data 注入，不触碰真实 plist）。
func runNativeLimitDomainScenarios() throws {
    // ---- fixture 工厂（确定性：NSKeyedArchiver 输出对固定输入确定；真实 powerd
    // 归档同构——/Library/Preferences/com.apple.powerd.charging.plist 实测核对）----

    /// 内层策略归档（NSKeyedArchiver 形态：策略字典经 $objects + NS.keys/NS.objects
    /// UID 间接引用落盘——解析器必须走 UID 解引用全链路）。
    func makeInnerArchive(_ policies: [[String: Any]]) -> Data {
        let array = NSMutableArray()
        for dict in policies { array.add(NSDictionary(dictionary: dict)) }
        // fixture 编码不可达失败（输入全为字面量）；失败即测试栈缺陷，崩溃比静默好。
        return try! NSKeyedArchiver.archivedData(withRootObject: array, requiringSecureCoding: false)
    }

    /// 外层平 plist 包装（{policies: Data}；真实文件另有 bootSessionUUID，解析器不消费）。
    func makeOuterPlist(_ inner: Data) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: ["policies": inner], format: .binary, options: 0)
    }

    /// 整包 Data = 外层包装 + 内层策略归档。
    func makePackage(_ policies: [[String: Any]]) -> Data {
        makeOuterPlist(makeInnerArchive(policies))
    }

    /// CF$UID 包装 fixture（平层字面键字典 + 值为 UID 间接引用——§1「归档内的值
    /// 可能以 CF$UID 包装而非裸 Int/String」的防御场景；构造：种子归档解出真实
    /// CFKeyedArchiverUID 对象 → 平层字典引用 → PropertyListSerialization 重编码）。
    func makeUIDWrappedPackage() -> Data {
        // 种子：三标量数组归档。$objects = [$null, 数组节点, 85, reason, false, 类元数据]，
        // 数组节点 NS.objects = [UID(2)→85, UID(3)→reason, UID(4)→false]（实测布局）。
        let seed = try! NSKeyedArchiver.archivedData(
            withRootObject: [85, "manualChargeLimit", false], requiringSecureCoding: false)
        let seedRoot = try! PropertyListSerialization.propertyList(
            from: seed, options: [], format: nil) as! [String: Any]
        let seedObjects = seedRoot["$objects"] as! [Any]
        let seedNode = seedObjects.first(where: { ($0 as? [String: Any])?["NS.objects"] != nil }) as! [String: Any]
        let refs = seedNode["NS.objects"] as! [Any]
        // 平层策略字典：值全部为 UID 包装（解析器必须解引用才能读到标量）。
        let flat: NSMutableDictionary = [
            "soclimit": refs[0], "reason": refs[1], "terminated": refs[2],
        ]
        // 自定义 $objects 布局与种子 UID 索引对齐：1=策略字典，2/3/4=标量。
        return makeFormBPackage(["$null", flat, 85, "manualChargeLimit", false])
    }

    /// form-B 手工归档（PropertyListSerialization 直编码自定义 $objects——用于
    /// NSKeyedArchiver 不可达的形态：字面键节点、越界 UID 引用、结构性异常节点；
    /// NSKeyedArchiver 会把字面 "NS.keys" 键再归档一层，直编码才能让解析器读到
    /// 原样节点）。
    func makeFormBPackage(_ objects: [Any]) -> Data {
        let root: NSMutableDictionary = [
            "$version": 100_000,
            "$archiver": "NSKeyedArchiver",
            "$top": NSMutableDictionary(),
            "$objects": NSMutableArray(array: objects),
        ]
        let inner = try! PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)
        return makeOuterPlist(inner)
    }

    /// 结构性异常节点族 fixture（全部走解析防御分支：该策略丢弃/跳过 + error
    /// 日志，绝不整包 nil、绝不 crash）：NS.keys/NS.objects 数目不齐 / 键引用
    /// 解析为非字符串 / 值引用越界（字典节点与平层字典两形态）/ terminated 非数值 Bool。
    func makeStructuralAnomalyPackage() -> Data {
        // 越界 UID 种子：12 个互异标量归档（NSKeyedArchiver 对重复标量去重，须互异）
        // → 数组节点 NS.objects[i] = UID(i+2)；refs[10] = UID(12)——自定义 $objects
        // 只有 7 项 → 解析时越界（防御分支：引用越界 → 该键值对/策略丢弃）。
        let bigSeed = try! NSKeyedArchiver.archivedData(
            withRootObject: Array(1...12), requiringSecureCoding: false)
        let bigRoot = try! PropertyListSerialization.propertyList(
            from: bigSeed, options: [], format: nil) as! [String: Any]
        let bigObjects = bigRoot["$objects"] as! [Any]
        let bigNode = bigObjects.first(where: { ($0 as? [String: Any])?["NS.objects"] != nil }) as! [String: Any]
        let outOfBoundsUID = (bigNode["NS.objects"] as! [Any])[10]

        let countMismatch: NSMutableDictionary = ["NS.keys": ["k"], "NS.objects": NSMutableArray()]  // 键值数目不齐 → 节点整体异常
        let badKeyRef: NSMutableDictionary = ["NS.keys": [85], "NS.objects": [85]]      // 键引用解析为非字符串（Int）
        let badValueRef: NSMutableDictionary = ["NS.keys": ["soclimit"], "NS.objects": [outOfBoundsUID]]  // 值引用越界 → 该键值对丢弃
        let oobReason: NSMutableDictionary = ["soclimit": 85, "reason": outOfBoundsUID, "terminated": false]  // 平层字典：reason 值引用越界 → 策略丢弃
        let nonBoolTerminated: NSMutableDictionary = ["soclimit": 85, "reason": "manualChargeLimit", "terminated": 2]  // terminated=2（非 Bool/0/1）→ 策略丢弃
        return makeFormBPackage([
            "$null", countMismatch, badKeyRef, badValueRef, oobReason, nonBoolTerminated,
        ])
    }

    /// 便捷断言：解析结果 == 单条策略。
    func assertSinglePolicy(_ data: Data, socLimit: Int, reason: String, terminated: Bool,
                            _ scenario: String, _ message: String) {
        guard let policies = NativeChargeLimit.parsePolicyArchive(data) else {
            check(false, scenario, "\(message)——但整包解析返回 nil")
            return
        }
        check(policies == [NativeChargePolicy(socLimit: socLimit, reason: reason, terminated: terminated)],
              scenario, message)
    }

    // ---- ① 平层归档解析（方案 §2.2 第一条）----

    // 原生-1：单策略解析（真实归档形态 round-trip——NSKeyedArchiver UID 间接引用
    // 全链路：键与值均经 $objects 解引用；owner/drain 等多余键忽略）。
    do {
        let data = makePackage([
            ["soclimit": 85, "reason": "manualChargeLimit", "terminated": false,
             "owner": 409, "drain": true, "isEndOfCharge": true],
        ])
        assertSinglePolicy(data, socLimit: 85, reason: "manualChargeLimit", terminated: false,
                           "原生-1", "单策略归档解析（soclimit=85/manualChargeLimit/未终止；多余键忽略）")
    }

    // 原生-2：多策略（OBC reason 混入）——全量解析、顺序保真（展示过滤 reason，
    // 守卫不过滤，双口径消费在 ④⑤）。
    do {
        let data = makePackage([
            ["soclimit": 85, "reason": "manualChargeLimit", "terminated": false],
            ["soclimit": 90, "reason": "optimizedBatteryCharging", "terminated": false],
        ])
        let policies = NativeChargeLimit.parsePolicyArchive(data)
        check(policies?.count == 2
                && policies?.first == NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false)
                && policies?.last == NativeChargePolicy(socLimit: 90, reason: "optimizedBatteryCharging", terminated: false),
              "原生-2", "OBC 混入双策略全量解析且顺序保真")
    }

    // 原生-3：terminated 策略解析全量保留（解析不过滤——过滤在消费侧 ④⑤ 验证）。
    do {
        let data = makePackage([["soclimit": 85, "reason": "manualChargeLimit", "terminated": true]])
        assertSinglePolicy(data, socLimit: 85, reason: "manualChargeLimit", terminated: true,
                           "原生-3", "terminated=true 策略解析保留（policies 全量含 terminated，§2.1）")
    }

    // 原生-4：损坏数据（多原子文本串——两种 plist 格式均解析失败）→ nil
    //（整包结构异常 → detectorError 通道；⚠️ 单原子文本串如 "garbage" 会被当作
    // OpenStep 标量成功解析，不构成「损坏」——那类输入走根非字典分支，见原生-5）。
    check(NativeChargeLimit.parsePolicyArchive(Data("not a plist".utf8)) == nil,
          "原生-4", "损坏数据 → nil（整包结构异常，未知态；不 crash 不静默）")

    // 原生-5：内层结构异常变体 → nil（policies 归档损坏 / 外层根非字典 / 内层缺 $objects）。
    do {
        let brokenInner = makeOuterPlist(Data("not a plist".utf8))
        check(NativeChargeLimit.parsePolicyArchive(brokenInner) == nil,
              "原生-5", "policies 归档损坏（不可解析 Data）→ nil")
        let arrayRoot = try! PropertyListSerialization.data(
            fromPropertyList: [1, 2, 3], format: .binary, options: 0)
        check(NativeChargeLimit.parsePolicyArchive(arrayRoot) == nil,
              "原生-5", "外层根非字典（Array plist）→ nil")
        let noObjects = try! PropertyListSerialization.data(
            fromPropertyList: ["policies": try! PropertyListSerialization.data(
                fromPropertyList: ["$archiver": "NSKeyedArchiver"], format: .binary, options: 0)],
            format: .binary, options: 0)
        check(NativeChargeLimit.parsePolicyArchive(noObjects) == nil,
              "原生-5", "内层根缺 $objects 数组 → nil")
    }

    // 原生-6：空 policies → []（正常无策略；与真实文件空态同形——空 NSMutableArray
    // 归档，$objects 仅 $null/类元数据节点，实测核对）。[] ≠ nil：解析成功可区分。
    do {
        let data = makePackage([])
        check(NativeChargeLimit.parsePolicyArchive(data) == [],
              "原生-6", "空 NSMutableArray 归档 → []（正常无策略，非 nil 整包异常）")
    }

    // 原生-7：缺 policies 键 / policies 非 Data → nil（外层缺键 = 整包结构异常）。
    do {
        let missing = try! PropertyListSerialization.data(
            fromPropertyList: ["bootSessionUUID": "uuid-string"], format: .binary, options: 0)
        check(NativeChargeLimit.parsePolicyArchive(missing) == nil,
              "原生-7", "外层缺 policies 键 → nil")
        let wrongType = try! PropertyListSerialization.data(
            fromPropertyList: ["policies": "85"], format: .binary, options: 0)
        check(NativeChargeLimit.parsePolicyArchive(wrongType) == nil,
              "原生-7", "policies 非 Data（String 混入）→ nil")
    }

    // ---- ② CF$UID 包装值解析（方案 §2.2 至少 1 条）----

    // 原生-8：soclimit/reason/terminated 全部 UID 包装 → 正确解出（回归钉死：
    // 无 UID 解包时 as? Int 恒失败 → 策略全丢 → 检测器永久 unknown，§1）。
    do {
        let data = makeUIDWrappedPackage()
        assertSinglePolicy(data, socLimit: 85, reason: "manualChargeLimit", terminated: false,
                           "原生-8", "CF$UID 包装值解包（soclimit=85 经 $objects 间接引用正确解出）")
    }

    // ---- ③ 策略级异常丢弃（不整包 nil、不连累正常策略）----

    // 原生-9：soclimit 非整数（Double/String）/缺 reason/terminated 非 Bool →
    // 该策略丢弃（os_log error 留痕）；缺 soclimit 键 = 非策略节点静默跳过。
    do {
        let mixed = makePackage([
            ["soclimit": 85, "reason": "manualChargeLimit", "terminated": false],
            ["soclimit": 85.5, "reason": "manualChargeLimit", "terminated": false],
            ["soclimit": "85", "reason": "manualChargeLimit", "terminated": false],
        ])
        let policies = NativeChargeLimit.parsePolicyArchive(mixed)
        check(policies?.count == 1 && policies?.first?.socLimit == 85,
              "原生-9", "soclimit 非整数（85.5/\"85\"）→ 仅异常策略丢弃，正常策略保留")

        let missingReason = makePackage([
            ["soclimit": 85, "terminated": false],
        ])
        check(NativeChargeLimit.parsePolicyArchive(missingReason) == [],
              "原生-9", "缺 reason 键 → 策略丢弃（非整包 nil）")

        let badTerminated = makePackage([
            ["soclimit": 85, "reason": "manualChargeLimit", "terminated": "no"],
        ])
        check(NativeChargeLimit.parsePolicyArchive(badTerminated) == [],
              "原生-9", "terminated 非 Bool（String 混入）→ 策略丢弃")

        let noSoclimit = makePackage([
            ["reason": "metadata-like", "terminated": false],
        ])
        check(NativeChargeLimit.parsePolicyArchive(noSoclimit) == [],
              "原生-9", "无 soclimit 键 = 非策略节点（类元数据同形）→ 静默跳过 → []")

        // form-B 手工形态（NSKeyedArchiver 不可达的节点级异常——见 fixture 注记）：
        // 数目不齐 / 键引用非字符串 / 值引用越界 / 平层字典 UID 越界 / terminated=2，
        // 全部策略级丢弃或跳过（各分支 os_log error 留痕），整包仍返回 []。
        check(NativeChargeLimit.parsePolicyArchive(makeStructuralAnomalyPackage()) == [],
              "原生-9", "结构性异常节点族（数目不齐/键引用非串/UID 越界×2/terminated=2）→ 全部丢弃，不整包 nil 不 crash")
    }

    // ---- ④ blockingPolicies 判据（守卫口径：不限 reason，§2.1）----
    // 直接构造 reading（纯消费逻辑与解析解耦）。

    // 原生-10：soclimit==100 不拦（等效关闭；§6 真机走查第 8 项的单元侧锚点）。
    check(NativeChargeLimitReading(policies: [
        NativeChargePolicy(socLimit: 100, reason: "manualChargeLimit", terminated: false),
    ]).blockingPolicies.isEmpty,
      "原生-10", "soclimit==100 → 不拦（等效关闭，soclimit<100 判据）")

    // 原生-11：非 manual reason 也拦（OBC 等系统策略同样卡死 fullOnce——守卫不过滤）。
    check(NativeChargeLimitReading(policies: [
        NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false),
    ]).blockingPolicies.count == 1,
      "原生-11", "OBC reason 策略 → 拦（守卫不限 reason，物理执法事实）")

    // 原生-12：terminated 不拦（注册态已失效）。
    check(NativeChargeLimitReading(policies: [
        NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: true),
    ]).blockingPolicies.isEmpty,
      "原生-12", "terminated=true → 不拦（消费侧过滤，与原生-3 解析保留对照）")

    // ---- ⑤ manualSocLimit 双口径（R2 P1：展示/拒绝文案仅手动策略）----

    // 原生-13：OBC(90)+manual(85) → blocking 最小 85 且 manual=85。
    do {
        let reading = NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 90, reason: "optimizedBatteryCharging", terminated: false),
            NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false),
        ])
        check(reading.blockingPolicies.map(\.socLimit).min() == 85 && reading.manualSocLimit == 85,
              "原生-13", "OBC(90)+manual(85) → blocking.min=85 且 manual=85（双口径一致）")
    }

    // 原生-14：manual(90)+OBC(85) → blocking 最小 85（最先触发者）但 manual=90
    // （用户可操作值——拒绝文案与注记行走 manual 口径）。
    do {
        let reading = NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 90, reason: "manualChargeLimit", terminated: false),
            NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false),
        ])
        check(reading.blockingPolicies.map(\.socLimit).min() == 85 && reading.manualSocLimit == 90,
              "原生-14", "manual(90)+OBC(85) → blocking.min=85、manual=90（双口径分流）")
    }

    // 原生-15：仅 OBC → manualSocLimit=nil（blocking 非空——「系统设置」文案不适用）。
    do {
        let reading = NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false),
        ])
        check(!reading.blockingPolicies.isEmpty && reading.manualSocLimit == nil,
              "原生-15", "仅 OBC → manualSocLimit=nil 且 blocking 非空（通用文案口径）")
    }

    // 原生-28：manual(100)+OBC(85) 混合（review P3-1）→ manualSocLimit=nil
    // （100 = 等效关闭，<100 过滤与 blockingPolicies 同尺——注记行不得以 100
    // 为主语，实际阻断者是 OBC 85，按钮走通用文案口径）。
    do {
        let reading = NativeChargeLimitReading(policies: [
            NativeChargePolicy(socLimit: 100, reason: "manualChargeLimit", terminated: false),
            NativeChargePolicy(socLimit: 85, reason: "optimizedBatteryCharging", terminated: false),
        ])
        check(reading.blockingPolicies.map(\.socLimit).min() == 85 && reading.manualSocLimit == nil,
              "原生-28", "manual(100)+OBC(85) → manualSocLimit=nil ∧ blocking.min=85（P3-1 同尺过滤）")
    }

    // ---- ⑥ detectorError 可观测 + isEmpty 语义钉死（三态 wire 形态断言）----

    // 原生-16：损坏 Data → load → detectorError=true 且 isEmpty=false（未知态永不
    // 伪装「正常空」；M2 wire known=false 映射的自然形态：blocking 空、manual nil）。
    do {
        let reading = NativeChargeLimit.load(rooted: Data("corrupted".utf8))
        check(reading.detectorError && !reading.isEmpty && reading.policies.isEmpty
                && reading.blockingPolicies.isEmpty && reading.manualSocLimit == nil,
              "原生-16", "损坏数据 → detectorError=true ∧ isEmpty=false ∧ 三口径全空（unknown 态形态钉死）")
    }

    // 原生-17：isEmpty ≡ policies.isEmpty && !detectorError（成功空 = true/false；
    // 成功非空 = false/false——「非空数组误判」回归钉死）。
    do {
        let empty = NativeChargeLimit.load(rooted: makePackage([]))
        check(!empty.detectorError && empty.isEmpty,
              "原生-17", "成功空 → isEmpty=true 且 detectorError=false")
        let active = NativeChargeLimit.load(rooted: makePackage(
            [["soclimit": 85, "reason": "manualChargeLimit", "terminated": false]]))
        check(!active.detectorError && !active.isEmpty && active.blockingPolicies.count == 1,
              "原生-17", "成功非空（活跃）→ isEmpty=false 且 blocking 非空（active 态形态）")
        let terminatedOnly = NativeChargeLimit.load(rooted: makePackage(
            [["soclimit": 85, "reason": "manualChargeLimit", "terminated": true]]))
        check(terminatedOnly.policies.count == 1 && terminatedOnly.blockingPolicies.isEmpty
                && !terminatedOnly.isEmpty,
              "原生-17", "仅 terminated 策略 → policies 非空故 isEmpty=false（≠「无策略」，字面义区分）")
    }

    // ---- ⑦ load() Data 注入（thin I/O 封装面）----

    // 原生-18：成功路径 reading 与 parse 对齐；读取失败（注入 throwing 表达式）→
    // detectorError=true（I/O 故障与解析故障同归 unknown，§3.1 fail-open 前提）。
    do {
        let package = makePackage([["soclimit": 85, "reason": "manualChargeLimit", "terminated": false]])
        let reading = NativeChargeLimit.load(rooted: package)
        check(reading == NativeChargeLimitReading(
                policies: [NativeChargePolicy(socLimit: 85, reason: "manualChargeLimit", terminated: false)],
                detectorError: false),
              "原生-18", "load(Data 注入) 成功路径 == parse 结果（thin 封装不变形）")
        struct InjectedReadError: Error {}
        func throwingRead() throws -> Data { throw InjectedReadError() }
        let failed = NativeChargeLimit.load(rooted: try throwingRead())
        check(failed.detectorError && !failed.isEmpty,
              "原生-18", "读取失败（throwing 注入）→ detectorError=true（I/O 故障同归 unknown）")
    }

    // ---- ⑧ 位常量钉死（D5 hint-only 防回归）----

    // 原生-19：reasonNativeHold=2^24 / reasonSmcInhibit=2^59 字节形态钉死
    // （本机实测值；位语义漂移由 D5 hint-only 兜底，常量漂移此处立刻红）。
    // ⚠️ 十六进制形态核对：2^59 = 0x0800_0000_0000_0000（8 在第二位，前导零）——
    // 0x8000_0000_0000_0000（8 在第一位）是 2^63，非 2^59；十进制值双重钉死防誊写。
    check(NativeChargeLimit.reasonNativeHold == 0x1000000
            && NativeChargeLimit.reasonSmcInhibit == 0x0800_0000_0000_0000
            && NativeChargeLimit.reasonSmcInhibit == 576_460_752_303_423_488,
          "原生-19", "位常量钉死：2^24=0x1000000、2^59=0x0800_0000_0000_0000=576460752303423488（UInt64 全域）")

    // ---- ⑨ BatterySnapshot.notChargingReason（缺席保持 nil 模式）----

    // 原生-20：缺席 → nil（既有 fixture 无 ChargerData 键——存量场景零回归）。
    do {
        let snapshot = try BatterySnapshotParser.parse(batteryProps(), timestamp: Date(timeIntervalSince1970: 0))
        check(snapshot.notChargingReason == nil,
              "原生-20", "ChargerData 缺席 → notChargingReason=nil（缺席保持，其余字段不受影响）")
    }

    // 原生-21：有值提取（UInt64 全域按位保留）+ 类型不符容错。
    do {
        var props = batteryProps()
        props["ChargerData"] = ["NotChargingReason": NSNumber(value: UInt64(1) << 59)] as [String: Any]
        let smcInhibit = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 0))
        check(smcInhibit.notChargingReason == NativeChargeLimit.reasonSmcInhibit,
              "原生-21", "NotChargingReason=2^59 → 原值提取（== reasonSmcInhibit，位集按位保留）")
        props["ChargerData"] = ["NotChargingReason": NSNumber(value: UInt64(1) << 24)] as [String: Any]
        let nativeHold = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 0))
        check(nativeHold.notChargingReason == NativeChargeLimit.reasonNativeHold,
              "原生-21", "NotChargingReason=2^24 → 原值提取（== reasonNativeHold）")
        props["ChargerData"] = ["NotChargingReason": UInt64.max] as [String: Any]
        let allBits = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 0))
        check(allBits.notChargingReason == UInt64.max,
              "原生-21", "UInt64.max → 全域保留（位 63 置位不回绕——位集必须 UInt64 口径）")
        props["ChargerData"] = ["NotChargingReason": "0"] as [String: Any]
        let badType = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 0))
        check(badType.notChargingReason == nil,
              "原生-21", "NotChargingReason 类型不符（String）→ nil 容错")
        props["ChargerData"] = [:] as [String: Any]
        let emptyDict = try BatterySnapshotParser.parse(props, timestamp: Date(timeIntervalSince1970: 0))
        check(emptyDict.notChargingReason == nil,
              "原生-21", "ChargerData 空字典 → nil（键缺席容错）")
    }

    // ---- ⑩ powerd 路径常量钉死（D4：daemon 只读 /Library 域）----

    // 原生-22：daemon 侧唯一读取路径（§2.1/D4——用户域 UI 镜像不归 daemon；M2 接线
    // 与 doctor 检查共同依赖此路径，漂移即越域）。
    check(NativeChargeLimit.powerdPoliciesURL.path == "/Library/Preferences/com.apple.powerd.charging.plist",
          "原生-22", "powerdPoliciesURL 钉死 /Library 域（daemon 只读惯例，D4）")
}
