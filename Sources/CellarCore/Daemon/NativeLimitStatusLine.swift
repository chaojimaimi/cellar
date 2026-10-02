import Foundation

// MARK: - 0.20.2 §1.3 status CLI「原生限充」行语义统一（方案 §1.3）
//
// 动机（0.20.2 部署验证实测）：topoff active（域 75 在位）时 status 行显示
// 「未注册」——语义误导。门控同 §1.2（sub80 capable ∧ sub80State == .active →
// 「现行执法（上限 N%）」；N = daemon 上报 upperLimit——0.20.1 enforcingLimit 门
// 同款词汇）；否则原注册态检测文案。纯展示层（sub80State wire 可达，零 wire）。
//
// 决策纯函数进 CellarCore（项目模式）：printNativeLine 是 CLI 私有渲染不可直测，
// 行文案/门控判定经本枚举下沉 CellarCoreCheck 场景域钉死；CLI 只消费渲染。

/// status CLI「原生限充」行决策（NativeLimitStatusLine.resolve → lineText 直印）。
public enum NativeLimitStatusLine: Equatable, Sendable {
    /// 旧 daemon 未上报 nativeLimit（升级提示）。
    case legacyDaemon
    /// 检测未知（CLI 侧策略文件读取/解析失败）。
    case unknown
    /// 未注册（无阻断策略）。
    case unregistered
    /// N% 注册（守卫口径 blocking 最小值；CLI 附加用户域 UI 镜像行）。
    case registered(socLimit: Int)
    /// 0.20.2 §1.3：topoff 通道承载中 → 现行执法（N = daemon 上报 upperLimit）。
    case topoffEnforcing(limit: Int)

    /// 行决策（§1.3 门控钉死）：sub80 capable ∧ sub80State == .active →
    /// topoffEnforcing（优先于注册态检测——域值在位时「未注册」误导；旧 daemon
    /// 无 sub80State/capabilities 天然不触发，既有语义零回归）；否则按既有三态
    /// 检测文案（legacy / unknown / 未注册 / 注册）。
    public static func resolve(_ status: DaemonStatus) -> NativeLimitStatusLine {
        if status.sub80State == .active,
           status.capabilities?.contains(DaemonXPC.capabilitySub80) == true {
            return .topoffEnforcing(limit: status.upperLimit)
        }
        guard let native = status.nativeLimit else { return .legacyDaemon }
        guard native.known else { return .unknown }
        guard native.active, let socLimit = native.socLimit else { return .unregistered }
        return .registered(socLimit: socLimit)
    }

    /// 行完整文案（含「原生限充：」前缀——CLI 直印；CLI 输出恒中文，既有惯例）。
    public var lineText: String {
        switch self {
        case .legacyDaemon:
            return "原生限充：旧版守护进程未上报（升级后可查看）"
        case .unknown:
            return "原生限充：检测未知（策略文件读取失败）"
        case .unregistered:
            return "原生限充：未注册"
        case .registered(let socLimit):
            return "原生限充：\(socLimit)% 注册"
        case .topoffEnforcing(let limit):
            return "原生限充：现行执法（上限 \(limit)%，topoff 通道）"
        }
    }

    /// 注册态形态下附加用户域 UI 镜像行（CLI printNativeMirrorLine 消费——用户域
    /// 读取只能在 CLI 用户态执行，不进决策面）。
    public var showsUserMirror: Bool {
        if case .registered = self { return true }
        return false
    }
}
