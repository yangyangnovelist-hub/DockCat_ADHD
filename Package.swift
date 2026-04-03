// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DockCatTaskAssistant",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "DockCatTaskAssistant",
            targets: ["DockCatTaskAssistant"]
        ),
    ],
    dependencies: [
        .package(path: "ThirdParty/Bridges/AppFlowyDocumentBridge"),
        .package(path: "ThirdParty/Bridges/RemindersMenubarBridge"),
        .package(path: "ThirdParty/Bridges/VikunjaQuickAddBridge"),
        .package(path: "ThirdParty/Bridges/BongoCatInputBridge"),
        .package(path: "ThirdParty/Upstreams/pet-therapy/Packages/OnScreen"),
        .package(path: "ThirdParty/Upstreams/pet-therapy/Packages/Pets"),
        .package(url: "https://github.com/stevengharris/SplitView.git", from: "1.0.0"),
        .package(url: "https://github.com/buh/CompactSlider.git", from: "2.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.10.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.8"),
    ],
    targets: [
        .executableTarget(
            name: "DockCatTaskAssistant",
            dependencies: [
                .product(name: "AppFlowyDocumentBridge", package: "AppFlowyDocumentBridge"),
                .product(name: "RemindersMenubarBridge", package: "RemindersMenubarBridge"),
                .product(name: "VikunjaQuickAddBridge", package: "VikunjaQuickAddBridge"),
                .product(name: "BongoCatInputBridge", package: "BongoCatInputBridge"),
                .product(name: "OnScreen", package: "OnScreen"),
                .product(name: "Pets", package: "Pets"),
                .product(name: "SplitView", package: "SplitView"),
                .product(name: "CompactSlider", package: "CompactSlider"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Defaults", package: "Defaults"),
            ],
            resources: [
                .process("Resources/DashCatAvatar.jpg"),
                .process("Resources/DockCatAppIcon.png"),
                .copy("Resources/MindMapApp"),
            ]
        ),
        .testTarget(
            name: "DockCatTaskAssistantTests",
            dependencies: ["DockCatTaskAssistant"]
        ),
    ]
)
