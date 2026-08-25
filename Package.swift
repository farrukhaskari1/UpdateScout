// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UpdateScout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "UpdateScout",
            path: "Sources/UpdateScout"
        ),
        .testTarget(
            name: "UpdateScoutTests",
            dependencies: ["UpdateScout"],
            path: "Tests/UpdateScoutTests",
            resources: [.process("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
