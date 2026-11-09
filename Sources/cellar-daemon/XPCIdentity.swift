// cellar-daemon —— 0.23.13 B6-2 XPC 客户端身份取证 glue（方案 §2.2）
//
// 判定全在 CellarCore 纯函数层（appBundleAnchor / evaluateClientIdentity——
// CellarCoreCheck 直测可达）；本文件只做 OS 胶水并保持最薄（executable target
// 不可 import 的 SPM 硬事实下，唯一测试通道 = XPCPinningDomain 源钉面）。
//
// 取证纪律（方案 §1.5 + 落地偏差一裁决 A）：
// - 唯一代码路径 SecCodeCreateWithXPCMessage（公开 API，消息绑定——消息对象一步
//   直达 SecCode，无连接级陈旧令牌面）；全部 audit-token 提取 API（连接级
//   xpc_connection_get_audit_token / 消息级 xpc_dictionary_get_audit_token）均为
//   私有 SPI——类级否决，绝不引入。
// - 主可执行路径取公开常量 kSecCodeInfoMainExecutable（SecCode.h:424-427，文档
//   语义 = 主可执行文件 CFURL）。**落地偏差一**：方案原字面 kSecCodeInfoPath 为
//   Security 私有常量（公开 SDK 零声明），且其对 bundle 代码返回 bundle 路径
//   而非主可执行路径——照原字面「路径精确相等」恒 deny（R1 误杀 App），经裁决
//   改用 MainExecutable（语义恰为方案括注「主可执行路径」）。
// - Swift 导入形状（SDK typecheck 实证）：SecCSFlags 为 OptionSet（空集 `[]`；
//   kSecCSSigningInformation 以 UInt32 全局导入，SecCSFlags(rawValue:) 构造）；
//   SecCodeCopySigningInformation 入参 SecStaticCodeRef——SecCodeCopyStaticCode
//   插步（SecCode.h:103/528）。

import CellarCore
import Foundation
import Security
import os
@preconcurrency import XPC

/// daemon 身份取证日志（一次性日志——锚点解析在装配段仅调用一次，天然无刷屏面）。
private let identityLog = Logger(subsystem: "com.cellar.daemon", category: "identity")

/// daemon 锚点模式（XPCServer init 注入，进程生存期不可变值——无共享可变态，
/// Swift 6 strict concurrency 零新增 nonisolated(unsafe)）。
enum ClientAnchor: Sendable {
    /// App-route：客户端身份钉扎启用（期望身份 = PinnedClientIdentity）。
    case pinned(PinnedClientIdentity)
    /// CLI-route / 锚点解析失败：诚实降级，维持既有 admin 门（行为零变化）。
    case legacy
}

/// 启动期锚点解析（方案 §2.2①；main.swift 装配段调用一次）：
/// 1) 纯函数 appBundleAnchor 派生 appPath；nil → .legacy（一次性 notice 日志）；
/// 2) 读 <appPath>/Contents/Info.plist 的 CFBundleExecutable（缺席 fallback =
///    bundle 名）拼期望可执行路径；Info.plist 读取失败 → 降级 .legacy + 一次性
///    error 日志（锚定解析失败是环境异常非攻击面：保持可用性，诚实降级不静默）；
/// 3) 成功 → .pinned(PinnedClientIdentity) + info 日志。
func resolveClientAnchor(executablePath: String?) -> ClientAnchor {
    // R4：Bundle.main.executableURL 在 launchd 环境形态异常 → nil → legacy 降级
    // （不阻断 daemon 启动；纯函数层不依赖 Bundle API——入参直测）。
    guard let executablePath,
          let appPath = appBundleAnchor(fromDaemonExecutablePath: executablePath) else {
        identityLog.notice("CLI-route 部署——客户端身份钉扎不可用（无可信锚），变更命令维持 admin 组门")
        return .legacy
    }
    let infoPlistURL = URL(fileURLWithPath: appPath)
        .appendingPathComponent("Contents/Info.plist")
    guard let infoData = try? Data(contentsOf: infoPlistURL),
          let raw = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
          let info = raw as? [String: Any] else {
        identityLog.error("客户端身份锚定解析失败（\(appPath, privacy: .public)/Contents/Info.plist 读取失败）——降级 legacy 维持 admin 组门（环境异常非攻击面，诚实降级不静默）")
        return .legacy
    }
    // bundle 名 fallback = 锚点目录名去 .app 后缀（macOS bundle 命名约定 <Name>.app
    // ↔ 可执行 <Name>；不额外依赖 CFBundleName 键——锚点自身即真相）。
    let bundleName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
    let executableName = (info["CFBundleExecutable"] as? String) ?? bundleName
    let expected = PinnedClientIdentity(
        bundleIdentifier: ClientIdentity.appBundleIdentifier,
        appPath: appPath,
        executablePath: appPath + "/Contents/MacOS/" + executableName)
    identityLog.info("客户端身份钉扎启用：期望 App \(appPath, privacy: .public)（可执行 \(expected.executablePath, privacy: .public)）")
    return .pinned(expected)
}

/// 消息绑定取证（方案 §2.2③——唯一不可直测面，保持最薄）。SecCodeCreateWithXPCMessage
/// （消息→SecCode 一步直达）→ SecCodeCheckValidity（identifier requirement 有效
/// 签名判定）→ SecCodeCopyStaticCode 插步 → SecCodeCopySigningInformation
/// （kSecCSSigningInformation）→ facts。任何 API 失败/字段缺失 → 对应字段
/// nil/false（诚实缺席，判定层 fail-closed 拒绝）。
func extractClientIdentity(message: xpc_object_t) -> ClientIdentityFacts {
    var code: SecCode?
    guard SecCodeCreateWithXPCMessage(message, [], &code) == errSecSuccess, let code else {
        return ClientIdentityFacts(validityPassed: false, identifier: nil, executablePath: nil)
    }
    // 有效签名判定：identifier "com.cellar.app" requirement（单一真相常量拼
    // requirement 文本——ad-hoc 无证书身份可钉，identifier 判有效签名是语义防线）。
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(
        "identifier \"\(ClientIdentity.appBundleIdentifier)\"" as CFString,
        [], &requirement) == errSecSuccess, let requirement else {
        return ClientIdentityFacts(validityPassed: false, identifier: nil, executablePath: nil)
    }
    let validityPassed = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    // 签名信息字典：identifier + 主可执行路径（kSecCodeInfoMainExecutable CFURL
    // ——落地偏差一裁决 A；SecCodeCopySigningInformation 入参 SecStaticCodeRef，
    // SecCodeCopyStaticCode 插步照 SDK typecheck 实证形态）。
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else {
        return ClientIdentityFacts(validityPassed: validityPassed, identifier: nil, executablePath: nil)
    }
    return ClientIdentityFacts(
        validityPassed: validityPassed,
        identifier: dict[kSecCodeInfoIdentifier as String] as? String,
        executablePath: (dict[kSecCodeInfoMainExecutable as String] as? URL)?.path)
}
