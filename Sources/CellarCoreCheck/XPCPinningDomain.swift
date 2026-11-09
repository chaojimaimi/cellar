// CellarCoreCheck —— 0.23.13「B6 XPC 客户端身份钉扎批」场景域（方案 §2.4）
//
// 随批分 commit 递增（先例照 SecurityHardeningDomain 纵深段）：
// - commit 1（本文件初版）：钉扎-1..7 判定矩阵直测 + 钉扎-8..12 锚点派生直测
//   ——纯函数面（DaemonRegistration.swift 邻位新增判定层），零 SecCode/零进程/
//   零网络/不触碰真实 plist；
// - commit 2（B6-2）：钉扎-13..17+ 源钉（authorize 序钉/getStatus 零触及/
//   fail-closed 注记与专属错误消息字面量/bundle ID 常量对 pbxproj 一致性/
//   行为零变化反钉）；
// - commit 3（B6-3）：钉扎-18 hardened 源钉（pbxproj ENABLE_HARDENED_RUNTIME）。

import CellarCore
import Foundation

/// 0.23.13 B6 批场景域入口（Main.main 调用）。
func runXPCPinningDomainScenarios() {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Sources/CellarCoreCheck
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // 仓库根
    func source(_ relativePath: String) -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // 源文件缺席 = 钉面失效（checkout 残缺/文件被改名）——fail 红而非静默绿。
            check(false, "钉扎-0", "源文件读取失败：\(relativePath)（结构钉面依赖仓库布局）")
            return ""
        }
        return text
    }

    // ---- 钉扎-1..7：身份判定矩阵直测（方案 §2.1 判定序，deny reason 逐字面钉）----

    let expected = PinnedClientIdentity(
        bundleIdentifier: ClientIdentity.appBundleIdentifier,
        appPath: "/Applications/Cellar.app",
        executablePath: "/Applications/Cellar.app/Contents/MacOS/Cellar")
    let goodFacts = ClientIdentityFacts(
        validityPassed: true,
        identifier: ClientIdentity.appBundleIdentifier,
        executablePath: "/Applications/Cellar.app/Contents/MacOS/Cellar")

    // 钉扎-1：match 全过（三段判定全命中——App-route 真实拓扑形态）。
    expectEqual(evaluateClientIdentity(goodFacts, expected: expected),
                ClientIdentityVerdict.match, "钉扎-1", "validity+identifier+path 全命中 → match")

    // 钉扎-2：路径不符（executablePath ≠ 期望精确路径）→ deny("路径不符")。
    // deny reason 字面量一字不差——路径精确相等是承重墙（同 bundle id 不同路径
    // 即拒：App bundle 移动/改名后 daemon 拒绝直至重装的判定来源）。
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: true,
                                identifier: ClientIdentity.appBundleIdentifier,
                                executablePath: "/Applications/Other.app/Contents/MacOS/Cellar"),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "路径不符"),
        "钉扎-2", "错路径 → deny(路径不符)（同 bundle id 不同路径仍拒）")

    // 钉扎-3：路径缺席（executablePath nil = 提取失败/缺失——诚实缺席）→
    // deny("路径不符")。fail-closed：取证失败绝不静默放行。
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: true,
                                identifier: ClientIdentity.appBundleIdentifier,
                                executablePath: nil),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "路径不符"),
        "钉扎-3", "路径 nil → deny(路径不符)（诚实缺席 fail-closed）")

    // 钉扎-4：标识符不符（错值/nil 皆拒）→ deny("标识符不符")。
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: true,
                                identifier: "com.evil.app",
                                executablePath: expected.executablePath),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "标识符不符"),
        "钉扎-4", "错标识符（复制 bundle id 失败的伪装进程）→ deny(标识符不符)")
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: true,
                                identifier: nil,
                                executablePath: expected.executablePath),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "标识符不符"),
        "钉扎-4", "标识符 nil（未签名/签名信息缺席）→ deny(标识符不符)")

    // 钉扎-5：签名校验未通过（validityPassed false——SecCodeCheckValidity 拒绝）
    // → deny("签名校验未通过")。自洽可伪造面由本臂收口（ad-hoc 无证书身份可钉，
    // 有效签名判定是 identifier requirement 的语义防线）。
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: false,
                                identifier: ClientIdentity.appBundleIdentifier,
                                executablePath: expected.executablePath),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "签名校验未通过"),
        "钉扎-5", "validity false → deny(签名校验未通过)")

    // 钉扎-6：判定序钉——多字段同坏取首个 reason（路径优先于标识符/签名）。
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: false,
                                identifier: "com.evil.app",
                                executablePath: "/evil"),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "路径不符"),
        "钉扎-6", "三字段同坏 → 首个 reason = 路径不符（路径承重墙优先序钉死）")
    expectEqual(
        evaluateClientIdentity(
            ClientIdentityFacts(validityPassed: false,
                                identifier: "com.evil.app",
                                executablePath: expected.executablePath),
            expected: expected),
        ClientIdentityVerdict.deny(reason: "标识符不符"),
        "钉扎-6", "路径命中后标识符/签名同坏 → 首个 reason = 标识符不符（标识符先于签名）")

    // 钉扎-7：legacy 模式不构成本判定（类型面断言）——evaluateClientIdentity 的
    // expected 参数为**非可选** PinnedClientIdentity：无锚（CLI-route）形态无从
    // 构造期望身份，判定路径对其不存在（daemon 侧 .legacy 分支维持既有 admin 门，
    // 行为零变化）。签名逐字面钉（非可选类型即类型系统级事实）。
    let registrationSrc = source("Sources/CellarCore/Daemon/DaemonRegistration.swift")
    check(registrationSrc.contains("public func evaluateClientIdentity(_ facts: ClientIdentityFacts, expected: PinnedClientIdentity) -> ClientIdentityVerdict"),
          "钉扎-7", "签名 expected 非可选 PinnedClientIdentity（类型面：legacy 形态无判定路径）")

    // ---- 钉扎-8..12：锚点派生直测（方案 §2.1 形态矩阵，两条守卫独立归因）----

    // 钉扎-8：App-route 四层形态 → App bundle 锚点（真机部署实测路径形态）。
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: "/Applications/Cellar.app/Contents/Library/LaunchDaemons/cellar-daemon"),
        "/Applications/Cellar.app",
        "钉扎-8", "App-route 四层形态 → /Applications/Cellar.app")
    // 「首个 /Contents/ 前缀」语义：路径深处理再嵌 Contents 目录不回溯不误取。
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: "/Volumes/x/Cellar.app/Contents/a/Contents/b/cellar-daemon"),
        "/Volumes/x/Cellar.app",
        "钉扎-8", "多 Contents 形态取首个 /Contents/ 前缀（不回溯）")

    // 钉扎-9：开发构建形态 → nil（子串缺席）+ 入参 nil → nil（R4：锚点解析
    // 入参失败 → legacy 降级，不阻断 daemon 启动）。
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: "/Users/x/Cellar/.build/release/cellar-daemon"),
        nil as String?,
        "钉扎-9", ".build/release 开发形态 → nil（子串缺席 = CLI-route 无锚）")
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: nil),
        nil as String?,
        "钉扎-9", "executablePath nil → nil（R4 legacy 降级不阻断启动）")

    // 钉扎-10：CLI-route 安装落位 → nil（方案 §1.2：/Library/PrivilegedHelperTools
    // 无可信锚 → 诚实降级 legacy = 现状 admin 门）。
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: "/Library/PrivilegedHelperTools/cellar-daemon"),
        nil as String?,
        "钉扎-10", "PrivilegedHelperTools → nil（CLI-route 无锚诚实降级）")

    // 钉扎-11：.app 收尾守卫（守卫二）独立命中——路径含 "/Contents/"，但前缀
    // "/Users/x" 末段 "x" 非 .app 收尾 → nil。本条与钉扎-12 是两条守卫各自独立
    // 覆盖的证据（归因勿合并）：删守卫二则本条变 App bundle 误判放行；守卫一
    // 对本条照常命中（子串在位）——拒因唯守卫二。
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: "/Users/x/Contents/cellar-daemon"),
        nil as String?,
        "钉扎-11", "含 /Contents/ 但前缀非 .app 收尾 → nil（守卫二独立命中）")

    // 钉扎-12：子串缺席归因（守卫一）——"/Contents 测试/" 不构成 "/Contents/"
    // 分量（Contents 后无斜杠，语义子串两侧斜杠俱全）→ nil。归因 = 守卫一子串
    // 缺席，**非** .app 收尾守卫（守卫二对本条不可达——prefix 计算先行短路）。
    expectEqual(
        appBundleAnchor(fromDaemonExecutablePath: "/Users/x/Contents 测试/cellar-daemon"),
        nil as String?,
        "钉扎-12", "…/Contents 测试/… → nil（守卫一子串缺席归因——非 .app 守卫）")

    // ---- 钉扎-13..17：daemon 门接线源钉（方案 §2.4 commit 2 段；照
    // SecurityHardeningDomain source() 先例——活体连接直测面不存在）----

    let xpcServerSrc = source("Sources/cellar-daemon/XPCServer.swift")
    let xpcIdentitySrc = source("Sources/cellar-daemon/XPCIdentity.swift")

    // 钉扎-13：root 旁路先于身份门序钉（判定序单函数三段：root 旁路 → identity
    // 门（仅 pinned）→ admin 门）——`sudo cellar <变更>` 文档化用法零影响的判定
    // 级证据（字面量位置序，非仅存在性）。
    do {
        let bypassRange = xpcServerSrc.range(of: "peer.euid != 0")
        let identityRange = xpcServerSrc.range(of: "extractClientIdentity(message:")
        let adminRange = xpcServerSrc.range(of: "isAdminGroupMember(euid: peer.euid)")
        if let bypassRange, let identityRange, let adminRange {
            check(bypassRange.lowerBound < identityRange.lowerBound
                    && identityRange.lowerBound < adminRange.lowerBound,
                  "钉扎-13", "root 旁路（euid != 0）→ 身份门 → admin 门三段序钉死（位置序）")
        } else {
            check(false, "钉扎-13", "三段序标记缺席（序钉依赖字面量在位）")
        }
    }

    // 钉扎-14：getStatus 分支零 identity 触及（未鉴权面保持——方案 §0.2 显式
    // 非目标；分支体内无 extract/evaluate/record 字面量，1Hz 轮询零 SecCode 开销）。
    do {
        let getStatusRange = xpcServerSrc.range(of: "case \"getStatus\":")
        let setLimitsRange = xpcServerSrc.range(of: "case \"setLimits\":")
        if let getStatusRange, let setLimitsRange {
            let branch = String(xpcServerSrc[getStatusRange.upperBound..<setLimitsRange.lowerBound])
            check(branch.contains("sendStatus(core.status(), to: peer)")
                    && !branch.contains("extractClientIdentity")
                    && !branch.contains("evaluateClientIdentity")
                    && !branch.contains("recordRejection"),
                  "钉扎-14", "getStatus 分支体零 identity 触及（未鉴权语义不变）")
        } else {
            check(false, "钉扎-14", "getStatus/setLimits 分支标记缺席（钉面依赖分支结构）")
        }
    }

    // 钉扎-15：fail-closed 注记与专属错误消息字面量在位（wire 专属消息一字不差；
    // deny reason 三串为 daemon 日志面非 wire）+ 取证唯一公开代码路径链（落地偏差
    // 一裁决 A：kSecCodeInfoMainExecutable——方案原字面 kSecCodeInfoPath 为私有
    // 常量公开 SDK 零声明）+ 反 SPI 钉 + 锚点解析诚实降级日志 + main 接线。
    check(xpcServerSrc.contains("客户端身份未通过验证（仅 Cellar App 或 root 可执行变更命令）"),
          "钉扎-15", "wire 专属错误消息字面量在位（一字不差——XPC 回包文本非 l10n）")
    check(registrationSrc.contains("\"路径不符\"")
            && registrationSrc.contains("\"标识符不符\"")
            && registrationSrc.contains("\"签名校验未通过\""),
          "钉扎-15", "deny reason 三串字面量在位（路径/标识符/签名——判定序承重）")
    check(xpcIdentitySrc.contains("fail-closed"),
          "钉扎-15", "取证 glue fail-closed 注记在位（API 失败/字段缺失 → nil/false 诚实缺席）")
    check(xpcIdentitySrc.contains("SecCodeCreateWithXPCMessage(message, [], &code)")
            && xpcIdentitySrc.contains("SecCodeCheckValidity(code, [], requirement)")
            && xpcIdentitySrc.contains("SecCodeCopyStaticCode(code, [], &staticCode)")
            && xpcIdentitySrc.contains("SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)")
            && xpcIdentitySrc.contains("kSecCodeInfoMainExecutable"),
          "钉扎-15", "消息绑定取证链五标记在位（公开 API 全链——Create/CheckValidity/CopyStaticCode/CopySigningInformation/MainExecutable）")
    check(!xpcIdentitySrc.contains("get_audit_token(")
            && !xpcIdentitySrc.contains("_silgen_name")
            && !xpcServerSrc.contains("get_audit_token(")
            && !xpcServerSrc.contains("_silgen_name"),
          "钉扎-15", "零 audit-token SPI 调用 / 零 @_silgen_name（类级否决面反钉——钉调用形态而非字符串提及，注释记载否决名不误伤）")
    check(xpcIdentitySrc.contains("CLI-route 部署——客户端身份钉扎不可用（无可信锚），变更命令维持 admin 组门")
            && xpcIdentitySrc.contains("客户端身份钉扎启用：期望 App"),
          "钉扎-15", "锚点解析 notice/info 日志字面量在位（一次性——装配段调用一次，诚实降级不静默）")
    let mainSrc = source("Sources/cellar-daemon/main.swift")
    check(mainSrc.contains("resolveClientAnchor(executablePath: Bundle.main.executableURL?.path)")
            && mainSrc.contains("XPCServer(core: core, log: lifecycleLog, clientAnchor: clientAnchor)"),
          "钉扎-15", "启动期锚点解析接线在位（装配段纯纪律——结果随 init 注入，无共享可变态）")

    // 钉扎-16：bundle ID 单一真相常量声明钉 + pbxproj PRODUCT_BUNDLE_IDENTIFIER
    // 一致性断言（防两处漂移——常量与 App 构建配置同源）。
    check(registrationSrc.contains("public static let appBundleIdentifier = \"com.cellar.app\""),
          "钉扎-16", "bundle ID 单一真相常量声明在位（CellarCore/DaemonRegistration.swift）")
    let pbxprojSrc = source("App/CellarApp.xcodeproj/project.pbxproj")
    check(pbxprojSrc.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = com.cellar.app").count - 1 == 2,
          "钉扎-16", "pbxproj PRODUCT_BUNDLE_IDENTIFIER = com.cellar.app 恰两处（Debug+Release）——与常量一致性源钉")

    // 钉扎-17：行为零变化反钉——既有 admin 门标记原样在位 + 拒绝计数链字面量
    // 同文件存活（B5 纵深-4 源钉依赖 XPCServer.swift 文本字面量——recordRejection
    // 落点受 Swift private 可见性 + 本源钉双约束锚定于 XPCServer.swift）+
    // recordRejection 保序（发送先于 cancel 判定）。
    check(xpcServerSrc.contains("private func isAdminGroupMember(euid: uid_t) -> Bool")
            && xpcServerSrc.contains("禁止传 80"),
          "钉扎-17", "admin 组门判定 + getgrouplist basegid 纪律注释原样在位（legacy 零变化）")
    check(xpcServerSrc.contains("private static let authFailureLimit = 10")
            && xpcServerSrc.contains("private static let globalAuthAnnounceLimit = 50"),
          "钉扎-17", "限流阈值钉值照旧（authFailureLimit=10 / globalAuthAnnounceLimit=50）")
    check(xpcServerSrc.contains("private func recordRejection(peer: Peer, message: String")
            && xpcServerSrc.contains("peer.rejections += 1")
            && xpcServerSrc.contains("globalAuthRejections += 1"),
          "钉扎-17", "recordRejection 共享私有助手在位且计数字面量同文件存活（两拒绝分支单一路径）")
    do {
        let sendRange = xpcServerSrc.range(of: "send(errorReply(message), to: peer.connection)")
        let cancelRange = xpcServerSrc.range(of: "if peer.rejections >= Self.authFailureLimit")
        if let sendRange, let cancelRange {
            check(sendRange.lowerBound < cancelRange.lowerBound,
                  "钉扎-17", "拒绝回包发送先于 cancel 判定（保序承重——先 cancel 丢拒绝回包）")
        } else {
            check(false, "钉扎-17", "发送/cancel 标记缺席（保序钉依赖字面量）")
        }
    }
    check(xpcServerSrc.contains("guard peer.euid == 0 || isAdminGroupMember(euid: peer.euid) else {")
            && xpcServerSrc.contains("需要管理员权限（admin 组）才能执行 "),
          "钉扎-17", "legacy admin 门调用点 + 拒绝消息原文逐字在位（第三段行为零变化）")
}
