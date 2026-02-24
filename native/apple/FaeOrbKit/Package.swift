// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FaeOrbKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "FaeOrbKit", targets: ["FaeOrbKit"]),
    ],
    targets: [
        .target(
            name: "FaeOrbKit",
            path: "Sources/FaeOrbKit",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
