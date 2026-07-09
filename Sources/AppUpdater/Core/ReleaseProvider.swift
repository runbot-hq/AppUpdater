// ReleaseProvider.swift
// AppUpdater

// MARK: - ReleaseFetchResult

/// The result of a release fetch from a `ReleaseProvider`.
///
/// Distinguishes two structurally different nil cases that `AvailableRelease?`
/// alone cannot represent:
///
/// - `.fetched(nil)` — fetch and decode succeeded, but no release matched
///   the requested channel (e.g. stable user on a beta-only repo). Maps to
///   `.upToDate`.
/// - `.fetched(release)` — a matching release was found. Caller performs
///   version comparison.
/// - `.failed(ReleaseFetchError)` — network error, non-200 HTTP response,
///   or JSON decode failure. The associated `ReleaseFetchError` identifies
///   the specific failure mode so callers can present actionable messages.
///   Maps to `.failed(.fetchFailed(error))`.
public enum ReleaseFetchResult: Sendable {
    /// Fetch and decode succeeded. `release` is `nil` when no release matched
    /// the channel filter.
    case fetched(AvailableRelease?)
    /// Fetch, HTTP, or decode failure. The associated value identifies the
    /// specific failure mode — see `ReleaseFetchError` for the full case list.
    case failed(ReleaseFetchError)
}

// MARK: - ReleaseProvider

/// Abstracts the release-fetch layer so `AppUpdater` can be tested
/// without a live network. The protocol is intentionally narrow —
/// one method returning a `ReleaseFetchResult`. `AppUpdater` owns
/// the `isNewer` comparison; this type only fetches.
///
/// Conforming types must be `Sendable` (Pillar 6 — non-isolated
/// `Sendable` structs for business logic).
///
/// ## Production conformance
/// `GitHubReleaseProvider` is the default production implementation.
///
/// ## Test conformance
/// `MockReleaseProvider` (in `AppUpdaterTests`) is an `actor` that
/// captures call arguments and returns a configurable `ReleaseFetchResult`.
public protocol ReleaseProvider: Sendable {
    /// Fetches the latest release for `repo` matching the given channel.
    ///
    /// Returns `.fetched(release)` on success, `.fetched(nil)` when no
    /// release matched the channel filter, and `.failed(error)` on any
    /// network, HTTP, or decode error — where `error` is a `ReleaseFetchError`
    /// identifying the specific failure mode.
    ///
    /// Failures are best-effort and must never surface error UI directly —
    /// mapping to `UpdateCheckResult` is the caller's responsibility.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug.
    ///   - betaChannel: When `true`, pre-release builds are candidates.
    ///   - assetName: Maps a tag name to the expected zip asset filename;
    ///     used to resolve the signature sidecar URL
    ///     (`<assetName(tagName)>.sig`) from the release's asset list.
    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> ReleaseFetchResult
}
