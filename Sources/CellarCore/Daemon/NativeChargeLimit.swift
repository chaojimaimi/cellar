import Foundation
import os

// MARK: - Phase 5 v1.7 原生限充检测器（M1，方案 §2.1）—— CellarCore 纯函数/纯值层
//
// 事实源（docs/SMC-NOTES.md §5 spike 实测，Mac14,6 / macOS 26.6.2）：原生限充是
// powerd 软件策略（非 SMC 固件键），注册态持久化在 /Library/Preferences/
// com.apple.powerd.charging.plist：外层平 plist {bootSessionUUID, policies: Data}，
// 内层 NSKeyedArchiver 归档，$objects 数组中筛「dict 且含 soclimit 键」得策略对象。
// ⚠️ 归档内键/值以 CF$UID 间接引用（实测 __NSCFType / CFKeyedArchiverUID 包装，
// `as? Int` 恒 nil——直接读标量会让 soclimit 恒判「非整数」→ 检测器永久 unknown），
// 解析必须显式解引用（resolved）。
// 本文件只读不写（红线 §5.2）：禁写 powerd 域、禁发私有 XPC；解析层只吃 Data
//（纯函数，测试全走 Data 注入）。

/// 单条原生策略（注册态）。
public struct NativeChargePolicy: Equatable, Sendable {
    /// 策略充电上限（soclimit；系统五档 80/85/90/95/100）。
    public var socLimit: Int
    /// 策略原因（reason；实测 "manualChargeLimit"=用户手动限充，OBC 优化充电等
    /// 系统 reason 亦可能混入——展示过滤 reason，守卫不过滤，方案 §2.1 口径分工）。
    public var reason: String
    /// 是否已终止（terminated；true = 注册态已失效不再阻断。解析全量保留，
    /// 过滤在 blockingPolicies/manualSocLimit 消费侧）。
    public var terminated: Bool

    public init(socLimit: Int, reason: String, terminated: Bool) {
        self.socLimit = socLimit
        self.reason = reason
        self.terminated = terminated
    }
}

/// 检测结果——三态显式建模（unknown / 无阻断策略 / 有阻断策略），
/// 解析失败与「确实无策略」可区分（R1 P2）。
public struct NativeChargeLimitReading: Equatable, Sendable {
    /// 解析成功时全量（含 terminated）；未知态（detectorError=true）为空数组。
    public var policies: [NativeChargePolicy]
    /// true = 读取/解析失败（未知态；os_log error 已留痕——永不 crash 永不静默）。
    public var detectorError: Bool

    public init(policies: [NativeChargePolicy] = [], detectorError: Bool = false) {
        self.policies = policies
        self.detectorError = detectorError
    }

    /// isEmpty ≡ 检测成功且无策略（policies.isEmpty && !detectorError，≠
    /// policies.isEmpty 字面义——未知态恒 false，R1 P2 isEmpty 语义钉死）。
    public var isEmpty: Bool { policies.isEmpty && !detectorError }

    /// 守卫判据（§3.1）：不限 reason——任何未终止且 <100 的策略都会卡死 fullOnce
    /// （soclimit==100 = 等效关闭不拦；多阻断取最小 soclimit 交 wire 层）。
    public var blockingPolicies: [NativeChargePolicy] {
        policies.filter { !$0.terminated && $0.socLimit < 100 }
    }

    /// 展示过滤：reason == "manualChargeLimit" 的未终止且 <100 策略最小 soclimit
    /// （无则 nil；<100 过滤与 blockingPolicies 同尺——review P3-1：manual(100)=
    /// 等效关闭不得成为注记行主语，manual(100)+OBC(85) 混合下展示 100 属张冠
    /// 李戴，实际阻断者是 OBC 85）。仅手动策略可被用户操作（「请先在系统设置
    /// 中关闭」只对手动限充成立，R2 P1）。
    public var manualSocLimit: Int? {
        policies.filter {
            !$0.terminated && $0.socLimit < 100 && $0.reason == "manualChargeLimit"
        }
        .map(\.socLimit).min()
    }
}

