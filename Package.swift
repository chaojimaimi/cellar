// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cellar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "cellar", targets: ["CellarCLI"])
    ],
    dependencies: [
        // CLI 参数解析（Apple 官方开源，Apache-2.0；仅 CellarCLI 目标使用）
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "CellarCore"),
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
