// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Theine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Theine", targets: ["Theine"]),
    ],
    targets: [
        // Localization and the interface language (InterfaceLanguage.swift is the family's shared file)
        .target(
            name: "TheineCore",
            path: "Sources/TheineCore"
        ),
        // The menu bar app: the icon, its menu and panel, Settings, updates, sounds
        .executableTarget(
            name: "Theine",
            dependencies: ["TheineCore"],
            path: "Sources/Theine"
        ),
        .testTarget(
            name: "TheineTests",
            dependencies: ["Theine", "TheineCore"],
            path: "Tests/TheineTests"
        ),
    ]
)
