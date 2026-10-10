// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Oneshot",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 0.6.1 is the last FluidAudio release that builds with Swift 5.10 and macOS 13 (later tags need Swift 6).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.6.1"),
    ],
    targets: [
        .executableTarget(name: "Oneshot", dependencies: ["FluidAudio"], path: "Sources/Oneshot")
    ]
)
