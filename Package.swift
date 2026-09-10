// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Smudge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Smudge",
            path: "Sources/Smudge"
        )
    ]
)
