// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VikunjaQuickAddBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "VikunjaQuickAddBridge",
            targets: ["VikunjaQuickAddBridge"]
        ),
    ],
    targets: [
        .target(
            name: "VikunjaQuickAddBridge"
        ),
    ]
)
