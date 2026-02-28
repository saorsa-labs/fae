// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fae",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Fae", targets: ["Fae"]),
        .executable(name: "FaeBenchmark", targets: ["FaeBenchmark"]),
    ],
    dependencies: [
        // Shared Handoff contract types: FaeHandoffContract, ConversationSnapshot, etc.
        .package(path: "../../apple/FaeHandoffKit"),
        // Sparkle 2 auto-update framework (EdDSA signature verification).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // MLX ecosystem — local ML inference on Apple Silicon.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
        // SQLite with ORM — memory store.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // TOML config file parsing.
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Fae",
            dependencies: [
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                // MLX LLM inference.
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // MLX Audio — STT and TTS.
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                // Data layer.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/Fae",
            exclude: [
                // Metal sources are pre-compiled to Resources/default.metallib
                // via: xcrun metal -c NebulaOrb.metal -o /tmp/NebulaOrb.air
                //      xcrun metallib /tmp/NebulaOrb.air -o Resources/default.metallib
                "FogCloudOrb.metal",
                "NebulaOrb.metal",
            ],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // System frameworks for native Swift pipeline.
                .linkedFramework("Security"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreML"),
            ]
        ),

        // LLM benchmark executable — measures throughput, /no_think compliance, tool calling.
        // Run: swift run FaeBenchmark --model qwen3.5-35b-a3b
        .executableTarget(
            name: "FaeBenchmark",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/FaeBenchmark"
        ),

        // Handoff unit tests — depends only on FaeHandoffKit (no libfae.a required).
        // Tests pure logic: command parsing, snapshot encoding, payload scenarios.
        .testTarget(
            name: "HandoffTests",
            dependencies: [
                "Fae",
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
            ],
            path: "Tests/HandoffTests",
            exclude: [
                "Fixtures/Memory/README.md",
                "Fixtures/Memory/manifest.toml",
                "Fixtures/Memory/records.jsonl",
                "Fixtures/Memory/audit.jsonl",
            ]
        ),

        // Search module tests — URL normalization, content extraction, engines, orchestrator.
        // Includes live integration tests that fetch from real search engines.
        .testTarget(
            name: "SearchTests",
            dependencies: [
                "Fae",
            ],
            path: "Tests/SearchTests"
        ),

        // End-to-end integration tests with mock ML engines.
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Fae",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/IntegrationTests"
        ),
    ]
)
