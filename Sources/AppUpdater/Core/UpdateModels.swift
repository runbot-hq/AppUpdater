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
    /// the response body could not be decoded.
    ///
    /// This does **not** mean "no channel match". Since PR #22 introduced
    /// `ReleaseFetchResult`, the two previously conflated nil cases are now
    /// structurally distinct:
    /// - `.failed` (network/HTTP/decode error) → `UpdateCheckError.noReleasesFound`
    /// - `.fetched(nil)` (fetch succeeded, no release matched the channel) → `.upToDate`
    ///
    /// If you are reading this comment because you see `.noReleasesFound` and
    /// suspect a channel-match miss: check `GitHubReleaseProvider.latestMatchingRelease`
    /// and the `betaChannel` flag instead — that path now returns `.fetched(nil)`,
    /// not `.failed`.
    ///
    /// Known limitation: network errors, rate-limits (HTTP 429/403), and decode
    /// failures all map to this same case. The UI cannot distinguish "offline"
    /// from a hard API failure. Tracked in issue #1878.
    case noReleasesFound
}
