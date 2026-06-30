// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenSurreal",
    platforms: [
        .visionOS(.v1)
    ],
    products: [
        .library(name: "OpenSurreal", targets: ["OpenSurreal"])
    ],
    targets: [
        .target(name: "OpenSurreal", path: "Sources"),
        .testTarget(
            name: "OpenSurrealTests",
            dependencies: ["OpenSurreal"]
        )
    ]
)
