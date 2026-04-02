// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AppFlowyDocumentBridge",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "AppFlowyDocumentBridge",
            targets: ["AppFlowyDocumentBridge"]
        ),
    ],
    targets: [
        .target(
            name: "AppFlowyDocumentBridge"
        ),
    ]
)
