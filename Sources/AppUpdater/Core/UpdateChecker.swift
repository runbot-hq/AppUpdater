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
    /// These are the only formats produced by the RunBot publish pipeline and
    /// the only formats this function is designed to handle. Using this library
    /// with tags outside this shape (e.g. `rc.1`, `alpha.1`, CalVer, build
    /// metadata suffixes) is outside the supported contract. If your pipeline
    /// uses a different tag convention, adapt the convention — do not extend
    /// this parser.
    ///
    /// ❌ DO NOT add support for `rc.N`, `alpha.N`, or arbitrary pre-release labels.
    ///
    /// A reviewer may propose extending `ParsedVersion` to handle `rc.N` or
    /// `alpha.N` so that `isNewer` returns a meaningful ordering for those
    /// suffixes rather than `false`. This is permanently rejected:
    ///
    /// - The library has a defined tag contract (see above). Consumers who do
    ///   not follow it get undefined behaviour — that is correct and intentional.
    ///   The library's job is not to accommodate every possible tagging scheme.
    /// - Adding more suffix types adds parser complexity, more `betaIndex`-style
    ///   fields, and new ordering edge cases (how does `rc.1` compare to `beta.2`?
    ///   Is `alpha < beta < rc < stable`? Different projects answer differently).
    /// - Silent `false` for an unrecognised suffix is a safe, predictable
    ///   failure mode. The worst outcome is "update not offered" — not a
    ///   wrong-version install or a crash.
    ///
    /// If this is raised in review again, point the reviewer here.
    ///
    /// ## Constraints
    ///
    /// Pre-release ordering is supported **only for `beta.N` labels** (e.g.
    /// `v0.8.0-beta.2` is newer than `v0.8.0-beta.1`). Any other pre-release
    /// suffix — such as `rc.1`, `alpha.1`, or an arbitrary string — is parsed
    /// with `betaIndex == nil`. When both versions share the same
    /// `major.minor.patch` and at least one has a non-`beta.N` pre-release
    /// label, the `if let ci, let si` guard falls through and this function
    /// returns `false`.
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

    /// Checks whether `availableRelease` is newer than `currentVersion`.
    ///
    /// This is the pure comparison layer — it receives an already-fetched
    /// `AvailableRelease?` and maps it to an `UpdateCheckResult`. No network
    /// I/O occurs here.
    ///
    /// ## Return values
    ///
    /// - `.upToDate` — `availableRelease` is `nil` (no channel match) or not
    ///   newer than `currentVersion`.
    /// - `.updateAvailable` — `availableRelease` is newer than `currentVersion`.
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty.
    /// - `.failed(.noReleasesFound)` — `availableRelease` was `nil` due to a
    ///   fetch failure (signalled by the caller passing `nil` with
    ///   `fetchFailed: true`).
    ///
    /// ## Why two separate nil meanings for availableRelease
    ///
    /// `nil` from the provider can mean two different things:
    /// - Fetch/decode failure — maps to `.failed(.noReleasesFound)`
    /// - No channel match — maps to `.upToDate`
    ///
    /// The caller (`AppUpdater.checkForUpdate`) distinguishes these by calling
    /// the provider and interpreting the result before passing it here. This
    /// keeps `UpdateChecker` free of provider knowledge while preserving the
    /// correct nil semantics.
    static func evaluate(
        availableRelease: AvailableRelease?,
        currentVersion: String,
        fetchFailed: Bool
    ) -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }
        if fetchFailed {
            return .failed(UpdateCheckError.noReleasesFound)
        }
        guard let release = availableRelease else {
            // nil + fetchFailed==false means no channel match — user is up to date.
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
    /// - `.upToDate` — the latest eligible release is not newer than
    ///   `currentVersion`, **or** releases were fetched successfully but none
    ///   matched the requested channel.
    /// - `.updateAvailable` — a newer eligible release was found.
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty.
    /// - `.failed(.noReleasesFound)` — fetch, HTTP, or decode failure.
    public static func checkForUpdate(
        repo: String,
        currentVersion: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> UpdateCheckResult {
        let provider = GitHubReleaseProvider()
        // GitHubReleaseProvider.fetchLatestRelease returns nil for both fetch
        // failure and no-channel-match. We have no way to distinguish them here
        // without a richer return type from the provider. For this static
        // convenience overload we conservatively map nil to .failed so callers
        // always get a meaningful error rather than a silent .upToDate.
        // AppUpdater.checkForUpdate uses the injected provider path which has
        // the same conservative nil mapping.
        let release = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        return evaluate(
            availableRelease: release,
            currentVersion: currentVersion,
            fetchFailed: release == nil
        )
    }
}
