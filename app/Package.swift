// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Martin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Martin",
            path: "Sources/Martin",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
