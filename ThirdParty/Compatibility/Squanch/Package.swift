// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Squanch",
    platforms: [
        .macOS(.v11),
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "Squanch",
            targets: ["Squanch"]
        ),
    ],
    targets: [
        .target(
            name: "Squanch"
        ),
    ]
)
