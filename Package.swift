// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodexMate",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "CodexMate",
            targets: ["CodexMate"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.9.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "CodexMate",
            dependencies: [
                "KeyboardShortcuts",
                "Sparkle",
            ],
            path: "Sources/CodexMate",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CodexMateTests",
            dependencies: ["CodexMate"],
            path: "Tests/CodexMateTests"
        ),
    ]
)
