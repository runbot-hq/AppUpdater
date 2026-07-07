// AppUpdaterDefaultsTests.swift
// AppUpdaterTests

import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDefaultsTests

/// Smoke-tests for `AppUpdater` instance configuration defaults.
///
/// `AppUpdaterDefaults` and `rehydrateCachedUpdateIfNewer` were removed in the
/// AppUpdater library-extraction refactor (issue #1860). The scoped
/// `UserDefaults` cache is superseded by `fixedZipURL` — the zip always lives
/// at a deterministic path under `~/Library/Caches/<id>/update.zip`
/// so no key-based persistence is required.
@MainActor struct AppUpdaterDefaultsTests {

    // MARK: - Helpers

    /// A minimal `AppUpdater` constructed with all defaults.
    private func makeUpdater() -> AppUpdater {
        AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.defaults"
        )
    }

    // MARK: - checkInterval

    /// `checkInterval` must be a positive `TimeInterval`.
    @Test func checkInterval_isPositive() {
        #expect(makeUpdater().checkInterval > 0)
    }

    /// A custom value passed at init is reflected on the instance regardless of
    /// build configuration.
    @Test func checkInterval_customValue_isRespected() {
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.custom-interval",
            checkInterval: 300
        )
        #expect(updater.checkInterval == 300)
    }

    /// Passing the debug default (60 s) explicitly must be stored as-is.
    @Test func checkInterval_debugDefault_60Seconds() {
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.debug-interval",
            checkInterval: 60
        )
        #expect(updater.checkInterval == 60)
    }

    /// Passing the release default (24 h) explicitly must be stored as-is.
    @Test func checkInterval_releaseDefault_24Hours() {
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.release-interval",
            checkInterval: 24 * 60 * 60
        )
        #expect(updater.checkInterval == 24 * 60 * 60)
    }
}
