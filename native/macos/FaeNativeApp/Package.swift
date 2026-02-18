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
    targets: [
        // C module exposing the libfae FFI header to Swift.
        .target(
            name: "CLibFae",
            path: "Sources/CLibFae",
            publicHeadersPath: "include"
        ),

        .executableTarget(
            name: "FaeNativeApp",
            dependencies: ["CLibFae"],
            path: "Sources/FaeNativeApp",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                // Path to Rust-built libfae.a (arm64 release).
                // In CI, the release workflow builds this before swift build.
                // For local dev, run: just build-staticlib
                .unsafeFlags([
                    "-L../../../target/aarch64-apple-darwin/release",
                    "-L../../../target/debug",
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
    ]
)
