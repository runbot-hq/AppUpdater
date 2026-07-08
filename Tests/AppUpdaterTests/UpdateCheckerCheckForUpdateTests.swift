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
@Suite("UpdateChecker.evaluate")
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

    /// Builds a minimal `AvailableRelease` with a custom tag and no assets.
    private func release(tag: String) -> AvailableRelease {
        AvailableRelease(tagName: tag, assets: [], checksumURL: nil)
    }

    // MARK: - missingVersionKey

    @Test func emptyCurrentVersion_returnsMissingVersionKey() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(nil),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .missingVersionKey = checkError
        else {
            Issue.record("Expected .failed(.missingVersionKey), got \(result)")
            return
        }
    }

    @Test func fetchedNonNilRelease_emptyVersion_returnsMissingVersionKey() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .missingVersionKey = checkError
        else {
            Issue.record("Expected .failed(.missingVersionKey), got \(result)")
            return
        }
    }

    @Test func failedFetchResult_returnsNetworkError() {
        let simulatedError = URLError(.notConnectedToInternet)
        let result = UpdateChecker.evaluate(
            fetchResult: .failed(.networkError(underlying: simulatedError)),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .fetchFailed(let reason) = checkError,
              case .networkError = reason
        else {
            Issue.record("Expected .failed(.fetchFailed(.networkError)), got \(result)")
            return
        }
    }

    @Test func failedFetchResult_returnsHttpError() {
        let result = UpdateChecker.evaluate(
            fetchResult: .failed(.httpError(statusCode: 429)),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .fetchFailed(let reason) = checkError,
              case .httpError(let statusCode) = reason
        else {
            Issue.record("Expected .failed(.fetchFailed(.httpError)), got \(result)")
            return
        }
        #expect(statusCode == 429)
    }

    @Test func failedFetchResult_returnsDecodingError() {
        let simulatedError = DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "fixture decode failure")
        )
        let result = UpdateChecker.evaluate(
            fetchResult: .failed(.decodingError(underlying: simulatedError)),
            currentVersion: ""
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .fetchFailed(let reason) = checkError,
              case .decodingError = reason
        else {
            Issue.record("Expected .failed(.fetchFailed(.decodingError)), got \(result)")
            return
        }
    }

    // MARK: - Malformed semver

    /// A garbage `currentVersion` string with a nil-fetched release must not
    /// crash — `evaluate` must return `.upToDate` (no release to offer).
    @Test func malformedCurrentVersion_fetchedNil_returnsUpToDate() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(nil),
            currentVersion: "not-a-version"
        )
        guard case .upToDate = result else {
            Issue.record("Expected .upToDate for malformed currentVersion with nil release, got \(result)")
            return
        }
    }

    /// A garbage `currentVersion` with a valid release tag must not crash.
    /// `ParsedVersion` returns `nil` for non-semver input and `isNewer` treats
    /// a nil current version as `0.0.0`, so any parseable release tag wins and
    /// `evaluate` returns `.updateAvailable`. This pins that production
    /// fallback; a deliberate change to return `.failed` instead would require
    /// updating this test and `ParsedVersion` together.
    @Test func malformedCurrentVersion_withValidRelease_returnsUpdateAvailable() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release(tag: "v2.0.0")),
            currentVersion: "not-a-version"
        )
        guard case .updateAvailable = result else {
            Issue.record("Expected .updateAvailable for malformed currentVersion with valid tag, got \(result)")
            return
        }
    }

    /// A garbage release `tagName` with a valid `currentVersion` must not crash.
    /// `ParsedVersion` returns `nil` for the tag, so `isNewer` treats it as
    /// `0.0.0` — which can never beat a real version — and `evaluate` returns
    /// `.upToDate`.
    @Test func malformedReleaseTag_validCurrentVersion_returnsUpToDate() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release(tag: "not-a-version")),
            currentVersion: "1.0.0"
        )
        guard case .upToDate = result else {
            Issue.record("Expected .upToDate for malformed release tag, got \(result)")
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
        #expect(UpdateChecker.isNewer(release.tagName, than: "1.0.0"))
    }

    // MARK: - Semver guard

    @Test func fixtureNewer_v200_notNewerThanItself() throws {
        let release = try #require(try firstRelease(fromFixture: "releases.newer"))
        #expect(UpdateChecker.isNewer(release.tagName, than: "2.0.0") == false)
    }
}

// MARK: - FixtureRelease

/// A minimal Decodable mirror of the JSON fixture shape.
private struct FixtureRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case assets
    }
}
