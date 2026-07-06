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
/// at a deterministic path under `~/Library/Caches/<schedulerIdentifier>/update.zip`
/// so no key-based persistence is required.
@MainActor
struct AppUpdaterDefaultsTests {

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

    #if DEBUG
    /// In DEBUG builds the interval defaults to 60 seconds for fast QA cycles.
    @Test func checkInterval_debug_defaultIs60Seconds() {
        #expect(makeUpdater().checkInterval == 60)
    }
    #else
    /// In release builds the interval defaults to 24 hours.
    @Test func checkInterval_release_is24Hours() {
        #expect(makeUpdater().checkInterval == 24 * 60 * 60)
    }
    #endif

    /// A custom value passed at init is reflected on the instance.
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
}
