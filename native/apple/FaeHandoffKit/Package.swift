// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FaeHandoffKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FaeHandoffKit", targets: ["FaeHandoffKit"]),
    ],
    targets: [
        .target(
            name: "FaeHandoffKit",
            path: "Sources/FaeHandoffKit"
        ),
        .testTarget(
            name: "FaeHandoffKitTests",
            dependencies: ["FaeHandoffKit"],
            path: "Tests/FaeHandoffKitTests"
        ),
    ]
)
