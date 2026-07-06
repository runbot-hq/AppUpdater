// UpdateModels.swift
// AppUpdater
import Foundation

// MARK: - ReleaseAsset

/// A single asset attached to a GitHub Release (e.g. `RunBot.zip`).
public struct ReleaseAsset: Decodable, Sendable {
    /// The filename of the asset as it appears on the release page.
    public let name: String
    /// The direct download URL for this asset.
    public let browserDownloadURL: URL

    /// Maps Swift property names to the GitHub API's snake_case JSON keys.
    enum CodingKeys: String, CodingKey {
        /// Maps to the JSON key `"name"`.
        case name
        /// Maps to the GitHub API JSON key `"browser_download_url"`.
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - AvailableRelease

/// A decoded GitHub Release, carrying the tag name and asset list.
public struct AvailableRelease: Sendable {
    /// The git tag of this release (e.g. `"v0.8.0"` or `"v0.8.0-beta.1"`).
    public let tagName: String
    /// The list of binary assets attached to this release.
    public let assets: [ReleaseAsset]
    /// The URL of the SHA-256 checksum sidecar asset, or `nil` if absent.
    public let checksumURL: URL?
}

// MARK: - UpdateCheckResult

/// The result of an `UpdateChecker.checkForUpdate(...)` call.
public enum UpdateCheckResult: Sendable {
    /// The running version is already the latest eligible version.
    case upToDate
    /// A newer eligible release was found.
    case updateAvailable(release: AvailableRelease)
    /// The check could not complete due to the associated error.
    case failed(Error)
}

// MARK: - UpdateCheckError

/// Errors produced by `UpdateChecker` and `AppUpdater.checkForUpdate`.
public enum UpdateCheckError: Error, Sendable {
    /// The `currentVersion` string supplied to the checker was empty.
    case missingVersionKey
    /// The releases API request failed, the HTTP response was non-200, or
    /// the response body could not be decoded. This does not mean
    /// "no channel match" — when releases exist but none match the requested
    /// channel the result is `.upToDate`, not this error.
    ///
    /// ⚠️ Known conflation: `GitHubReleaseProvider.fetchLatestRelease`
    /// returns `nil` for both a genuine network failure AND a successful
    /// fetch where no release matched the channel. The instance-level
    /// `AppUpdater.checkForUpdate` maps both to this case. In practice
    /// this means: if a user disables beta channel and no stable release
    /// exists yet, the background scheduler treats it as a network failure
    /// and preserves `.ready` state rather than clearing it. This is an
    /// accepted limitation — RunBot always has stable releases, so the
    /// degenerate case (beta-only repo, user on stable channel) does not
    /// apply. If that ever changes, split the nil return into a typed
    /// result so the two cases can be handled separately.
    ///
    /// Known limitation: nil is returned for network errors, rate-limits (HTTP 429/403),
    /// and genuine no-match — all three become .failed(.noReleasesFound). The UI cannot
    /// distinguish "offline" from "up to date". Tracked in issue #1878.
    case noReleasesFound
}