public enum NativeChargeLimit {
    /// 日志（enum 静态成员非隔离；Logger Sendable，跨隔离界安全——ActionStore 同款）。
    private nonisolated static let log = Logger(subsystem: "com.cellar", category: "nativelimit")

    /// daemon 侧唯一读取：/Library/Preferences/com.apple.powerd.charging.plist
    /// （0644 root 可读；用户域 UI 镜像不归 daemon——D4「daemon 只碰 /Library 域」）。
    public static var powerdPoliciesURL: URL {
        URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
    }

    /// NotChargingReason 位（D5：hint-only，本机实测，跨机型/版本不保证——仅作展示
    /// hint 与 doctor 参考，不作行为判据）：powerd 原生限充持有（2^24）。
    public static let reasonNativeHold: UInt64 = 1 << 24
    /// Cellar CHTE 抑制位（2^59）。
    public static let reasonSmcInhibit: UInt64 = 1 << 59

    /// M2 wire 映射（方案 §3.2 三态钉死，形态被场景 原生-16/17 + 原生-23..24 消费）：
    /// - detectorError → `known:false, active:false` 双 socLimit=nil（未知态形态固定）；
    /// - 正常 → known:true，active=blockingPolicies 非空（守卫口径，物理执法事实），
    ///   socLimit=blocking 最小（active 时——最先触发者），manualSocLimit=manual 过滤
    ///   最小（R2 P1 展示口径，nil 可）；
    /// - active=false（known=true）⇒ 双 socLimit 恒 nil——App 无需猜测（多策略组合
    ///   下 manual 口径可能在 blocking 为空时仍非 nil，本映射统一收敛为 nil）。
    public static func wireStatus(_ reading: NativeChargeLimitReading) -> NativeLimitStatus {
        guard !reading.detectorError else {
            return NativeLimitStatus(known: false, active: false, socLimit: nil, manualSocLimit: nil)
        }
        let blocking = reading.blockingPolicies
        guard !blocking.isEmpty else {
            return NativeLimitStatus(known: true, active: false, socLimit: nil, manualSocLimit: nil)
        }
        return NativeLimitStatus(
            known: true,
            active: true,
            socLimit: blocking.map(\.socLimit).min(),
            manualSocLimit: reading.manualSocLimit
        )
    }

    /// daemon 侧唯一读取入口（thin I/O 封装——文件字节由调用方注入便于测试；M2
    /// 接线形态 `NativeChargeLimit.load(rooted: try Data(contentsOf: powerdPoliciesURL))`）。
    ///
    /// 读取失败 / 整包解析失败 → detectorError=true（未知态：policies 空、isEmpty
    /// false——三态归 unknown，fail-open 决策在 §3.1 守卫侧，不在本层降级猜测）。
    public static func load(rooted: @autoclosure () throws -> Data) -> NativeChargeLimitReading {
        let payload: Data
        do {
            payload = try rooted()
        } catch {
            log.error("原生限充：策略包读取失败（\(error.localizedDescription, privacy: .public)）")
            return NativeChargeLimitReading(policies: [], detectorError: true)
        }
        guard let policies = parsePolicyArchive(payload) else {
            return NativeChargeLimitReading(policies: [], detectorError: true)
        }
        return NativeChargeLimitReading(policies: policies, detectorError: false)
    }

