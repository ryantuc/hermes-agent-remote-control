// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HermesServeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HermesServeKit", targets: ["HermesServeKit"])
    ],
    targets: [
        .target(
            name: "HermesServeKit",
            path: "Sources/HermesServeKit"
        ),
        .testTarget(
            name: "HermesServeKitTests",
            dependencies: ["HermesServeKit"],
            path: "Tests/HermesServeKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
