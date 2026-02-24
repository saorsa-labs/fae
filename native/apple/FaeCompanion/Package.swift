// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FaeCompanion",
    platforms: [
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../FaeHandoffKit"),
        .package(path: "../FaeOrbKit"),
        .package(path: "../FaeRelayKit"),
    ],
    targets: [
        .executableTarget(
            name: "FaeCompanion",
            dependencies: [
                "FaeHandoffKit",
                "FaeOrbKit",
                "FaeRelayKit",
            ],
            path: "Sources/FaeCompanion"
        ),
    ]
)
