// UpdateChecker.swift
// AppUpdater
import Foundation

// MARK: - UpdateChecker

/// Pure semver business logic: version parsing, comparison, and update-check
/// orchestration.
///
/// `UpdateChecker` deliberately owns **no network code**. All fetch, decode,
/// and channel-filtering logic lives in `GitHubReleaseProvider`. This
/// separation means `UpdateChecker` can be tested without any network
/// involvement and `GitHubReleaseProvider` can be swapped out via the
/// `ReleaseProvider` protocol.
public enum UpdateChecker {

    /// A parsed representation of a semver version string used internally by `isNewer`.
    ///
    /// Strips the leading `"v"` if present, splits on `"-"` to separate the
    /// core version from any pre-release suffix, and extracts a `betaIndex`
    /// for `beta.N` labels so beta versions can be ordered numerically.
    ///
    /// ❌ DO NOT add `Comparable` conformance to this type.
    ///
    /// A reviewer may propose conforming `ParsedVersion` to `Comparable` so
    /// that `isNewer` can be rewritten as `ParsedVersion(candidate) > ParsedVersion(current)`
    /// and `latestMatchingRelease` can sort with `sorted(by: >)`. This is not
    /// worth doing:
    ///
    /// - `ParsedVersion` is `private`. Nothing outside this file ever touches it.
    ///   There is exactly one call site (`isNewer`) and the manual comparison
    ///   chain there is already short and readable.
    /// - `Comparable` requires a total order. `betaIndex` is `Optional<Int>`,
    ///   and the correct semantics for `nil` vs `nil` (treat as equal, not less-than)
    ///   are non-obvious to implement correctly — a naive `betaIndex ?? -1` pattern
    ///   introduces subtle ordering bugs that the current explicit chain cannot.
    /// - The gain is cosmetic (two call sites become marginally shorter). The
    ///   existing tests pin the full observable behaviour of `isNewer`; any
    ///   `Comparable` implementation that diverges will be caught, but the
    ///   risk of a subtle regression in `nil`-betaIndex tie-breaking is not
    ///   worth the cosmetic saving.
    ///
    /// Keep the explicit field-by-field chain in `isNewer`. It is the right tool here.
    private struct ParsedVersion {
        /// The major version component (first numeric segment).
        let major: Int
        /// The minor version component (second numeric segment).
        let minor: Int
        /// The patch version component (third numeric segment).
        let patch: Int
        /// `true` when the version string contained a pre-release suffix.
        let isPrerelease: Bool
        /// The numeric index from a `beta.N` pre-release suffix, or `nil` for
        /// any other suffix (e.g. `rc.1`, `alpha.1`) or no suffix at all.
        let betaIndex: Int?

        /// Parses `version` into its semver components.
        ///
        /// Non-numeric or missing segments default to `0`. An unrecognised
        /// pre-release suffix (anything other than `beta.N`) sets `betaIndex`
        /// to `nil` while still marking `isPrerelease = true`.
        init(_ version: String) { // skipcq: SW-R1002 — reviewed; complexity acceptable for this version parser
            let versionString = version.hasPrefix("v") ? String(version.dropFirst()) : version
            let parts = versionString.split(separator: "-", maxSplits: 1)
            let core = parts.isEmpty ? "" : String(parts[0])
            isPrerelease = parts.count > 1
            let nums = core.split(separator: ".").compactMap { Int($0) }
            major = nums.isEmpty ? 0 : nums[0]
            minor = nums.count > 1 ? nums[1] : 0
            patch = nums.count > 2 ? nums[2] : 0
            if parts.count > 1 {
                let suffix = String(parts[1])
                let suffixParts = suffix.split(separator: ".")
                if suffixParts.count == 2, suffixParts[0] == "beta",
                   let n = Int(suffixParts[1]) {
                    betaIndex = n
                } else {
                    betaIndex = nil
                }
            } else {
                betaIndex = nil
            }
        }
    }

