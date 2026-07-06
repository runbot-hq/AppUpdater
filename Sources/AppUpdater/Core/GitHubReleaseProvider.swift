// GitHubReleaseProvider.swift
// AppUpdater

// MARK: - GitHubReleaseProvider

/// The production `ReleaseProvider` — fetches the latest eligible release
/// from the GitHub Releases API by calling `UpdateChecker.checkForUpdate`
/// and extracting the release from an `.updateAvailable` result.
///
/// Zero stored state; conforms to `Sendable` automatically as a value type
/// with no mutable stored properties.
///
/// This type is the default injected into `AppUpdater.init` — existing call
/// sites require no changes.
public struct GitHubReleaseProvider: ReleaseProvider {
    /// Creates a new `GitHubReleaseProvider`.
    public init() {}

    /// Fetches the latest release for `repo` by calling
    /// `UpdateChecker.checkForUpdate` and extracting the release.
    ///
    /// Returns `nil` when there is no update available, the fetch failed,
    /// or no release matched the channel. All failure modes are best-effort
    /// and must never surface error UI.
    ///
    /// ## Why call checkForUpdate instead of a raw fetch primitive?
    ///
    /// `checkForUpdate` is the single authoritative fetch+filter+compare path
    /// (see issue #13). A dedicated `fetchLatestAvailableRelease` primitive
    /// was removed because it duplicated the same three steps
    /// (fetchAndDecodeReleases, latestMatchingRelease, checksum assembly)
    /// via a slightly different nil-handling path. Two paths that can drift
    /// are worse than one path that is slightly over-qualified for this call
    /// site. The version comparison step (`isNewer`) is cheap and correct
    /// to run here — it produces `.upToDate` rather than `.updateAvailable`
    /// when there is nothing new, which maps cleanly to `nil`.
    public func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> AvailableRelease? {
        // Pass an empty currentVersion so isNewer always returns true —
        // this provider's job is to return the latest eligible release
        // regardless of what the running version is. The version comparison
        // is the caller's (AppUpdater.checkForUpdate) responsibility.
        //
        // isNewer("", than: "") => false via the ParsedVersion(0.0.0) path,
        // so we use a sentinel that is guaranteed to be older than any real
        // release tag: "v0.0.0". Any published release is newer than v0.0.0.
        let result = await UpdateChecker.checkForUpdate(
            repo: repo,
            currentVersion: "v0.0.0",
            betaChannel: betaChannel,
            assetName: assetName
        )
        guard case .updateAvailable(let release) = result else { return nil }
        return release
    }
}
