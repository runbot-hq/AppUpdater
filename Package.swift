// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [
        .macOS(.v14)
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
            path: "Sources/AppUpdater",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdater"],
            path: "Tests/AppUpdaterTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
