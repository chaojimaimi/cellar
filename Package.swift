// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cellar",
    // WP4 §2.2：与 catalog 源语言对齐（Localizable.xcstrings sourceLanguage =
    // zh-Hans；en 是完整 localization，golden 由 CI 显式 pin en）。
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cellar", targets: ["CellarCLI"]),
        .library(name: "CellarCore", targets: ["CellarCore"]),
        // WP4：SwiftUI-only 组件库（Xcode 本地包链接只认 product——cellar-daemon
        // 显式声明同款先例，硬事实 1）。
        .library(name: "CellarUI", targets: ["CellarUI"]),
        // WP4 §3.1：快照矩阵工具（渲染/归一化/容差 diff + --l10n 门禁；自研零依赖
        // ——SwiftPM 不为 executable target 自动建 product，显式声明同先例）。
        .executable(name: "CellarUICheck", targets: ["CellarUICheck"]),
        // WP2：内嵌 daemon 构建产物（App 的 run-script 以 --product cellar-daemon 构建；
        // 无此 product，--product 会报 product not found）。
        .executable(name: "cellar-daemon", targets: ["cellar-daemon"])
    ],
    dependencies: [
        // CLI 参数解析（Apple 官方开源，Apache-2.0；仅 CellarCLI 目标使用）
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "CellarCore"),
        // WP4：SwiftUI-only 组件库（platforms macOS 13——下沉组件必须以包平台
        // 编译过检，App deployment target 26.0 不豁免；依赖闭包 = CellarCore）。
        // ⚠️ SwiftPM 不自动发现 .xcstrings（实查警告 "unhandled"）——catalog 须
        // 显式 resources 声明，否则 Bundle.module 访问器不生成。
        .target(
            name: "CellarUI",
            dependencies: ["CellarCore"],
            resources: [
                .process("Resources/Localizable.xcstrings")
            ]
        ),
        // WP4 §3.1：快照矩阵可执行（单栈对齐 CellarCoreCheck——executable 无
        // XCTest；对比模式为无参默认，CI snapshot job 直接调用）。
        .executableTarget(
            name: "CellarUICheck",
            dependencies: ["CellarUI"]
        ),
        // CLT-only 环境的本地验证工具（无 XCTest 依赖）：76 个场景 + 真机诊断。
        // CellarCoreCheck 是唯一测试栈（公开仓库无 Tests/，本地 XCTest 已移除）。
        .executableTarget(
            name: "CellarCoreCheck",
            dependencies: ["CellarCore"]
        ),
        .executableTarget(
            name: "CellarCLI",
            dependencies: [
                "CellarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // WP6：root LaunchDaemon（安装器校验 .build/release/cellar-daemon 产物路径，
        // ⚠️ 目标名必须为小写连字符 cellar-daemon——评审 E-2）。
        .executableTarget(
            name: "cellar-daemon",
            dependencies: ["CellarCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
