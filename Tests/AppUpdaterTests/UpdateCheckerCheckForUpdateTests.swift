// UpdateCheckerCheckForUpdateTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - UpdateCheckerCheckForUpdateTests

/// Tests for `UpdateChecker.checkForUpdate` that exercise the public
/// `UpdateCheckResult` enum using a live-decoded `AvailableRelease` built from
/// the JSON fixtures bundled under `Tests/AppUpdaterTests/Fixtures/`.
///
/// These tests stay synchronous and never touch the network: all input is
/// derived from the JSON fixtures loaded via `Bundle.module`. Zero
/// `DispatchQueue` usage (Pillar 5).
struct UpdateCheckerCheckForUpdateTests {

    // MARK: - Fixture helpers

    /// Loads the JSON at `Fixtures/<name>.json` via `Bundle.module` and
    /// decodes it as `[FixtureRelease]`.
    private func loadFixture(
        named name: String
    ) throws -> [FixtureRelease] {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "Missing fixture: Fixtures/\(name).json"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([FixtureRelease].self, from: data)
    }

    /// Decodes the first entry in the fixture and builds an `AvailableRelease`
    /// using `assetName` to find the checksum sidecar.
    private func firstRelease(
        fromFixture name: String,
        assetName: (String) -> String = { _ in "App.zip" }
    ) throws -> AvailableRelease? {
        let fixtures = try loadFixture(named: name)
        guard let first = fixtures.first else { return nil }
        let checksumAssetName = assetName(first.tagName) + ".sha256"
        let checksumAsset = first.assets.first(where: { $0.name == checksumAssetName })
        return AvailableRelease(
            tagName: first.tagName,
            assets: first.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )
    }

    // MARK: - missingVersionKey

    /// Verifies that `evaluate` returns `.missingVersionKey` when
    /// `currentVersion` is empty and the fetch succeeded (no failure).
    ///
    /// Calls `evaluate` directly with `.fetched(nil)` — purely synchronous,
    /// no network. The public `checkForUpdate` makes a real network request
    /// which fails in CI, and `.failed` takes priority over `.missingVersionKey`,
    /// so the public entry point cannot be used to test this path.
    @Test func emptyCurrentVersion_returnsMissingVersionKey() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(nil),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              checkError == .missingVersionKey else {
            Issue.record("Expected .failed(.missingVersionKey), got \(result)")
            return
        }
    }

    /// Verifies that `evaluate` returns `.missingVersionKey` when
    /// `currentVersion` is empty and a non-nil release was fetched.
    ///
    /// Pins the priority-order guarantee from the `evaluate` doc comment:
    /// `.failed` is checked first, then `currentVersion.isEmpty`. A non-nil
    /// `.fetched(release)` must not bypass the empty-version guard.
    @Test func fetchedNonNilRelease_emptyVersion_returnsMissingVersionKey() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              checkError == .missingVersionKey else {
            Issue.record("Expected .failed(.missingVersionKey), got \(result)")
            return
        }
    }

    /// Verifies that `.failed` takes priority over `currentVersion.isEmpty`.
    ///
    /// When both conditions hold — fetch failed AND `currentVersion` is empty —
    /// `evaluate` must return `.failed(.noReleasesFound)`, not
    /// `.failed(.missingVersionKey)`. This pins the priority-order guarantee
    /// documented in the `evaluate` doc comment so a future refactor cannot
    /// accidentally swap the order.
    @Test func failedFetchResult_emptyVersion_returnsNoReleasesFound() {
        let result = UpdateChecker.evaluate(
            fetchResult: .failed,
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              checkError == .noReleasesFound else {
            Issue.record("Expected .failed(.noReleasesFound), got \(result)")
            return
        }
    }

    // MARK: - Fixture: newer.json — v2.0.0, stable

    @Test func fixtureNewer_newerThan1x_decodesTagName() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        #expect(release.tagName == "v2.0.0")
    }

    @Test func fixtureNewer_checksumURLPresent() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        #expect(release.checksumURL != nil)
    }

    @Test func fixtureNewer_assetListContainsZip() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        #expect(release.assets.contains(where: { $0.name == "App.zip" }))
    }

    // MARK: - Fixture: empty.json

    @Test func fixtureEmpty_returnsNil() throws {
        let release = try firstRelease(fromFixture: "releases.empty")
        #expect(release == nil)
    }

    // MARK: - Fixture: beta.json — v2.0.0-beta.1, prerelease

    @Test func fixtureBeta_tagNameContainsBeta() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.beta"))
        #expect(release.tagName.contains("beta"))
    }

    @Test func fixtureBeta_isNewerThan100() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.beta"))
        // 2.0.0-beta.1 has a higher major than 1.0.0 — still newer.
        #expect(UpdateChecker.isNewer(release.tagName, than: "1.0.0"))
    }

    // MARK: - Semver guard: fixture-tag compared to same version is not newer

    @Test func fixtureNewer_v200_notNewerThanItself() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        #expect(UpdateChecker.isNewer(release.tagName, than: "2.0.0") == false)
    }
}

// MARK: - FixtureRelease

/// A minimal Decodable mirror of the JSON fixture shape. Decodes only the
/// fields needed by these tests; extra fields are ignored.
private struct FixtureRelease: Decodable {
    /// The git tag name (e.g. `"v2.0.0"`).
    let tagName: String
    /// `true` when GitHub has marked this as a pre-release.
    let prerelease: Bool
    /// The binary assets attached to this release.
    let assets: [ReleaseAsset]

    /// Maps Swift property names to the fixture JSON's snake_case keys.
    enum CodingKeys: String, CodingKey {
        /// Maps to `"tag_name"`.
        case tagName = "tag_name"
        /// Maps to `"prerelease"`.
        case prerelease
        /// Maps to `"assets"`.
        case assets
    }
}
