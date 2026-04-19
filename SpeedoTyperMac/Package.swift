// swift-tools-version:6.0
import PackageDescription

// llama.cpp + ggml are installed via Homebrew. Swift doesn't search
// /opt/homebrew by default, so we pass the paths explicitly.
let brewPrefix = "/opt/homebrew"

let package = Package(
    name: "SpeedoTyper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpeedoTyper", targets: ["SpeedoTyper"]),
    ],
    targets: [
        .systemLibrary(
            name: "Cllama",
            path: "Sources/Cllama",
            providers: [.brew(["llama.cpp"])]
        ),
        .executableTarget(
            name: "SpeedoTyper",
            dependencies: ["Cllama"],
            path: "Sources/SpeedoTyper",
            resources: [.process("Resources")],
            cSettings: [
                .unsafeFlags(["-I", "\(brewPrefix)/include"]),
            ],
            swiftSettings: [
                .unsafeFlags(["-I", "\(brewPrefix)/include"]),
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(brewPrefix)/lib",
                    "-L\(brewPrefix)/opt/llama.cpp/lib",
                ]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
            ]
        ),
    ]
)
