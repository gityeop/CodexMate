// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodextensionMenubar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "CodextensionMenubar",
            targets: ["CodextensionMenubar"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "CodextensionMenubar"
        ),
        .testTarget(
            name: "CodextensionMenubarTests",
            dependencies: ["CodextensionMenubar"]
        ),
    ]
)
