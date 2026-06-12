// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Fae",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .executable(name: "Fae", targets: ["Fae"]),
        .executable(name: "FaeBenchmark", targets: ["FaeBenchmark"]),
        .executable(name: "FaePerceptionBenchmark", targets: ["FaePerceptionBenchmark"]),
        .executable(name: "FaeEvalServer", targets: ["FaeEvalServer"]),
    ],
    dependencies: [
        // Shared Handoff contract types: FaeHandoffContract, ConversationSnapshot, etc.
        .package(path: "../../apple/FaeHandoffKit"),
        // Sparkle 2 auto-update framework (EdDSA signature verification).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // MLX ecosystem — local ML inference on Apple Silicon.
        // mlx-swift is resolved transitively via mlx-swift-lm.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.31.0")),
        // Pinned by SHA (supply-chain policy): the v0.1.2 tag points at a
        // pre-Kokoro commit — resolving it silently killed TTS ("Unsupported
        // model type: kokoro"). 65e228f = main 2026-04-20: has Kokoro (incl.
        // the #136/#151 crash fixes) and is the last revision on
        // mlx-swift-lm 2.x, matching our 2.31 pin. Newer main requires
        // mlx-swift-lm 3.x — bump both together when that migration happens.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "65e228ff3131f994c47d083c732e1adb6504cbf7"),
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
        // NOTE: kokoro-ios vendored package removed from dependencies.
        // FaeTTSAdapter uses MLXAudioTTS (mlx-audio-swift) directly.
        // MCP (Model Context Protocol) — official Swift SDK for connecting to MCP servers.
        // Enables Fae to use plugin-provided MCP tools (Slack, Linear, etc.).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "FaeInference",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/FaeInference"
        ),

        .executableTarget(
            name: "Fae",
            dependencies: [
                "FaeInference",
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
                .product(name: "Sparkle", package: "Sparkle"),
                // MLX LLM inference.
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                // MLX Audio — STT, TTS, and VAD (SmartTurn endpoint detection).
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                // Data layer.
                .product(name: "GRDB", package: "GRDB.swift"),
                "CSQLiteVecCore",
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "SileroVAD", package: "silero-vad-swift"),
                // MCP client for plugin-provided tool servers.
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/Fae",
            exclude: [
                // Metal sources are pre-compiled to Resources/default.metallib
                // via: xcrun metal -c FaeOrb.metal -o /tmp/FaeOrb.air
                //      xcrun metallib /tmp/FaeOrb.air -o Resources/default.metallib
                "FaeOrb.metal",
                "FogCloudOrb.metal",
                "NebulaOrb.metal",
                "Resources/bin/README.md",
            ],
            resources: [
                // Individual resource entries avoid the double-nesting bug where
                // .copy("Resources") creates Contents/Resources/Resources/ in
                // xcodebuild bundles, making NSBundle.url(forResource:) fail.
                .copy("Resources/Skills"),
                .copy("Resources/Models"),
                .copy("Resources/default.metallib"),
                .copy("Resources/SOUL.md"),
                .copy("Resources/CHANGELOG.md"),
                .copy("Resources/HEARTBEAT.md"),
                .copy("Resources/damage-control-default.yaml"),
                .copy("Resources/Voices/fae.wav"),
                .copy("Resources/Voices/fae.bin"),
                .copy("Resources/Voices/fae.safetensors"),
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
                "FaeInference",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/FaeBenchmark"
        ),

        // OpenAI-compatible eval server — same MLXLLMEngine + MLXVLMEngine as production Fae.
        // Bridges the Python eval harness to real Swift MLX inference.
        // Run: swift run FaeEvalServer --model qwen3.5-27b --port 8234
        // VLM: swift run FaeEvalServer --model smolvlm-256m --port 8234
        .executableTarget(
            name: "FaeEvalServer",
            dependencies: [
                "FaeInference",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/FaeEvalServer"
        ),

        .executableTarget(
            name: "FaePerceptionBenchmark",
            dependencies: [
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources/FaePerceptionBenchmark"
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
                .unsafeFlags(["-Wno-shorten-64-to-32"]),
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

        // Offline audio evaluation tests — run against downloaded corpora
        // (MUSAN, Google Speech Commands, OpenSLR RIR).  Slow (~2 min) and
        // skipped when corpus data is absent.  Run explicitly via:
        //   just eval-audio
        .testTarget(
            name: "EvalTests",
            dependencies: [
                "Fae",
            ],
            path: "Tests/EvalTests"
        ),
    ]
)
