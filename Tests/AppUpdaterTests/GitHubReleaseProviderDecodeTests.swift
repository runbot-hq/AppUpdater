// GitHubReleaseProviderDecodeTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - GitHubReleaseProviderDecodeTests

/// Decoding contract for `GitHubReleaseProvider.Release`.
///
/// `installAndRelaunch` compares `latest.tagName != version` using raw string
/// equality for yank-revalidation, so `tagName` must be the exact unmodified
/// value from the API — no leading-`v` stripping, no lowercasing, no trimming.
/// If a normalisation step is ever added to the decoder the revalidation guard
/// silently starts producing spurious aborts or misses.
///
/// `Release` is `internal` (not `private`) specifically to allow this.
@Suite("GitHub release decoding")
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

    @Test
    func decodingContract() throws {
        struct Case {
            let tagName: String
            let prerelease: Bool
        }

        let cases: [Case] = [
            Case(tagName: "v1.2.3", prerelease: false),
            Case(tagName: "1.2.3", prerelease: false),
            Case(tagName: "v2.0.0-beta.1", prerelease: true)
        ]

        for testCase in cases {
            let data = releaseJSON(
                tagName: testCase.tagName,
                prerelease: testCase.prerelease
            )

            let releases = try JSONDecoder().decode(
                [GitHubReleaseProvider.Release].self,
                from: data
            )

            let release = try #require(releases.first)

            // Load-bearing assertion: if the decoder ever normalises tagName
            // (e.g. strips the leading "v"), this fails before the regression
            // reaches installAndRelaunch. Do NOT change expected to stripped form.
            #expect(
                release.tagName == testCase.tagName,
                "tag=\(testCase.tagName)"
            )
            #expect(
                release.prerelease == testCase.prerelease,
                "tag=\(testCase.tagName)"
            )
        }
    }

    /// Decoding fails when `tag_name` is absent — `Release` is not constructed
    /// with a default empty string, so decoding a payload missing the required
    /// field must produce an error.
    @Test func missingTagNameThrows() {
        let json = Data("""
        [{ "prerelease": false, "assets": [] }]
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([GitHubReleaseProvider.Release].self, from: json)
        }
    }
}
