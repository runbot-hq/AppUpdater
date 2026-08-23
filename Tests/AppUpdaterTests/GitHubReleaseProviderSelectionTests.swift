// GitHubReleaseProviderSelectionTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - GitHubReleaseProviderSelectionTests

/// Channel-selection contract for `GitHubReleaseProvider.latestMatchingRelease(from:betaChannel:)`.
///
/// Channels are mutually exclusive: beta channel returns only prereleases,
/// stable channel returns only stable releases. The matrix locks in that
/// contract, including the regression from runbot-hq/run-bot#2715 where
/// stable `v0.7.9` was incorrectly offered to a beta user over `v0.7.9-beta.71`.
struct GitHubReleaseProviderSelectionTests {

    // MARK: - Fixtures

    private struct ReleaseFixture {
        let tag: String
        let prerelease: Bool
    }

    private struct SelectionCase {
        let label: String
        let releases: [ReleaseFixture]
        let betaChannel: Bool
        let expectedTag: String?
    }

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

    // MARK: - Channel selection contract

    @Test func channelSelectionContract() throws {
        let cases: [SelectionCase] = [
            SelectionCase(
                label: "beta regression ignores stable",
                releases: [
                    .init(tag: "v0.7.9", prerelease: false),
                    .init(tag: "v0.7.9-beta.71", prerelease: true),
                    .init(tag: "v0.7.9-beta.70", prerelease: true)
                ],
                betaChannel: true,
                expectedTag: "v0.7.9-beta.71"
            ),
            SelectionCase(
                label: "stable ignores newer beta",
                releases: [
                    .init(tag: "v0.8.0-beta.1", prerelease: true),
                    .init(tag: "v0.7.9", prerelease: false)
                ],
                betaChannel: false,
                expectedTag: "v0.7.9"
            ),
            SelectionCase(
                label: "stable with only betas",
                releases: [.init(tag: "v0.7.9-beta.71", prerelease: true)],
                betaChannel: false,
                expectedTag: nil
            ),
            SelectionCase(
                label: "beta with only stable",
                releases: [.init(tag: "v0.7.9", prerelease: false)],
                betaChannel: true,
                expectedTag: nil
            ),
            SelectionCase(
                label: "newest beta selected",
                releases: [
                    .init(tag: "v0.7.9-beta.70", prerelease: true),
                    .init(tag: "v0.7.9-beta.72", prerelease: true),
                    .init(tag: "v0.7.9-beta.71", prerelease: true)
                ],
                betaChannel: true,
                expectedTag: "v0.7.9-beta.72"
            ),
            SelectionCase(
                label: "empty stable",
                releases: [],
                betaChannel: false,
                expectedTag: nil
            ),
            SelectionCase(
                label: "empty beta",
                releases: [],
                betaChannel: true,
                expectedTag: nil
            )
        ]

        for testCase in cases {
            let releases = try testCase.releases.map { fixture in
                try release(fixture.tag, prerelease: fixture.prerelease)
            }
            let result = provider.latestMatchingRelease(from: releases, betaChannel: testCase.betaChannel)
            #expect(result?.tagName == testCase.expectedTag, Comment(rawValue: testCase.label))
        }
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
            release("v0.9.9", prerelease: false),
            release("v1.0.0-beta.2", prerelease: true),
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
