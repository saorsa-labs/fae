// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FaeNativeApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "FaeNativeApp", targets: ["FaeNativeApp"]),
    ],
    dependencies: [
        // Shared Handoff contract types: FaeHandoffContract, ConversationSnapshot, etc.
        .package(path: "../../apple/FaeHandoffKit"),
    ],
    targets: [
        // C module exposing the libfae FFI header to Swift.
        .target(
            name: "CLibFae",
            path: "Sources/CLibFae",
            publicHeadersPath: "include"
        ),

        .executableTarget(
            name: "FaeNativeApp",
            dependencies: [
                "CLibFae",
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
            ],
            path: "Sources/FaeNativeApp",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // Path to Rust-built libfae.a (arm64 release).
                // In CI, the release workflow builds this before swift build.
                // For local dev, run: just build-staticlib
                //
                // -force_load ensures ALL symbols from libfae.a are linked,
                // not just those directly reachable from the FFI entry points.
                // Without this, the linker strips the ML inference (mistralrs),
                // TTS (kokoro), STT (parakeet), and audio pipeline code because
                // the command handler dispatches to them via async runtime calls
                // that the linker's dead-code analysis cannot trace.
                .unsafeFlags([
                    "-L../../../target/aarch64-apple-darwin/release",
                    "-L../../../target/debug",
                    "-Xlinker", "-force_load",
                    "-Xlinker", "../../../target/aarch64-apple-darwin/release/libfae.a",
                ]),
                // System frameworks required by libfae's Rust dependencies.
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
                // ONNX Runtime (C++ runtime)
                .linkedLibrary("c++"),
                // Metal GPU acceleration (mistralrs, candle)
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                // BLAS/LAPACK (candle, accelerate-src)
                .linkedFramework("Accelerate"),
                // winit keyboard layout queries (kTISPropertyUnicodeKeyLayoutData)
                .linkedFramework("Carbon"),
                // Audio I/O (cpal)
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                // Hardware/device access (cpal, system info)
                .linkedFramework("IOKit"),
                // DNS resolver (reqwest/hyper)
                .linkedLibrary("resolv"),
            ]
        ),

        // Handoff unit tests — depends only on FaeHandoffKit (no libfae.a required).
        // Tests pure logic: command parsing, snapshot encoding, payload scenarios.
        .testTarget(
            name: "HandoffTests",
            dependencies: [
                .product(name: "FaeHandoffKit", package: "FaeHandoffKit"),
            ],
            path: "Tests/HandoffTests"
        ),
    ]
)