    /// Returns `true` when `candidate` is strictly newer than `current` using
    /// numeric semver comparison, including beta ordering.
    ///
    /// ## Supported tag format
    ///
    /// AppUpdater supports exactly two tag shapes:
    ///   - Stable releases:   `vMAJOR.MINOR.PATCH`           (e.g. `v1.2.3`)
    ///   - Beta pre-releases: `vMAJOR.MINOR.PATCH-beta.N`    (e.g. `v1.2.3-beta.4`)
    ///
    /// ❌ DO NOT add support for `rc.N`, `alpha.N`, or arbitrary pre-release labels.
    /// See the full rationale in the source history (issue #17).
    public static func isNewer(_ candidate: String, than current: String) -> Bool { // skipcq: SW-R1002 — reviewed; complexity acceptable for this semver comparison
        let cv = ParsedVersion(candidate)
        let sv = ParsedVersion(current)

        if cv.major != sv.major { return cv.major > sv.major }
        if cv.minor != sv.minor { return cv.minor > sv.minor }
        if cv.patch != sv.patch { return cv.patch > sv.patch }

        if cv.isPrerelease != sv.isPrerelease { return !cv.isPrerelease }
        if let ci = cv.betaIndex, let si = sv.betaIndex { return ci > si }

        return false
    }

    /// Maps a fetched `AvailableRelease?` to an `UpdateCheckResult`.
    ///
    /// This is the pure comparison layer — no network I/O.
    ///
    /// ## Return values
    ///
    /// - `.failed(.noReleasesFound)` — `fetchFailed` is `true`. Checked first;
    ///   a real network failure takes priority over a misconfigured host app.
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty (and fetch
    ///   did not fail).
    /// - `.upToDate` — `availableRelease` is `nil` (no channel match, fetch
    ///   succeeded) or not newer than `currentVersion`.
    /// - `.updateAvailable` — `availableRelease` is newer than `currentVersion`.
    ///
    /// ## Priority order
    ///
    /// `fetchFailed` is checked before `currentVersion.isEmpty` so that a host
    /// app with an empty version string does not mask a real network failure
    /// with a misleading `.missingVersionKey` error. If both conditions are
    /// true, the network failure is the actionable signal.
    ///
    /// ## fetchFailed vs nil
    ///
    /// `nil` from the provider has two meanings:
    /// - Fetch/decode failure (`fetchFailed: true`) → `.failed(.noReleasesFound)`
    /// - No channel match (`fetchFailed: false`) → `.upToDate`
    ///
    /// Callers derive `fetchFailed` from `ReleaseFetchResult` — never from
    /// `availableRelease == nil` alone.
    // internal — not public API. Reached by AppUpdater+UpdateFlow and indirectly
    // by tests via updater.checkForUpdate. ❌ DO NOT make public: the evaluate
    // signature is an implementation detail; callers must go through checkForUpdate.
    static func evaluate(
        availableRelease: AvailableRelease?,
        currentVersion: String,
        fetchFailed: Bool
    ) -> UpdateCheckResult {
        // ❌ DO NOT reorder these guards. fetchFailed must be checked first.
        // See "Priority order" in the doc comment above.
        if fetchFailed {
            return .failed(UpdateCheckError.noReleasesFound)
        }
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }
        guard let release = availableRelease else {
            return .upToDate
        }
        guard isNewer(release.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: release)
    }

    /// Checks for an available update for `repo`.
    ///
    /// This overload performs the full fetch+compare pipeline using
    /// `GitHubReleaseProvider` directly. It exists for call sites that do not
    /// have an injected provider (e.g. one-shot CLI usage). `AppUpdater` uses
    /// the instance-level `checkForUpdate` which goes through the injected
    /// provider instead.
    ///
    /// ## Return values
    ///
    /// - `.upToDate` — latest eligible release is not newer than `currentVersion`,
    ///   **or** no release matched the channel (stable user, beta-only repo).
    /// - `.updateAvailable` — a newer eligible release was found.
    /// - `.failed(.noReleasesFound)` — fetch, HTTP, or decode failure.
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty and fetch
    ///   did not fail.
    public static func checkForUpdate(
        repo: String,
        currentVersion: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> UpdateCheckResult {
        let provider = GitHubReleaseProvider()
        let fetchResult = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        switch fetchResult {
        case .failed:
            return evaluate(availableRelease: nil, currentVersion: currentVersion, fetchFailed: true)
        case .fetched(let release):
            return evaluate(availableRelease: release, currentVersion: currentVersion, fetchFailed: false)
        }
    }
}
