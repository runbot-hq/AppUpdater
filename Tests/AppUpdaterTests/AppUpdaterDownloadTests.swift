// AppUpdaterDownloadTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDownloadTests

/// Tests that verify `AppUpdater.handle` state-machine behaviour via
/// `MockUpdateState.currentPhase` / `appliedPhases`.
///
/// Network I/O is avoided throughout:
/// - "no matching asset" and "no signature URL" paths return before spawning
///   any download Task.
/// - The "cached zip" path is exercised by writing a dummy file at
///   `updater.fixedZipURL` before calling `handle`.
/// - The "asset present + signatureURL present" path advances to `.available`
///   synchronously, then the download Task fires asynchronously — we assert
///   only the synchronous phase transition here.
///
/// All tests are `@MainActor` because `AppUpdater` and `MockUpdateState`
/// are both `@MainActor`.
@MainActor
@Suite("AppUpdater.handle")
struct AppUpdaterDownloadTests {

    // MARK: - Helpers

    private func makeUpdater(
        currentVersion: String = "1.0.0",
        assetName: @Sendable @escaping (String) -> String = { _ in "App.zip" }
    ) -> (updater: AppUpdater, state: MockUpdateState) {
        let domain = "AppUpdaterDownloadTests.\(UUID().uuidString)"
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: currentVersion,
            assetName: assetName,
            schedulerIdentifier: domain,
            betaChannelProvider: { false }
        )
        return (updater, MockUpdateState())
    }

    /// Makes an `AvailableRelease` with a matching `App.zip` asset but a nil
    /// `signatureURL`.
    private func releaseWithNilSignature(tagName: String = "v2.0.0") throws -> AvailableRelease {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        return AvailableRelease(tagName: tagName, assets: [asset], signatureURL: nil)
    }

    // MARK: - No matching asset → phase stays .idle

    /// A release whose assets list contains no file matching `assetName` must
    /// leave the phase at `.idle` — no phase transitions fire.
    @Test func noMatchingAsset_phaseStaysIdle() async throws {
        let (updater, state) = makeUpdater()
        let asset = ReleaseAsset(
            name: "WrongName.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/WrongName.zip"))
        )
        let release = AvailableRelease(tagName: "v2.0.0", assets: [asset], signatureURL: nil)

        await updater.handle(release, state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }

    // MARK: - Nil signatureURL → phase stays .idle

    /// When the asset matches but `signatureURL` is nil, `handle` logs a warning
    /// and returns without applying any phase transition.
    @Test func nilSignatureURL_noPhaseTransitions() async throws {
        let (updater, state) = makeUpdater()
        await updater.handle(try releaseWithNilSignature(), state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }

    // MARK: - Multiple assets → correct one selected

    /// When a release contains multiple zips (e.g. arch-specific builds),
    /// `assetName` must select the correct one and the phase must advance to
    /// `.available`. Note: this test verifies that phase advancement occurs
    /// when the named asset is present, but it cannot assert which
    /// `browserDownloadURL` was handed to the downloader — `AppUpdater` does
    /// not expose the chosen asset URL to test code. URL-selection correctness
    /// is implicitly covered by the `noMatchingAsset_phaseStaysIdle` test
    /// (wrong name → no transition) in combination with this test (right name
    /// → transition fires).
    @Test func multipleAssets_correctAssetSelected_advancesToAvailable() async throws {
        let (updater, state) = makeUpdater(assetName: { _ in "App-arm64.zip" })

        let zipURL = updater.fixedZipURL
        try? FileManager.default.removeItem(at: zipURL)

        let arm64Asset = ReleaseAsset(
            name: "App-arm64.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App-arm64.zip"))
        )
        let x86Asset = ReleaseAsset(
            name: "App-x86_64.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App-x86_64.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [x86Asset, arm64Asset], // arm64 is second — order must not matter
            signatureURL: URL(string: "https://example.com/App-arm64.zip.sig")
        )
        await updater.handle(release, state: state)

        guard let first = state.appliedPhases.first,
              case .available(let version) = first else {
            Issue.record("Expected .available, got \(state.appliedPhases)")
            return
        }
        #expect(version == "v2.0.0")
    }

    /// When a release has multiple assets but none match `assetName`,
    /// the phase must stay `.idle` regardless of how many assets are present.
    @Test func multipleAssets_noneMatch_phaseStaysIdle() async throws {
        let (updater, state) = makeUpdater(assetName: { _ in "App-arm64.zip" })

        let assets = [
            ReleaseAsset(
                name: "App-x86_64.zip",
                browserDownloadURL: try #require(URL(string: "https://example.com/App-x86_64.zip"))
            ),
            ReleaseAsset(
                name: "App-universal.zip",
                browserDownloadURL: try #require(URL(string: "https://example.com/App-universal.zip"))
            )
        ]
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: assets,
            signatureURL: URL(string: "https://example.com/App.sig")
        )
        await updater.handle(release, state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }

    // MARK: - Cached zip fast-path → .ready

    /// When a zip already exists at `fixedZipURL`, `handle` must advance
    /// directly to `.ready` without spawning a download Task.
    @Test func cachedZip_advancesToReady() async throws {
        let (updater, state) = makeUpdater()
        let zipURL = updater.fixedZipURL
        try FileManager.default.createDirectory(
            at: zipURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("zip".utf8).write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [asset],
            signatureURL: URL(string: "https://example.com/App.zip.sig")
        )
        await updater.handle(release, state: state)

        guard case .ready(let version) = state.currentPhase else {
            Issue.record("Expected .ready, got \(state.currentPhase)")
            return
        }
        #expect(version == "v2.0.0")
        #expect(state.appliedPhases.count == 1)
    }

    // MARK: - Asset present + signatureURL present → .available then download

    /// When the asset matches and a signature URL is provided, `handle` must
    /// synchronously advance to `.available` before handing off to the download
    /// Task. We verify only the synchronous phase here.
    @Test func assetAndSignature_advancesToAvailable() async throws {
        let (updater, state) = makeUpdater()

        let zipURL = updater.fixedZipURL
        try? FileManager.default.removeItem(at: zipURL)

        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [asset],
            signatureURL: URL(string: "https://example.com/App.zip.sig")
        )
        await updater.handle(release, state: state)

        guard let first = state.appliedPhases.first,
              case .available(let version) = first else {
            Issue.record("Expected first applied phase to be .available, got \(state.appliedPhases)")
            return
        }
        #expect(version == "v2.0.0")
    }

    /// Regression: a second `handle` call while a download is in flight
    /// (zip not yet on disk). `handle` has no in-flight dedup guard by design
    /// — each call is independent and must produce its own `.available`
    /// transition. `== 2` is intentional; if someone adds a dedup guard this
    /// test will fail and the decision should be made explicitly.
    @Test func secondHandle_noZip_advancesToAvailableAgain() async throws {
        let (updater, state) = makeUpdater()

        let zipURL = updater.fixedZipURL
        try? FileManager.default.removeItem(at: zipURL)

        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.com/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v2.0.0",
            assets: [asset],
            signatureURL: URL(string: "https://example.com/App.zip.sig")
        )

        await updater.handle(release, state: state)
        await updater.handle(release, state: state)

        let availableCount = state.appliedPhases.filter {
            if case .available = $0 { return true }
            return false
        }.count
        #expect(availableCount == 2)
    }
}
