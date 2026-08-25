// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateScout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "UpdateScout",
            path: "Sources/UpdateScout"
        )
    ]
)
