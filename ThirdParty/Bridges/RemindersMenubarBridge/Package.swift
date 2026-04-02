// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RemindersMenubarBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "RemindersMenubarBridge",
            targets: ["RemindersMenubarBridge"]
        ),
    ],
    targets: [
        .target(name: "RemindersMenubarBridge"),
    ]
)
