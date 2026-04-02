// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BongoCatInputBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "BongoCatInputBridge",
            targets: ["BongoCatInputBridge"]
        ),
    ],
    targets: [
        .target(name: "BongoCatInputBridge"),
    ]
)
