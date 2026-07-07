// GitHubReleaseProviderDecodeTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - GitHubReleaseProviderDecodeTests

/// Tests that `GitHubReleaseProvider.Release` decodes `tag_name` from GitHub
/// Releases API JSON into `tagName` without any normalisation.
///
/// ## Why this test exists
///
/// `installAndRelaunch` compares `latest.tagName != version` using raw string
/// equality for yank-revalidation. That comparison is only correct if
/// `tagName` is the exact unmodified value from the API — no leading-`v`
/// stripping, no lowercasing, no trimming.
///
/// `GitHubReleaseProvider.Release` decodes `tag_name` via a custom `CodingKeys`
/// mapping. If a normalisation step is ever added to that decoder the
/// revalidation guard silently starts producing spurious aborts or misses.
/// These tests make that regression visible by decoding raw fixture JSON
/// directly — no mocks, no network.
///
/// `Release` is `internal` (not `private`) specifically to allow this.
struct GitHubReleaseProviderDecodeTests {

    // MARK: - Helpers

    /// Minimal valid GitHub Releases API JSON for a single release.
    /// `assets` is empty — asset parsing is not under test here.
    private func releaseJSON(tagName: String, prerelease: Bool = false) -> Data {
        let json = """
        [{
            "tag_name": "\(tagName)",
            "prerelease": \(prerelease),
            "assets": []
        }]
        """
        return Data(json.utf8)
    }

    // MARK: - CodingKeys mapping

    /// The `tag_name` JSON key maps to `tagName` via `CodingKeys` and the
    /// value is returned verbatim — a `v`-prefixed semver tag is not modified.
    @Test func decode_vPrefixedSemver_tagNameIsUnmodified() throws {
        let data = releaseJSON(tagName: "v1.2.3")
        let releases = try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: data)
        let release = try #require(releases.first)
        // This is the load-bearing assertion: if the decoder ever normalises
        // tagName (e.g. strips the leading "v"), this test will catch it before
        // the regression reaches installAndRelaunch. Do NOT change the expected
        // value to a stripped form.
        #expect(release.tagName == "v1.2.3")
    }

    /// A tag without a `v` prefix decodes verbatim — the decoder does not add
    /// a prefix.
    @Test func decode_noVPrefix_tagNameIsUnmodified() throws {
        let data = releaseJSON(tagName: "1.2.3")
        let releases = try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: data)
        let release = try #require(releases.first)
        #expect(release.tagName == "1.2.3")
    }

    /// A pre-release tag with beta suffix decodes verbatim.
    @Test func decode_betaSuffix_tagNameIsUnmodified() throws {
        let data = releaseJSON(tagName: "v2.0.0-beta.1", prerelease: true)
        let releases = try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: data)
        let release = try #require(releases.first)
        #expect(release.tagName == "v2.0.0-beta.1")
    }

    /// The `prerelease` field decodes correctly alongside `tag_name`.
    @Test func decode_prereleaseFlag_decodesCorrectly() throws {
        let stableData = releaseJSON(tagName: "v1.0.0", prerelease: false)
        let betaData   = releaseJSON(tagName: "v1.0.0-beta.1", prerelease: true)

        let stable = try #require(try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: stableData).first)
        let beta   = try #require(try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: betaData).first)

        #expect(stable.prerelease == false)
        #expect(beta.prerelease == true)
    }

    /// Decoding fails gracefully when `tag_name` is absent — `Release` is not
    /// constructed with a default empty string.
    @Test func decode_missingTagName_throws() {
        let json = Data("""
        [{ "prerelease": false, "assets": [] }]
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: json)
        }
    }
}
