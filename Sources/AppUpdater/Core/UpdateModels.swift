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

// MARK: - ReleaseFetchError

/// The specific reason a release fetch failed.
///
/// Carried by `ReleaseFetchResult.failed` and `UpdateCheckError.fetchFailed`
/// to let callers distinguish connectivity problems from API-level rejections
/// and data errors.
public enum ReleaseFetchError: Error, Sendable {
    /// The network request itself could not be completed (device offline, DNS
    /// failure, timeout, etc.). The underlying `URLSession` error is attached.
    case networkError(underlying: Error)
    /// The GitHub API returned a non-200 HTTP status code (e.g. 403 Forbidden,
    /// 429 Too Many Requests, 500 Internal Server Error).
    case httpError(statusCode: Int)
    /// The HTTP response body could not be decoded as the expected releases array.
    case decodingError(underlying: Error)
}

// MARK: - UpdateCheckError

/// Errors produced by `UpdateChecker` and `AppUpdater.checkForUpdate`.
public enum UpdateCheckError: Error, Sendable {
    /// The `currentVersion` string supplied to the checker was empty.
    case missingVersionKey
    /// The release fetch failed with a structured error describing the root cause.
    ///
    /// Use the associated `ReleaseFetchError` to present a meaningful message:
    /// - `.networkError` → the device is likely offline or the request timed out.
    /// - `.httpError(429)` / `.httpError(403)` → GitHub rate-limit or auth failure.
    /// - `.httpError(let code)` → other API-level failure.
    /// - `.decodingError` → unexpected response shape; worth logging for diagnosis.
    ///
    /// Note: this replaces the previous `.noReleasesFound` case, which conflated
    /// all three failure modes. See issue #31 for background.
    case fetchFailed(ReleaseFetchError)

    /// Deprecated. Retained as a real enum case (not a static property) so that
    /// existing callers using `case .noReleasesFound:` in switch/guard statements
    /// continue to compile with a deprecation warning rather than a hard error.
    ///
    /// Migrate to `case .fetchFailed(let reason):` and branch on `ReleaseFetchError`
    /// sub-cases for actionable failure handling. This case will be removed in a
    /// future minor version.
    @available(*, deprecated, renamed: "fetchFailed")
    case noReleasesFound
}
