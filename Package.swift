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
        .executableTarget(name: "CLI", dependencies: ["Core", "Analysis"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "CLITests", dependencies: ["CLI", "Analysis", "Core", "TestSupport"]),
    ]
)
