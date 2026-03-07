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
        // mlx-swift pinned to branch:main to override the .upToNextMinor(from:"0.30.6")
        // constraint imposed by mlx-swift-lm. Required to pick up fixes merged after 0.30.6
        // (e.g. wired memory race condition fix — PR #358 on mlx-swift).
        .package(url: "https://github.com/ml-explore/mlx-swift", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
        // SQLite with ORM — memory store.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // NOTE: SQLiteVec upstream removed — its CSQLiteVec C module exposes
        // sqlite3ext.h as a public header, whose macros redefine sqlite3_db_config
        // and break GRDB's shim.h. Local CSQLiteVecCore target bundles sqlite-vec.c
        // with SQLITE_CORE defined to avoid the conflict.
        // TOML config file parsing.
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        // Neural Voice Activity Detection (Silero VAD v6 via CoreML).
        .package(url: "https://github.com/paean-ai/silero-vad-swift.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Fae",
            dependencies: [
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                // MLX LLM inference.
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                // MLX Audio — STT and TTS.
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                // Data layer.
                .product(name: "GRDB", package: "GRDB.swift"),
                "CSQLiteVecCore",
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "SileroVAD", package: "silero-vad-swift"),
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
                // Individual resource entries avoid the double-nesting bug where
                // .copy("Resources") creates Contents/Resources/Resources/ in
                // xcodebuild bundles, making NSBundle.url(forResource:) fail.
                .copy("Resources/Skills"),
                .copy("Resources/Models"),
                .copy("Resources/default.metallib"),
                .copy("Resources/SOUL.md"),
                .copy("Resources/HEARTBEAT.md"),
                .copy("Resources/damage-control-default.yaml"),
                .copy("Resources/Voices/fae.wav"),
                .copy("Resources/App/AppIconFace.jpg"),
                .copy("Resources/Scripts"),
            ],
            linkerSettings: [
                // System frameworks for native Swift pipeline.
                .linkedFramework("Security"),
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreML"),
                .linkedFramework("ScreenCaptureKit"),
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

        // Local sqlite-vec C target — bundles sqlite-vec.c with SQLITE_CORE to avoid
        // header macro conflicts with GRDB's GRDBSQLite module.
        .target(
            name: "CSQLiteVecCore",
            path: "Sources/CSQLiteVecCore",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_ENABLE_FTS5"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
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
