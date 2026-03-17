// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodextensionMenubar",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "CodextensionMenubar",
            targets: ["CodextensionMenubar"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.9.4"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "CodextensionMenubar",
            dependencies: [
                "KeyboardShortcuts",
                "Sparkle",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CodextensionMenubarTests",
            dependencies: ["CodextensionMenubar"]
        ),
    ]
)
