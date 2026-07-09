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
            currentVersion: "",
            betaChannel: false
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
            currentVersion: "",
            betaChannel: false
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .missingVersionKey = checkError
        else {
            Issue.record("Expected .failed(.missingVersionKey), got \(result)")
            return
        }
    }

    /// Verifies that a `.failed` fetch result propagates as
    /// `.failed(.fetchFailed(.networkError))` regardless of `currentVersion`.
    ///
    /// ## ⚠️ currentVersion: "" is intentional — ordering dependency
    ///
    /// A reviewer may expect `currentVersion: ""` to produce
    /// `.failed(.missingVersionKey)` instead. It does not, because
    /// `UpdateChecker.evaluate` checks `.failed` fetch results *before* the
    /// empty-version guard: a failed fetch is always a fetch failure regardless
    /// of what `currentVersion` contains. `emptyCurrentVersion_returnsMissingVersionKey`
    /// above covers the `.fetched(nil)` + empty version path. The two tests
    /// are complementary, not contradictory.
    @Test func failedFetchResult_returnsNetworkError() {
        let simulatedError = URLError(.notConnectedToInternet)
        let result = UpdateChecker.evaluate(
            fetchResult: .failed(.networkError(underlying: simulatedError)),
            currentVersion: "",
            betaChannel: false
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
            currentVersion: "",
            betaChannel: false
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
            currentVersion: "",
            betaChannel: false
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

    /// Pins the interim buildRequest-nil fallback behaviour: a malformed repo
    /// string causes `buildRequest` to return nil, which `fetchAndDecodeReleases`
    /// maps to `.failure(.networkError(underlying: URLError(.badURL)))` in
    /// release builds. This test exercises that exact `ReleaseFetchError` value
    /// through `UpdateChecker.evaluate` so that when issue #38 changes the
    /// return to `.configurationError`, this test fails loudly rather than
    /// letting the misclassification silently persist.
    ///
    /// The test operates at the `evaluate` layer (not the `URLSession` layer)
    /// because `GitHubReleaseProvider.fetchAndDecodeReleases` constructs a live
    /// `URLSession` and cannot be injected; the evaluate path is the correct
    /// seam to pin.
    @Test func buildRequestNilFallback_networkError_badURL_roundTripsCorrectly() {
        let badURLError = URLError(.badURL)
        let result = UpdateChecker.evaluate(
            fetchResult: .failed(.networkError(underlying: badURLError)),
            currentVersion: "1.0.0",
            betaChannel: false
        )
        guard case .failed(let error) = result,
              let checkError = error as? UpdateCheckError,
              case .fetchFailed(let reason) = checkError,
              case .networkError(let underlying) = reason,
              let urlError = underlying as? URLError
        else {
            Issue.record("Expected .failed(.fetchFailed(.networkError(URLError(.badURL)))), got \(result)")
            return
        }
        #expect(urlError.code == .badURL)
    }

    // MARK: - Malformed semver

    /// A garbage `currentVersion` string with a nil-fetched release must not
    /// crash — `evaluate` must return `.upToDate` (no release to offer).
    @Test func malformedCurrentVersion_fetchedNil_returnsUpToDate() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(nil),
            currentVersion: "not-a-version",
            betaChannel: false
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
            currentVersion: "not-a-version",
            betaChannel: false
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
            currentVersion: "1.0.0",
            betaChannel: false
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

    // MARK: - Channel downgrade (issue #41)

    /// Primary regression case for issue #41.
    ///
    /// User is on v1.0.0-beta.1 (pre-release, semver-ahead of stable).
    /// They toggle betaChannel off. Latest stable is v0.9.9.
    /// isNewer("v0.9.9", than: "v1.0.0-beta.1") is false (major 0 < 1),
    /// so without the channel-downgrade guard the result would be .upToDate
    /// and the user would be stranded forever. With the guard, .updateAvailable
    /// is returned unconditionally because betaChannel == false && currentVersion
    /// is a pre-release.
    @Test func betaOff_prereleaseCurrent_stableAvailable_returnsUpdateAvailable() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release(tag: "v0.9.9")),
            currentVersion: "v1.0.0-beta.1",
            betaChannel: false
        )
        guard case .updateAvailable(let offered) = result else {
            Issue.record("Expected .updateAvailable(v0.9.9) for channel downgrade, got \(result)")
            return
        }
        #expect(offered.tagName == "v0.9.9")
    }

    /// Confirms the channel-downgrade guard does NOT fire when betaChannel == true.
    ///
    /// User is on v1.0.0-beta.1 with beta enabled. Latest is v0.9.9 (stable,
    /// which would only be returned by latestMatchingRelease if no beta exists,
    /// but we test evaluate in isolation). isNewer("v0.9.9", than: "v1.0.0-beta.1")
    /// is false, so .upToDate is the correct result — the guard must not fire.
    @Test func betaOn_prereleaseCurrent_olderStableAvailable_returnsUpToDate() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release(tag: "v0.9.9")),
            currentVersion: "v1.0.0-beta.1",
            betaChannel: true
        )
        guard case .upToDate = result else {
            Issue.record("Expected .upToDate when betaChannel=true and current is ahead, got \(result)")
            return
        }
    }

    /// Confirms the channel-downgrade guard does NOT fire for a stable currentVersion.
    ///
    /// User is on v1.0.0 stable with beta off. Latest stable is v0.9.9.
    /// isNewer returns false — .upToDate is correct. The guard checks
    /// isPrerelease first, so a stable currentVersion never triggers it.
    @Test func betaOff_stableCurrent_olderStableAvailable_returnsUpToDate() {
        let result = UpdateChecker.evaluate(
            fetchResult: .fetched(release(tag: "v0.9.9")),
            currentVersion: "v1.0.0",
            betaChannel: false
        )
        guard case .upToDate = result else {
            Issue.record("Expected .upToDate when stable current is ahead, got \(result)")
            return
        }
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
