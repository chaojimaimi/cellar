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
        // CLT-only 环境的本地验证工具（无 XCTest 依赖）：跑 §5.5 全部场景 + 真机冒烟。
        // CI 与装有 Xcode 的环境仍以 swift test（XCTest）为准，两者场景保持同步。
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
        .testTarget(
            name: "CellarCoreTests",
            dependencies: ["CellarCore", "CellarCLI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
