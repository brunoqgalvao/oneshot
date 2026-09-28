// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Oneshot",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Oneshot", path: "Sources/Oneshot")
    ]
)
