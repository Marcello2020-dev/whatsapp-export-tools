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
        ),
        .executable(
            name: "AIGlowHarness",
            targets: ["AIGlowHarness"]
        )
    ],
    targets: [
        .target(
            name: "AIGlowKit",
            path: "Sources/AIGlowKit"
        ),
        .target(
            name: "AIGlowKitDevTools",
            dependencies: ["AIGlowKit"],
            path: "Sources/AIGlowKitDevTools"
        ),
        .executableTarget(
            name: "AIGlowHarness",
            dependencies: ["AIGlowKitDevTools"],
            path: "Sources/AIGlowHarness",
            swiftSettings: [
                .define("AIGLOW_HARNESS")
            ]
        ),
        .testTarget(
            name: "AIGlowKitTests",
            dependencies: ["AIGlowKit", "AIGlowKitDevTools"],
            path: "Tests/AIGlowKitTests"
        )
    ]
)
