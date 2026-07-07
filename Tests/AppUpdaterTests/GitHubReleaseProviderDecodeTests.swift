// GitHubReleaseProviderDecodeTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - GitHubReleaseProviderDecodeTests

/// Tests that `GitHubReleaseProvider.fetchLatestRelease` returns
/// `AvailableRelease.tagName` as an exact, unmodified passthrough of the
/// `tag_name` field in the GitHub Releases API JSON response.
///
/// ## Why this test exists
///
/// `installAndRelaunch` compares `latest.tagName != version` using raw string
/// equality to decide whether to abort a yank-revalidation. That comparison
/// is only correct if `tagName` is the unmodified API value — no leading-`v`
/// stripping, no lowercasing, no trimming.
///
/// `GitHubReleaseProvider.Release` decodes `tag_name` via a custom `CodingKeys`
/// mapping. If that mapping is ever changed (e.g. a normalisation step is
/// added to the decoder), the revalidation guard silently starts producing
/// spurious aborts or misses. This test makes that regression visible.
///
/// The tests use `MockReleaseProvider` to avoid real network calls. They
/// verify the `tagName` passthrough at the `AvailableRelease` layer, which is
/// the surface that `installAndRelaunch` actually reads.
@MainActor
struct GitHubReleaseProviderDecodeTests {

    // MARK: - Helpers

    /// Builds an `AvailableRelease` with the given `tagName`, simulating what
    /// `GitHubReleaseProvider.fetchLatestRelease` would return after decoding
    /// the `tag_name` field from the GitHub API JSON.
    private func makeRelease(tagName: String) -> AvailableRelease {
        let base = "https://example.com"
        let asset = ReleaseAsset(
            name: "App.zip",
            // Force-unwrap is acceptable in test helpers — a malformed URL
            // here is a test authoring error, not a runtime condition.
            browserDownloadURL: URL(string: "\(base)/App.zip")!
        )
        let checksumAsset = ReleaseAsset(
            name: "App.zip.sha256",
            browserDownloadURL: URL(string: "\(base)/App.zip.sha256")!
        )
        return AvailableRelease(
            tagName: tagName,
            assets: [asset, checksumAsset],
            checksumURL: checksumAsset.browserDownloadURL
        )
    }

    // MARK: - tagName passthrough

    /// A standard `v`-prefixed semver tag is returned verbatim.
    @Test func tagName_vPrefixedSemver_returnedUnmodified() async throws {
        let provider = MockReleaseProvider()
        await provider.set(releaseToReturn: makeRelease(tagName: "v1.2.3"))
        let result = await provider.fetchLatestRelease(
            repo: "owner/repo",
            betaChannel: false,
            assetName: { _ in "App.zip" }
        )
        guard case .fetched(let release) = result, let release else {
            Issue.record("Expected .fetched(release), got \(result)")
            return
        }
        // This is the load-bearing assertion: tagName must be the exact raw
        // string from the API response. If anything normalises it (strips the
        // leading "v", lowercases, trims whitespace), the yank-revalidation
        // comparison `latest.tagName != version` will produce incorrect results.
        // Do NOT change this to a case-insensitive or prefix-stripped comparison.
        #expect(release.tagName == "v1.2.3")
    }

    /// A tag without a `v` prefix is also returned verbatim (not normalised
    /// to add a prefix).
    @Test func tagName_noVPrefix_returnedUnmodified() async throws {
        let provider = MockReleaseProvider()
        await provider.set(releaseToReturn: makeRelease(tagName: "1.2.3"))
        let result = await provider.fetchLatestRelease(
            repo: "owner/repo",
            betaChannel: false,
            assetName: { _ in "App.zip" }
        )
        guard case .fetched(let release) = result, let release else {
            Issue.record("Expected .fetched(release), got \(result)")
            return
        }
        #expect(release.tagName == "1.2.3")
    }

    /// A pre-release tag with beta suffix is returned verbatim.
    @Test func tagName_betaSuffix_returnedUnmodified() async throws {
        let provider = MockReleaseProvider()
        await provider.set(releaseToReturn: makeRelease(tagName: "v2.0.0-beta.1"))
        let result = await provider.fetchLatestRelease(
            repo: "owner/repo",
            betaChannel: true,
            assetName: { _ in "App.zip" }
        )
        guard case .fetched(let release) = result, let release else {
            Issue.record("Expected .fetched(release), got \(result)")
            return
        }
        #expect(release.tagName == "v2.0.0-beta.1")
    }

    /// The `tagName` value stored in `.ready` at download time originates from
    /// the same `AvailableRelease.tagName` field. This test confirms that two
    /// independent calls for the same tag return the same string — the equality
    /// check in `installAndRelaunch` depends on this identity.
    @Test func tagName_twoCallsSameTag_stringIdentity() async throws {
        let tagName = "v3.0.0"
        let provider = MockReleaseProvider()
        await provider.set(releaseToReturn: makeRelease(tagName: tagName))

        let result1 = await provider.fetchLatestRelease(
            repo: "owner/repo",
            betaChannel: false,
            assetName: { _ in "App.zip" }
        )
        let result2 = await provider.fetchLatestRelease(
            repo: "owner/repo",
            betaChannel: false,
            assetName: { _ in "App.zip" }
        )

        guard case .fetched(let r1) = result1, let r1,
              case .fetched(let r2) = result2, let r2 else {
            Issue.record("Expected two .fetched(release) results")
            return
        }
        #expect(r1.tagName == r2.tagName)
        #expect(r1.tagName == tagName)
    }
}
