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
}