    /// 解析 powerd charging plist 整包（外层平 plist + 内层 NSKeyedArchiver 归档）。
    ///
    /// 解析防御（方案 §2.1）：整包结构异常（外层缺键/非 plist/内层非归档）→ nil
    /// → 上层 detectorError=true；策略级异常（soclimit 非整数/键缺失）→ 该策略
    /// 丢弃 + os_log error——未知态永不 crash 永不静默。
    ///
    /// - Parameter data: 整包文件原始字节（纯函数入口，测试全走 Data 注入）。
    /// - Returns: 策略全数组（含 terminated）；`[]` = 正常无策略；`nil` = 整包结构异常。
    public static func parsePolicyArchive(_ data: Data) -> [NativeChargePolicy]? {
        // ① 外层平 plist：{bootSessionUUID: String, policies: Data}（§1 实测；
        //    bootSessionUUID 本检测器不消费——注册态跨启动取舍属守卫口径，非解析职责）。
        let outer: Any
        do {
            outer = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            log.error("原生限充：外层 plist 不可解析（\(error.localizedDescription, privacy: .public)）")
            return nil
        }
        guard let outerDict = outer as? [String: Any] else {
            log.error("原生限充：外层根非字典（形态 \(formSummary(outer), privacy: .public)）")
            return nil
        }
        guard let archiveData = outerDict[Keys.policies] as? Data else {
            log.error("原生限充：外层缺 policies 键或非 Data（形态 \(formSummary(outerDict[Keys.policies] as Any), privacy: .public)）")
            return nil
        }
        // ② 内层 NSKeyedArchiver（bplist00，$objects 数组——§1 实测）。
        let inner: Any
        do {
            inner = try PropertyListSerialization.propertyList(from: archiveData, options: [], format: nil)
        } catch {
            log.error("原生限充：内层归档不可解析（\(error.localizedDescription, privacy: .public)）")
            return nil
        }
        guard let root = inner as? [String: Any] else {
            log.error("原生限充：内层根非字典（形态 \(formSummary(inner), privacy: .public)）")
            return nil
        }
        guard let objects = root[Keys.objects] as? [Any] else {
            log.error("原生限充：内层缺 $objects 数组（形态 \(formSummary(root), privacy: .public)）")
            return nil
        }
        // ③ 遍历 $objects 筛「dict 且含 soclimit 键」：类元数据/$null 节点静默跳过；
        //    策略级结构异常在 policy(from:) 内丢弃 + error 日志。
        var policies: [NativeChargePolicy] = []
        policies.reserveCapacity(objects.count)
        for element in objects {
            if let policy = policy(from: element, objects: objects) {
                policies.append(policy)
            }
        }
        return policies
    }

    // MARK: - 解析内部（键名/形态常量与防御 helpers）

    /// plist 键名与归档结构键（实测钉死——§1；改动即形态漂移）。
    private enum Keys {
        /// 外层平 plist 的策略归档 Data 键。
        static let policies = "policies"
        /// NSKeyedArchiver 对象数组键。
        static let objects = "$objects"
        /// 归档字典节点的键引用数组。
        static let archiveKeys = "NS.keys"
        /// 归档字典节点的值引用数组。
        static let archiveObjects = "NS.objects"
        /// 策略上限键（策略对象识别锚——§1「筛 dict 且含 soclimit 键」）。
        static let socLimit = "soclimit"
        static let reason = "reason"
        static let terminated = "terminated"
    }

    /// 单个 $objects 元素 → 策略。nil = 非策略对象（$null/类元数据，静默跳过）
    /// 或策略级异常（丢弃并已记 error 日志）。
    private static func policy(from element: Any, objects: [Any]) -> NativeChargePolicy? {
        guard let pairs = pairs(from: element, objects: objects) else { return nil }
        // 无 soclimit 键 = 非策略对象（$classes/$classname 元数据、空 NSMutableArray 节点等）。
        guard let socRef = pairs[Keys.socLimit] else { return nil }
        guard let socValue = resolved(socRef, objects: objects), let socLimit = socValue as? Int else {
            log.error("原生限充：soclimit 非整数，策略丢弃（形态 \(formSummary(socRef), privacy: .public)）")
            return nil
        }
        guard let reasonRef = pairs[Keys.reason],
              let reason = resolved(reasonRef, objects: objects) as? String else {
            log.error("原生限充：reason 缺失或非字符串，策略丢弃（soclimit=\(socLimit, privacy: .public)）")
            return nil
        }
        guard let terminatedRef = pairs[Keys.terminated],
              let terminatedValue = resolved(terminatedRef, objects: objects),
              let terminated = boolValue(terminatedValue) else {
            log.error("原生限充：terminated 缺失或非 Bool，策略丢弃（soclimit=\(socLimit, privacy: .public)）")
            return nil
        }
        return NativeChargePolicy(socLimit: socLimit, reason: reason, terminated: terminated)
    }

