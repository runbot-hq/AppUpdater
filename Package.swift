// swift-tools-version:6.2
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
            path: "Sources/AppUpdater",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "AppUpdaterTests",
            dependencies: ["AppUpdater"],
            path: "Tests/AppUpdaterTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
