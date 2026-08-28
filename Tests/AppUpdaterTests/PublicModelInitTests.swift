// PublicModelInitTests.swift
// AppUpdaterTests
import Foundation
import Testing

// NOTE: this file deliberately does NOT use `@testable import`. A plain
// `import AppUpdater` sees only the public API surface, which is what makes
// this a real regression test for issue #69 (D1): before the public
// initialisers were added, `AvailableRelease` and `ReleaseAsset` could not be
// constructed outside the module, so no third party could conform to the
// public `ReleaseProvider` protocol or call the public `handle(_:state:)`.
// If the initialisers are ever dropped back to `internal`, this file stops
// compiling.
import AppUpdater

// MARK: - ExternalProvider

/// A `ReleaseProvider` written the way a third-party consumer would have to
/// write one — public API only.
private struct ExternalProvider: ReleaseProvider {
    let tagName: String

    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> ReleaseFetchResult {
        let asset = ReleaseAsset(
            name: assetName(tagName),
            browserDownloadURL: URL(string: "https://example.invalid/\(assetName(tagName))")!
        )
        return .fetched(
            AvailableRelease(
                tagName: tagName,
                assets: [asset],
                signatureURL: URL(string: "https://example.invalid/\(assetName(tagName)).sig")!
            )
        )
    }
}

// MARK: - PublicModelInitTests

@Suite("Public model initialisers")
struct PublicModelInitTests {

    /// The public initialisers must exist and assign verbatim — no
    /// normalisation of `tagName`, which `installAndRelaunch`'s
    /// yank-revalidation compares by raw string equality.
    @Test func publicInitsAssignVerbatim() throws {
        let asset = ReleaseAsset(
            name: "App.zip",
            browserDownloadURL: try #require(URL(string: "https://example.invalid/App.zip"))
        )
        let release = AvailableRelease(
            tagName: "v1.2.3-beta.4",
            assets: [asset],
            signatureURL: try #require(URL(string: "https://example.invalid/App.zip.sig"))
        )

        #expect(release.tagName == "v1.2.3-beta.4", "tagName must not be normalised")
        #expect(release.assets.count == 1)
        #expect(release.assets[0].name == "App.zip")
        #expect(release.signatureURL?.lastPathComponent == "App.zip.sig")
    }

    /// A provider built entirely from public API must satisfy the protocol and
    /// round-trip a release back to the caller.
    @Test func externalProviderConformsAndReturnsRelease() async throws {
        let provider = ExternalProvider(tagName: "v9.9.9")
        let result = await provider.fetchLatestRelease(
            repo: "owner/repo",
            betaChannel: false,
            assetName: { _ in "App.zip" }
        )

        guard case .fetched(let release) = result, let release else {
            Issue.record("Expected .fetched(release), got \(result)")
            return
        }
        #expect(release.tagName == "v9.9.9")
        #expect(release.signatureURL != nil)
    }
}
