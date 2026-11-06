// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacPulse",
            path: "Sources/MacPulse"
        )
    ]
)
