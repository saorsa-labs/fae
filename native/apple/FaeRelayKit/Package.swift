// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FaeRelayKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "FaeRelayKit", targets: ["FaeRelayKit"]),
    ],
    dependencies: [
        .package(path: "../FaeOrbKit"),
    ],
    targets: [
        .target(
            name: "FaeRelayKit",
            dependencies: ["FaeOrbKit"],
            path: "Sources/FaeRelayKit"
        ),
    ]
)
