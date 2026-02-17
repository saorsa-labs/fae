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
        .executableTarget(
            name: "FaeNativeApp",
            path: "Sources/FaeNativeApp",
            resources: [
                .process("Resources"),
            ]
        )
    ]
)
