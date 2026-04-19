// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeedoTyper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpeedoTyper", targets: ["SpeedoTyper"]),
    ],
    targets: [
        .executableTarget(
            name: "SpeedoTyper",
            path: "Sources/SpeedoTyper",
            resources: [.process("Resources")]
        ),
    ]
)