    /// 字典元素 → 键值对（两种形态，均实测——§1/probe）：
    /// - NSKeyedArchiver 字典节点：NS.keys/NS.objects 各为 UID 引用数组——键值逐对解引用；
    /// - 平层字面键字典：键为裸 String，值可能是 UID 引用（由 resolved 统一解包）。
    /// 非字典（$null/标量）→ nil。
    private static func pairs(from element: Any, objects: [Any]) -> [String: Any]? {
        guard let dict = element as? [String: Any] else { return nil }
        guard let keyRefs = dict[Keys.archiveKeys] as? [Any],
              let valueRefs = dict[Keys.archiveObjects] as? [Any] else {
            return dict
        }
        guard keyRefs.count == valueRefs.count else {
            log.error("原生限充：字典节点 NS.keys/NS.objects 数目不齐（\(keyRefs.count, privacy: .public)/\(valueRefs.count, privacy: .public)）")
            return nil
        }
        var result: [String: Any] = [:]
        result.reserveCapacity(keyRefs.count)
        for (keyRef, valueRef) in zip(keyRefs, valueRefs) {
            guard let key = resolved(keyRef, objects: objects) as? String else {
                log.error("原生限充：字典节点键引用不可解析（形态 \(formSummary(keyRef), privacy: .public)）")
                continue
            }
            guard let value = resolved(valueRef, objects: objects) else {
                log.error("原生限充：字典节点值引用不可解析（键 \(key, privacy: .public)）")
                continue
            }
            result[key] = value
        }
        return result
    }

    /// UID 解包（§1 关键防御）：CFKeyedArchiverUID 形态（实测 __NSCFType 包装，
    /// `as? Int` 恒 nil）→ 从 CF description 提取 {value = N} → 间接引用 $objects[N]；
    /// 直接形态原样返回；不可解析 → nil（调用方按结构异常处置）。
    private static func resolved(_ value: Any, objects: [Any]) -> Any? {
        // 直接形态：标量（NSNumber 含 Bool 桥接）/字符串/容器/数据/日期——非引用。
        if value is NSNumber || value is String || value is [String: Any] || value is [Any]
            || value is Data || value is Date {
            return value
        }
        guard let index = uidIndex(value) else {
            log.error("原生限充：UID 引用不可解析（形态 \(formSummary(value), privacy: .public)）")
            return nil
        }
        guard objects.indices.contains(index) else {
            log.error("原生限充：UID 引用越界 index=\(index, privacy: .public)（objects=\(objects.count, privacy: .public)）")
            return nil
        }
        return objects[index]
    }

    /// CFKeyedArchiverUID 数值提取。公开 API 无 UID 数值读取面（实测非 NSNumber、
    /// CFTypeID ≠ CFNumberGetTypeID）；description 形态 `<CFKeyedArchiverUID 0x…>
    /// {value = N}` 实测稳定——提取失败 = 形态漂移，按结构异常处置（不猜不崩）。
    private static func uidIndex(_ value: Any) -> Int? {
        let description = String(describing: value as AnyObject)
        guard let marker = description.range(of: "{value = ") else { return nil }
        let digits = description[marker.upperBound...].prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Bool 值域（照 BatterySnapshotParser.boolValue / 评审 B-5 同一把尺：Bool 直收；
    /// NSNumber 仅接受 0/1——禁止 boolValue 对非零一律 true 的桥接行为）。
    private static func boolValue(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber else { return nil }
        if number.uint64Value == 0 { return false }
        if number.uint64Value == 1 { return true }
        return nil
    }

    /// 原始形态摘要（os_log error 附带——类型名 + 截断描述，不吐全量归档内容；
    /// 可诊断性优先：形态漂移必须留痕，勿静默吞掉，方案 §2.1）。
    private static func formSummary(_ value: Any) -> String {
        let description = String(describing: value as AnyObject)
        let truncated = description.count > 120 ? description.prefix(120) + "…" : description
        return "\(type(of: value))(\(truncated))"
    }
}
