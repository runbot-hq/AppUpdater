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
    /// The URL of the Ed25519 signature sidecar asset (`.sig`), or `nil` if absent.
    public let signatureURL: URL?
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
///
/// ## Known misclassification — .networkError for malformed repo string
///
/// In release builds, a malformed `repo` string passed to `AppUpdater.init`
/// (one that causes `URL(string:)` to return `nil`) surfaces as
/// `.networkError(underlying: URLError(.badURL))`. This is a semantic
/// mismatch — it is a configuration error, not a connectivity failure.
/// An `assertionFailure` fires in debug builds to catch this immediately.
/// A dedicated `.configurationError` case is tracked in issue #38 and will
/// correct this in a future step.
public enum ReleaseFetchError: Error, Sendable {
    /// The network request itself could not be completed (device offline, DNS
    /// failure, timeout, etc.). The underlying `URLSession` error is attached.
    ///
    /// Note: in release builds a malformed `repo` string (configuration error)
    /// also surfaces as `.networkError(underlying: URLError(.badURL))` — see
    /// the "Known misclassification" section in the `ReleaseFetchError` doc
    /// comment above. Use the `assertionFailure` in debug builds to catch this
    /// before shipping. Fix tracked in issue #38.
    ///
    /// ❌ DO NOT revert the associated value type from `any Error & Sendable`
    /// back to bare `Error`.
    ///
    /// This has been raised twice across review cycles, in opposite directions.
    /// The correct spelling is `any Error & Sendable`. Here is why:
    ///
    /// `ReleaseFetchError` is itself `Sendable`. A `Sendable` enum with a
    /// non-`Sendable` associated value is a data race — the enum can cross
    /// actor boundaries while the associated error cannot. Bare `Error` makes
    /// the `Sendable` conformance on the *enum* unchecked: Swift trusts it
    /// rather than enforcing it, so a caller constructing `.networkError` with
    /// a non-`Sendable` custom error silently violates strict concurrency
    /// without a compile-time warning. `any Error & Sendable` makes the
    /// conformance sound at the type level.
    ///
    /// All construction sites in this codebase (`URLSession` throws,
    /// `JSONDecoder` throws, `URLError(.badURL)` fallback) already produce
    /// `Sendable`-safe errors, so no call site changes are required.
    /// The `& Sendable` constraint is not restrictive in practice — it
    /// prevents a class of future bugs rather than limiting current callers.
    case networkError(underlying: any Error & Sendable)
    /// The GitHub API returned a non-200 HTTP status code (e.g. 403 Forbidden,
    /// 429 Too Many Requests, 500 Internal Server Error).
    case httpError(statusCode: Int)
    /// The HTTP response body could not be decoded as the expected releases array.
    ///
    /// ❌ DO NOT revert the associated value type from `any Error & Sendable`
    /// back to bare `Error`. See the `networkError` case doc comment above for
    /// the full rationale — the same reasoning applies here.
    case decodingError(underlying: any Error & Sendable)
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
    ///
    /// Note: `message:` is used here instead of `renamed:` because `fetchFailed`
    /// requires an associated `ReleaseFetchError` value — Xcode's Fix-It cannot
    /// supply it automatically, so `renamed:` would generate a Fix-It that
    /// produces a compile error on apply.
    @available(*, deprecated, message: "Use fetchFailed(_:) and branch on ReleaseFetchError sub-cases. See UpdateCheckError docs.")
    case noReleasesFound
}
