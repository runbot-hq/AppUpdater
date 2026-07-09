// AppUpdaterCheckForUpdateTests.swift
// AppUpdater
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterCheckForUpdateTests

/// Exercises `AppUpdater.checkForUpdate(betaChannel:)` in isolation using
/// `MockReleaseProvider` — no network, no disk I/O.
@MainActor
@Suite("AppUpdater.checkForUpdate")
struct AppUpdaterCheckForUpdateTests {

    private let newerTag = "v2.0.0"
    private let olderTag = "v0.9.0"
    private let currentVersion = "1.0.0"

    /// Builds an `AppUpdater` wired to `provider` with an isolated
    /// scheduler identifier.
    private func makeUpdater(
        domain: String,
        provider: some ReleaseProvider,
        betaChannelProvider: @Sendable @escaping () -> Bool = { false }
    ) -> AppUpdater {
        AppUpdater(
            repo: "example/repo",
            currentVersion: currentVersion,
            assetName: { _ in "RunBot.zip" },
            publicKey: dummyPublicKey,
            schedulerIdentifier: domain,
            betaChannelProvider: betaChannelProvider,
            releaseProvider: provider
        )
    }

    /// Minimal `AvailableRelease` fixture — no assets, no signature URL.
    private func release(tag: String) -> AvailableRelease {
        AvailableRelease(tagName: tag, assets: [], signatureURL: nil)
    }

    // MARK: - 1. Provider returns .failed → .failed(.fetchFailed(.networkError))

    @Test func providerReturnsFailed_fetchFailedNetworkError() async throws {
        let domain = "test.check.failed.\(UUID().uuidString)"
        let simulatedError = URLError(.notConnectedToInternet)
        let provider = MockReleaseProvider(
            fetchResultToReturn: .failed(.networkError(underlying: simulatedError))
        )
        let updater = makeUpdater(domain: domain, provider: provider)
        let result = await updater.checkForUpdate(betaChannel: false)
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .fetchFailed(let reason) = checkError,
              case .networkError = reason
        else {
            Issue.record("Expected .failed(.fetchFailed(.networkError)), got \(result)")
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
}
