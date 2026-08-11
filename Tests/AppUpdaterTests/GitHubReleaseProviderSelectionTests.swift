// GitHubReleaseProviderSelectionTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - GitHubReleaseProviderSelectionTests

/// Tests for `GitHubReleaseProvider.latestMatchingRelease(from:betaChannel:)`.
///
/// Channels are mutually exclusive: beta channel returns only prereleases,
/// stable channel returns only stable releases. These tests lock in that
/// contract and cover the specific regression from runbot-hq/run-bot#2715
/// where stable `v0.7.9` was incorrectly offered to a beta user over
/// `v0.7.9-beta.71`.
struct GitHubReleaseProviderSelectionTests {

    // MARK: - Helpers

    private let provider = GitHubReleaseProvider()

    /// Builds a minimal `GitHubReleaseProvider.Release` from raw JSON so tests
    /// use the real `Decodable` path rather than a hand-rolled initialiser.
    private func release(_ tagName: String, prerelease: Bool) throws -> GitHubReleaseProvider.Release {
        let json = """
        [{"tag_name": "\(tagName)", "prerelease": \(prerelease), "assets": []}]
        """
        return try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: Data(json.utf8))[0]
    }

    // MARK: - Reported regression (run-bot#2715)

    /// Beta channel must select the newest prerelease and ignore a stable
    /// release that has higher SemVer precedence.
    ///
    /// Regression fixture: installed `v0.7.9-beta.70`, available
    /// `v0.7.9-beta.71` and `v0.7.9`. Without the channel filter, SemVer
    /// sort promotes `v0.7.9` first. With the filter only prereleases are
    /// candidates, so `v0.7.9-beta.71` is selected.
    @Test func betaChannel_selectsNewestPrerelease_ignoresStable() throws {
        let releases = try [
            release("v0.7.9",         prerelease: false),
            release("v0.7.9-beta.71", prerelease: true),
            release("v0.7.9-beta.70", prerelease: true),
        ]
        let result = provider.latestMatchingRelease(from: releases, betaChannel: true)
        #expect(result?.tagName == "v0.7.9-beta.71")
    }

    // MARK: - Stable channel

    /// Stable channel selects the stable release from the same fixture.
    @Test func stableChannel_selectsStableRelease() throws {
        let releases = try [
            release("v0.7.9",         prerelease: false),
            release("v0.7.9-beta.71", prerelease: true),
            release("v0.7.9-beta.70", prerelease: true),
        ]
        let result = provider.latestMatchingRelease(from: releases, betaChannel: false)
        #expect(result?.tagName == "v0.7.9")
    }

    /// Stable channel ignores a prerelease that is numerically newer.
    @Test func stableChannel_ignoresNumericallyNewerPrerelease() throws {
        let releases = try [
            release("v0.8.0-beta.1", prerelease: true),
            release("v0.7.9",        prerelease: false),
        ]
        let result = provider.latestMatchingRelease(from: releases, betaChannel: false)
        #expect(result?.tagName == "v0.7.9")
    }

    /// Stable channel with only prereleases returns nil.
    @Test func stableChannel_onlyPrereleases_returnsNil() throws {
        let releases = try [
            release("v0.7.9-beta.71", prerelease: true),
            release("v0.7.9-beta.70", prerelease: true),
        ]
        let result = provider.latestMatchingRelease(from: releases, betaChannel: false)
        #expect(result == nil)
    }

    // MARK: - Beta channel

    /// Beta channel with only stable releases returns nil.
    /// This locks in the product decision: beta means beta-only, not
    /// "early access plus stable".
    @Test func betaChannel_onlyStableReleases_returnsNil() throws {
        let releases = try [
            release("v0.7.9", prerelease: false),
            release("v0.7.8", prerelease: false),
        ]
        let result = provider.latestMatchingRelease(from: releases, betaChannel: true)
        #expect(result == nil)
    }

    /// Beta channel selects the newest among multiple prereleases.
    @Test func betaChannel_multiplePrereleases_selectsNewest() throws {
        let releases = try [
            release("v0.7.9-beta.70", prerelease: true),
            release("v0.7.9-beta.72", prerelease: true),
            release("v0.7.9-beta.71", prerelease: true),
        ]
        let result = provider.latestMatchingRelease(from: releases, betaChannel: true)
        #expect(result?.tagName == "v0.7.9-beta.72")
    }

    // MARK: - Empty input

    /// Empty release list returns nil for both channels.
    @Test func emptyReleases_betaChannel_returnsNil() {
        let result = provider.latestMatchingRelease(from: [], betaChannel: true)
        #expect(result == nil)
    }

    @Test func emptyReleases_stableChannel_returnsNil() {
        let result = provider.latestMatchingRelease(from: [], betaChannel: false)
        #expect(result == nil)
    }

    // MARK: - Composed: provider → evaluate (channel downgrade)

    /// Belt-and-suspenders: pipes `latestMatchingRelease` output directly into
    /// `UpdateChecker.evaluate` to confirm the full stable-channel path offers
    /// a stable release to a user currently on a prerelease.
    ///
    /// The two layers are individually tested in isolation; this test locks
    /// their interaction so a future seam change between provider and evaluator
    /// is caught without having to trace the integration manually.
    @Test func stableChannel_offersStableToInstalledPrerelease() throws {
        let releases = try [
            release("v0.9.9",         prerelease: false),
            release("v1.0.0-beta.2",  prerelease: true),
        ]
        let candidate = provider.latestMatchingRelease(from: releases, betaChannel: false)
        let fetchResult = ReleaseFetchResult.fetched(
            candidate.map { AvailableRelease(tagName: $0.tagName, assets: $0.assets, signatureURL: nil) }
        )
        let result = UpdateChecker.evaluate(
            fetchResult: fetchResult,
            currentVersion: "v1.0.0-beta.1",
            betaChannel: false
        )
        guard case .updateAvailable(let offered) = result else {
            Issue.record("Expected .updateAvailable(v0.9.9) for stable-channel downgrade, got \(result)")
            return
        }
        #expect(offered.tagName == "v0.9.9")
    }
}
