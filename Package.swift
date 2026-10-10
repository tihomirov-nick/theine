// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Theine",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Theine", targets: ["Theine"]),
        .executable(name: "TheineHelper", targets: ["TheineHelper"]),
    ],
    targets: [
        // What Theine and its root helper agree on, and what the helper does: the requests, the pass over them, pmset
        .target(
            name: "TheineHelperCore",
            path: "Sources/TheineHelperCore"
        ),
        // The helper itself, run by launchd as root once installed (Contents/Helpers/TheineHelper in the app)
        .executableTarget(
            name: "TheineHelper",
            dependencies: ["TheineHelperCore"],
            path: "Sources/TheineHelper"
        ),
        // The mode, the power assertions, the helper's installer, localization and the interface language
        // (InterfaceLanguage.swift is the family's shared file)
        .target(
            name: "TheineCore",
            dependencies: ["TheineHelperCore"],
            path: "Sources/TheineCore"
        ),
        // The menu bar app: the icon, its menu and panel, Settings, updates, sounds
        .executableTarget(
            name: "Theine",
            dependencies: ["TheineCore", "TheineHelperCore"],
            path: "Sources/Theine"
        ),
        .testTarget(
            name: "TheineTests",
            dependencies: ["Theine", "TheineCore", "TheineHelper", "TheineHelperCore"],
            path: "Tests/TheineTests"
        ),
    ]
)
