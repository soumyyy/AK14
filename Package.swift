// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AK14",
    platforms: [.iOS(.v26), .macOS(.v27)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Analysis", targets: ["Analysis"]),
        .library(name: "Director", targets: ["Director"]),
        .library(name: "Render", targets: ["Render"]),
        .library(name: "Session", targets: ["Session"]),
        .executable(name: "ak14", targets: ["CLI"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Analysis", dependencies: ["Core"]),
        .target(name: "Director", dependencies: ["Core", "Render"], resources: [.copy("Resources/Prompts")]),
        .target(name: "Render", dependencies: ["Core"], resources: [.copy("Resources/StylePacks"), .copy("Resources/Assets")]),
        .target(name: "Session", dependencies: ["Core", "Render"]),
        .executableTarget(name: "CLI", dependencies: ["Core", "Analysis", "Director", "Render", "Session"]),
        .executableTarget(name: "Studio", dependencies: ["Core", "Render", "Session"]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "CLITests", dependencies: ["CLI", "Analysis", "Core", "Director", "Render", "Session", "TestSupport"]),
    ]
)
