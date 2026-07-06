// GitHubReleaseProvider.swift
// AppUpdater

// MARK: - GitHubReleaseProvider

/// The production `ReleaseProvider` — fetches releases from the GitHub
/// Releases API by delegating to `UpdateChecker.fetchLatestAvailableRelease`.
///
/// Zero stored state; conforms to `Sendable` automatically as a value type
/// with no mutable stored properties (Pillar 6).
///
/// This type is the default injected into `AppUpdater.init` — existing call
/// sites require no changes.
public struct GitHubReleaseProvider: ReleaseProvider {
    /// Creates a new `GitHubReleaseProvider`.
    public init() {}

    /// Fetches the latest release for `repo` by delegating to
    /// `UpdateChecker.fetchLatestAvailableRelease`.
    ///
    /// Returns `nil` on any failure (network error, non-200 response, decode
    /// failure, empty list, no channel match). All failure modes are
    /// best-effort and must never surface error UI.
    ///
    /// ## ❌ DO NOT replace the fetchLatestAvailableRelease call with checkForUpdate
    ///
    /// It looks tempting to call `UpdateChecker.checkForUpdate` here with a
    /// sentinel `currentVersion` (e.g. `"v0.0.0"`) and extract the release
    /// from the `.updateAvailable` case. This is a trap:
    ///
    /// - `checkForUpdate` performs a version comparison. `fetchLatestAvailableRelease`
    ///   does not. This provider's job is to return the latest eligible release
    ///   unconditionally — the version comparison is `AppUpdater`'s responsibility.
    /// - Any sentinel value that is a valid tag (e.g. `v0.0.0`) will cause
    ///   `isNewer` to return `false` for a repo whose latest release is tagged
    ///   exactly that value, silently returning `nil` instead of the release.
    /// - This has already been attempted and reverted — see PR #20 and issue #13.
    ///
    /// The apparent duplication between `fetchLatestAvailableRelease` and
    /// `checkForUpdate` (both call `fetchAndDecodeReleases` + `latestMatchingRelease`)
    /// is load-bearing. The two methods have different contracts and different
    /// nil semantics. Leave them separate.
    public func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> AvailableRelease? {
        await UpdateChecker.fetchLatestAvailableRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
    }
}
