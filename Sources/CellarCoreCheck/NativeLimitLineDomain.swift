// CellarCoreCheck —— 0.20.2 §1.3 status CLI「原生限充」行语义统一场景域（方案 §1.3）
//
// 决策纯函数进 CellarCore（项目模式）：printNativeLine 是 CLI 私有渲染不可直测，
// 行文案/门控判定经 NativeLimitStatusLine.resolve 下沉本域钉死。覆盖：
// ①门控主臂：sub80 capable ∧ sub80State == .active → topoffEnforcing（N = daemon
//   上报 upperLimit——0.20.1 enforcingLimit 门同款词汇）
// ②门控负臂：sub80 缺席 / capabilities 不含 sub80 / degraded / off → 既有三态检测
//   文案零回归（26 语义锚）
// ③既有三态：legacy / unknown / 未注册 / 注册（+ 镜像行旗标）
// ④优先序：门控先于注册态检测（域 75 在位 ∧ 未注册 → 现行执法——实测误导场景修复）

import CellarCore
import Foundation

/// 0.20.2 §1.3 场景域入口（Main.main 调用；全部纯函数——DaemonStatus 直构）。
func runNativeLimitLineDomainScenarios() {
    /// 基底 daemonStatus（active 75——topoff 执法语境）。
    func status(
        upperLimit: Int = 75,
        capabilities: [String]? = nil,
        sub80State: Sub80State? = nil,
        nativeLimit: NativeLimitStatus? = nil
    ) -> DaemonStatus {
        DaemonStatus(
            version: "0.20.1-alpha", mode: "active", upperLimit: upperLimit, hysteresis: 2,
            capabilities: capabilities, nativeLimit: nativeLimit, sub80State: sub80State
        )
    }
    let registered85 = NativeLimitStatus(known: true, active: true, socLimit: 85, manualSocLimit: 85)
    let unregistered = NativeLimitStatus(known: true, active: false, socLimit: nil, manualSocLimit: nil)
    let unknown = NativeLimitStatus(known: false, active: false, socLimit: nil, manualSocLimit: nil)
    let sub80Capable = [DaemonXPC.capabilityOrchestration, DaemonXPC.capabilitySub80]

    // ---- ①门控主臂（topoff active → 现行执法）----

    // 行-1：sub80 capable ∧ active → 「现行执法（上限 N%，topoff 通道）」（N =
    // daemon 上报 upperLimit，与注册残留值无关）。
    do {
        let enforcing = NativeLimitStatusLine.resolve(status(
            capabilities: sub80Capable, sub80State: .active, nativeLimit: registered85
        ))
        check(enforcing == .topoffEnforcing(limit: 75)
                && enforcing.lineText == "原生限充：现行执法（上限 75%，topoff 通道）"
                && !enforcing.showsUserMirror,
              "行-1", "topoff active → 现行执法文案（N=upperLimit 75 与残留 85 无关；不附加镜像行）")
        let enforcing60 = NativeLimitStatusLine.resolve(status(
            upperLimit: 60, capabilities: [DaemonXPC.capabilitySub80], sub80State: .active,
            nativeLimit: unregistered
        ))
        check(enforcing60 == .topoffEnforcing(limit: 60)
                && enforcing60.lineText.contains("上限 60%"),
              "行-1", "N 取 upperLimit 现值（60 地板上限——门控文案随策略）")
    }

    // ---- ②门控负臂（既有语义零回归——26 语义锚）----

    // 行-2：sub80State 缺席（26 / 旧 daemon）/ capabilities 不含 sub80 / degraded /
    // off → 不触发门控，落既有检测分支。
    do {
        check(NativeLimitStatusLine.resolve(status(sub80State: .active)) == .legacyDaemon,
              "行-2", "sub80State active 但 capabilities 缺席（旧 daemon 形态）→ 不触发门控（capabilities 双门）")
        check(NativeLimitStatusLine.resolve(status(capabilities: [DaemonXPC.capabilityDischarge], sub80State: .active)) == .legacyDaemon,
              "行-2", "capabilities 不含 sub80 ∧ active → 不触发门控（26 终态语义——capabilities 单门）")
        let degraded = NativeLimitStatusLine.resolve(status(
            capabilities: sub80Capable, sub80State: .degraded, nativeLimit: registered85
        ))
        check(degraded == .registered(socLimit: 85),
              "行-2", "degraded 降级稳态 → 不触发门控（编排钳 80 接管——注册残留检测照常）")
        let off = NativeLimitStatusLine.resolve(status(
            capabilities: sub80Capable, sub80State: .off, nativeLimit: unregistered
        ))
        check(off == .unregistered,
              "行-2", "off 关断态 → 不触发门控（域随写 100 无执法——未注册文案）")
    }

    // ---- ③既有三态文案（零回归）----

    // 行-3：legacy / unknown / 未注册 / 注册 + 镜像行旗标。
    do {
        check(NativeLimitStatusLine.resolve(status()) == .legacyDaemon
                && NativeLimitStatusLine.resolve(status()).lineText == "原生限充：旧版守护进程未上报（升级后可查看）",
              "行-3", "nativeLimit 缺席（旧 daemon）→ 升级提示文案")
        check(NativeLimitStatusLine.resolve(status(nativeLimit: unknown)) == .unknown
                && NativeLimitStatusLine.resolve(status(nativeLimit: unknown)).lineText == "原生限充：检测未知（策略文件读取失败）",
              "行-3", "known=false → 检测未知文案")
        check(NativeLimitStatusLine.resolve(status(nativeLimit: unregistered)) == .unregistered
                && NativeLimitStatusLine.resolve(status(nativeLimit: unregistered)).lineText == "原生限充：未注册",
              "行-3", "无阻断策略 → 未注册文案")
        let registered = NativeLimitStatusLine.resolve(status(nativeLimit: registered85))
        check(registered == .registered(socLimit: 85)
                && registered.lineText == "原生限充：85% 注册"
                && registered.showsUserMirror,
              "行-3", "注册态 → N% 注册文案 + 用户域镜像行旗标（printNativeMirrorLine 消费）")
    }

    // ---- ④优先序（实测误导场景修复钉死）----

    // 行-4：topoff active ∧ 原生未注册（0.20.2 部署验证实测形态——域 75 在位显示
    // 「未注册」误导）→ 门控先于未注册判定 → 现行执法。
    do {
        let misleading = status(capabilities: sub80Capable, sub80State: .active,
                                nativeLimit: unregistered)
        check(NativeLimitStatusLine.resolve(misleading) == .topoffEnforcing(limit: 75),
              "行-4", "topoff active ∧ 未注册 → 现行执法（门控先于注册态检测——域值在位即执法事实）")
        let wireRoundTrip: DaemonStatus = {
            var s = misleading
            s.sub80State = .active
            s.capabilities = sub80Capable
            return s
        }()
        check(NativeLimitStatusLine.resolve(wireRoundTrip) == .topoffEnforcing(limit: 75),
              "行-4", "wire 字段直构（sub80State/capabilities 与 daemon getStatus 同源形态）→ 判定一致")
    }
}
