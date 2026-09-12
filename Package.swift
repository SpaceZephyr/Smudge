// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowRag",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WindowRag",
            path: "Sources/WindowRag"
        )
    ]
)
