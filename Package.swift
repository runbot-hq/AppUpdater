// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AppUpdater",
            targets: ["AppUpdater"]
        )
    ],
    targets: [
        .target(
            name: "AppUpdater",
            path: "Sources/AppUpdater"
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdater"],
            path: "Tests/AppUpdaterTests"
        )
    ]
)
