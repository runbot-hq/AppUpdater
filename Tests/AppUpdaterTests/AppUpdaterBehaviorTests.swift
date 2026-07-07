// AppUpdaterBehaviorTests.swift
// AppUpdater
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterCheckAndHandleTests

/// Exercises `AppUpdater.checkForUpdate(betaChannel:)` in isolation using
/// `MockReleaseProvider` — no network, no disk I/O.
@MainActor
@Suite("AppUpdater.checkAndHandle")
struct AppUpdaterCheckAndHandleTests {

    private let newerTag = "v2.0.0"
    private let olderTag = "v0.9.0"
    private let currentVersion = "1.0.0"

    /// Builds an `AppUpdater` wired to `provider` with an isolated
    /// scheduler identifier.
    private func makeUpdater(
        domain: String,
        provider: some ReleaseProvider,
        betaChannelProvider: @escaping () -> Bool = { false }
    ) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: currentVersion,
            assetName: { _ in "RunBot.zip" },
            schedulerIdentifier: domain,
            betaChannelProvider: betaChannelProvider,
            releaseProvider: provider
        )
    }

    /// Minimal `AvailableRelease` fixture — no assets, no checksum URL.
    private func release(tag: String) -> AvailableRelease {
        AvailableRelease(tagName: tag, assets: [], checksumURL: nil)
    }

    // MARK: - 1. Provider returns .failed → .failed(.noReleasesFound)

    @Test func providerReturnsNil_failedNoReleasesFound() async throws {
        let domain = "test.check.nil.\(UUID().uuidString)"
        let provider = MockReleaseProvider(fetchResultToReturn: .failed)
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              checkError == .noReleasesFound else {
            Issue.record("Expected .failed(.noReleasesFound), got \(result)")
            return
        }
    }

    // MARK: - 1b. Provider returns .fetched(nil) → .upToDate

    @Test func providerReturnsFetchedNil_upToDate() async throws {
        let domain = "test.check.fetchednil.\(UUID().uuidString)"
        let provider = MockReleaseProvider(fetchResultToReturn: .fetched(nil))
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .upToDate = result else {
            Issue.record("Expected .upToDate for no-channel-match, got \(result)")
            return
        }
    }

    // MARK: - 2. Provider returns release that is NOT newer → .upToDate

    @Test func providerReturnsOlderVersion_upToDate() async throws {
        let domain = "test.check.older.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: release(tag: olderTag))
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .upToDate = result else {
            Issue.record("Expected .upToDate, got \(result)")
            return
        }
    }

    // MARK: - 3. Provider returns newer release → .updateAvailable

    @Test func providerReturnsNewerVersion_updateAvailable() async throws {
        let domain = "test.check.newer.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: release(tag: newerTag))
        let updater = makeUpdater(domain: domain, provider: provider)

        let result = await updater.checkForUpdate(betaChannel: false)

        guard case .updateAvailable(let r) = result else {
            Issue.record("Expected .updateAvailable, got \(result)")
            return
        }
        #expect(r.tagName == newerTag)
    }

    // MARK: - 4. betaChannel=false forwarded to provider

    @Test func betaChannelFalse_passedToProvider() async throws {
        let domain = "test.check.beta.false.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: false)

        let captured = await provider.capturedBetaChannel
        #expect(captured == false)
    }

    // MARK: - 5. betaChannel=true forwarded to provider

    @Test func betaChannelTrue_passedToProvider() async throws {
        let domain = "test.check.beta.true.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: true)

        let captured = await provider.capturedBetaChannel
        #expect(captured == true)
    }

    // MARK: - 6. fetchLatestRelease called exactly once per checkForUpdate

    @Test func callCount_exactlyOnePerCheck() async throws {
        let domain = "test.check.callcount.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        let updater = makeUpdater(domain: domain, provider: provider)

        _ = await updater.checkForUpdate(betaChannel: false)

        let count = await provider.callCount
        #expect(count == 1)
    }

    // MARK: - 7. betaChannelProvider closure call timing

    /// Verifies the `betaChannelProvider` closure is invoked fresh on each
    /// `checkForUpdate` call rather than being captured once at init.
    ///
    /// The closure toggles from `false` on the first call to `true` on the
    /// second. If the value were captured at init, both provider calls would
    /// see `false`. If the closure is called each time, the second call sees
    /// `true`.
    @Test func betaChannelProvider_calledOnEachCheck() async throws {
        let domain = "test.check.provider.timing.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        var callCount = 0
        let updater = makeUpdater(domain: domain, provider: provider, betaChannelProvider: {
            callCount += 1
            return callCount > 1 // false on first call, true on second
        })

        _ = await updater.checkForUpdate(betaChannel: false)
        let firstCaptured = await provider.capturedBetaChannel

        _ = await updater.checkForUpdate(betaChannel: false)
        let secondCaptured = await provider.capturedBetaChannel

        // First call: closure returns false (callCount == 1)
        #expect(firstCaptured == false)
        // Second call: closure returns true (callCount == 2) — proves it was invoked again
        #expect(secondCaptured == true)
    }

    /// Verifies the closure is invoked exactly once per `checkForUpdate` call
    /// — not zero times (value captured at init) and not multiple times
    /// (called redundantly within a single check).
    @Test func betaChannelProvider_calledOncePerCheck() async throws {
        let domain = "test.check.provider.callcount.\(UUID().uuidString)"
        let provider = MockReleaseProvider(releaseToReturn: nil)
        var closureCallCount = 0
        let updater = makeUpdater(domain: domain, provider: provider, betaChannelProvider: {
            closureCallCount += 1
            return false
        })

        _ = await updater.checkForUpdate(betaChannel: false)
        #expect(closureCallCount == 1)

        _ = await updater.checkForUpdate(betaChannel: false)
        #expect(closureCallCount == 2)
    }
}
