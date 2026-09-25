// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AK14",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "ak14", targets: ["CLI"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Analysis", dependencies: ["Core"]),
        .target(name: "Director", dependencies: ["Core"], resources: [.copy("Resources/Prompts")]),
        .target(name: "Render", dependencies: ["Core"], resources: [.copy("Resources/StylePacks")]),
        .executableTarget(name: "CLI", dependencies: ["Core", "Analysis", "Director", "Render"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "CLITests", dependencies: ["CLI", "Analysis", "Core", "Director", "Render", "TestSupport"]),
    ]
)
