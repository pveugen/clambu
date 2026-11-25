// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clambu",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/SwiftTUI/swift-tui.git", .upToNextMajor(from: "0.25.1")),
    ],
    targets: [
        .target(name: "ClambuCore", dependencies: [.product(name: "Eye", package: "desert-ant-core")]),
        .target(name: "ClambuTerminal", dependencies: [
            "ClambuCore",
            .product(name: "SwiftTUICLI", package: "swift-tui"),
        ]),
        .executableTarget(name: "clambu", dependencies: [
            "ClambuCore", "ClambuTerminal", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ClambuCoreTests", dependencies: ["ClambuCore"]),
        .testTarget(name: "ClambuTerminalTests", dependencies: ["ClambuTerminal", "ClambuCore"]),
    ],
    swiftLanguageModes: [.v5]
)
