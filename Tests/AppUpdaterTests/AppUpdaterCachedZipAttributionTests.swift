// AppUpdaterCachedZipAttributionTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterCachedZipAttributionTests

/// Pins the cached-zip attribution rules introduced by issue #69 (A1).
///
/// The cache path is fixed (`update.zip`) and carries no version, so the bytes
/// on disk are not self-describing. The only trustworthy attribution is the
/// in-memory phase, which `AppUpdater` sets exactly once — immediately after
/// verifying and moving a specific download into place.
///
/// Before this fix, `handle` announced `.ready(release.tagName)` for whatever
/// bytes happened to be present, so a zip cached for an earlier release was
/// installed over the running app and only caught after the (irreversible)
/// swap.
///
/// Download URLs use the reserved `.invalid` TLD (RFC 2606) so the
/// fall-through paths cannot reach the real network.
///
/// Every test `defer`s removal of `zipURL.deletingLastPathComponent()` — the
/// whole scheduler-scoped directory, not just the zip. `makeUpdater` gives each
/// test a UUID-scoped `schedulerIdentifier`, so deleting the directory is safe
/// and is what keeps a run from leaving empty directories behind in the
/// developer's real `~/Library/Caches`.
@MainActor
@Suite("AppUpdater.handle cached-zip attribution")
struct AppUpdaterCachedZipAttributionTests {

    // MARK: - Helpers

    private func makeUpdater(currentVersion: String = "1.0.0") -> (AppUpdater, MockUpdateState) {
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: { _ in "App.zip" },
            publicKey: dummyPublicKey,
            schedulerIdentifier: "CachedZipAttribution.\(UUID().uuidString)",
            betaChannelProvider: { false }
        )
        return (updater, MockUpdateState())
    }

    /// Writes a placeholder zip at the updater's fixed cache path.
    private func writeCachedZip(_ updater: AppUpdater, contents: String) throws -> URL {
        let zipURL = updater.fixedZipURL
        try FileManager.default.createDirectory(
            at: zipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: zipURL)
        return zipURL
    }

    private func release(tagName: String) throws -> AvailableRelease {
        AvailableRelease(
            tagName: tagName,
            assets: [
                ReleaseAsset(
                    name: "App.zip",
                    browserDownloadURL: try #require(URL(string: "https://example.invalid/App.zip"))
                )
            ],
            signatureURL: try #require(URL(string: "https://example.invalid/App.zip.sig"))
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - The A1 regression

    /// **The bug this fix exists for.** A zip cached for v1.1.0 that the user
    /// never installed must not be announced as v1.2.0 — that is what caused
    /// the older bundle to be swapped over the running app.
    @Test func staleZipFromEarlierRelease_isDiscardedAndRedownloaded() async throws {
        let (updater, state) = makeUpdater()
        let zipURL = try writeCachedZip(updater, contents: "the v1.1.0 zip")
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        state.apply(.ready(version: "v1.1.0"))   // cached for the *previous* release

        await updater.handle(try release(tagName: "v1.2.0"), state: state)

        #expect(!exists(zipURL), "an unattributable zip must be deleted, not reused")
        #expect(
            state.currentPhase == .available(version: "v1.2.0"),
            "must fall through to a fresh download, got \(state.currentPhase)"
        )
    }

    /// A cold start: the host begins at `.idle`, so a zip left over from a
    /// previous session has no attribution and must be re-downloaded. This is
    /// the accepted cost of the fix — one redundant download.
    @Test func leftoverZipAfterRestart_isDiscardedAndRedownloaded() async throws {
        let (updater, state) = makeUpdater()
        let zipURL = try writeCachedZip(updater, contents: "leftover from last session")
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        // state.currentPhase is .idle — a fresh process has no phase history.
        await updater.handle(try release(tagName: "v2.0.0"), state: state)

        #expect(!exists(zipURL))
        #expect(state.currentPhase == .available(version: "v2.0.0"))
    }

    /// A `.failed` phase is not attribution either.
    @Test func failedPhase_doesNotAttributeCachedZip() async throws {
        let (updater, state) = makeUpdater()
        let zipURL = try writeCachedZip(updater, contents: "partial or unverified")
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        state.apply(.failed(version: "v2.0.0"))

        await updater.handle(try release(tagName: "v2.0.0"), state: state)

        #expect(!exists(zipURL))
        #expect(state.currentPhase == .available(version: "v2.0.0"))
    }

    // MARK: - The attributable case still works

    /// `.ready` for this exact tag is the one attribution that counts: the zip
    /// is kept and re-announced without a download.
    @Test func readyForSameTag_reusesCachedZip() async throws {
        let (updater, state) = makeUpdater()
        let zipURL = try writeCachedZip(updater, contents: "the v2.0.0 zip")
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        state.apply(.ready(version: "v2.0.0"))

        await updater.handle(try release(tagName: "v2.0.0"), state: state)

        #expect(exists(zipURL), "an attributable zip must be preserved")
        #expect(state.currentPhase == .ready(version: "v2.0.0"))
        #expect(
            !state.appliedPhases.contains(.available(version: "v2.0.0")),
            "must not start a download for a zip it already has"
        )
    }

    // MARK: - Issue #58 guard still wins

    /// The post-relaunch leftover guard runs before the attribution check: the
    /// zip is for the version already running, so `.idle` is correct and a
    /// re-download would be wrong.
    @Test func postRelaunchLeftover_appliesIdleAndKeepsIssue58Behaviour() async throws {
        let (updater, state) = makeUpdater(currentVersion: "2.0.0")
        let zipURL = try writeCachedZip(updater, contents: "just installed")
        defer { try? FileManager.default.removeItem(at: zipURL.deletingLastPathComponent()) }

        await updater.handle(try release(tagName: "v2.0.0"), state: state)

        #expect(state.currentPhase == .idle)
        #expect(
            !state.appliedPhases.contains(.available(version: "v2.0.0")),
            "a post-relaunch leftover must not trigger a download"
        )
    }
}
