// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AIGlowKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AIGlowKit",
            targets: ["AIGlowKit"]
        )
    ],
    targets: [
        .target(
            name: "AIGlowKit",
            path: "Sources/AIGlowKit"
        ),
        .testTarget(
            name: "AIGlowKitTests",
            dependencies: ["AIGlowKit"],
            path: "Tests/AIGlowKitTests"
        )
    ]
)
