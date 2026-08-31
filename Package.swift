// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Cellar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "CellarCore"),
        // CLT-only 环境的本地验证工具（无 XCTest 依赖）：跑 §5.5 全部场景 + 真机冒烟。
        // CI 与装有 Xcode 的环境仍以 swift test（XCTest）为准，两者场景保持同步。
        .executableTarget(
            name: "CellarCoreCheck",
            dependencies: ["CellarCore"]
        ),
        .testTarget(
            name: "CellarCoreTests",
            dependencies: ["CellarCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
