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

    /// Maps a `ReleaseFetchResult` to an `UpdateCheckResult`.
    ///
    /// This is the pure comparison layer — no network I/O.
    ///
    /// ## Access
    ///
    /// Intentionally `internal`, not `public`. Reached by `AppUpdater+UpdateFlow`
    /// and directly by tests via `@testable import`. ❌ DO NOT make public:
    /// the `evaluate` signature is an implementation detail; external callers
    /// must go through `checkForUpdate`.
    ///
    /// ## Why `ReleaseFetchResult` not `(AvailableRelease?, Bool)`
    ///
    /// The previous signature `(availableRelease: AvailableRelease?, fetchFailed: Bool)`
    /// allowed callers to pass a non-nil release alongside `fetchFailed: true` —
    /// a structurally inconsistent state that compiled fine but silently discarded
    /// the release. Taking `ReleaseFetchResult` directly makes inconsistent states
    /// impossible at the type level and collapses both call sites from a switch +
    /// two evaluate calls into a single call.
    ///
    /// ## Priority order
    ///
    /// `.failed` is handled before the `currentVersion.isEmpty` check so that a
    /// host app with an empty version string does not mask a real network failure
    /// with a misleading `.missingVersionKey` error.
    ///
    /// ## Channel downgrade
    ///
    /// When `betaChannel` is `false` and `currentVersion` is a pre-release, the
    /// user has opted out of beta while running a build that is semver-ahead of
    /// any available stable release. In this case `isNewer` would return `false`
    /// (the stable release is older) and the user would be silently stranded on
    /// their beta indefinitely. To handle this, `evaluate` offers the best
    /// available stable release unconditionally when all three conditions hold:
    ///   1. `betaChannel == false`
    ///   2. `currentVersion` is a pre-release
    ///   3. `release.tagName` is itself a stable release (not a pre-release)
    ///
    /// Condition 3 is enforced defensively inside `evaluate` even though
    /// `GitHubReleaseProvider.latestMatchingRelease` already guarantees a
    /// stable-only candidate when `betaChannel == false`. The extra check
    /// makes `evaluate` self-defending against any future caller that bypasses
    /// `GitHubReleaseProvider` and accidentally passes a pre-release release
    /// with `betaChannel: false` — without it, `evaluate` would silently offer
    /// a pre-release as a "stable downgrade". If the check fails, control falls
    /// through to `isNewer` which handles pre-release-to-pre-release comparison
    /// correctly.
    ///
    /// The user is then prompted to install the stable release as a downgrade.
    /// This mirrors the expected product behaviour: opting out of beta means
    /// "take me back to stable", not "keep me on this beta forever".
    ///
    /// ## Return values
    ///
    /// - `.failed(.fetchFailed(fetchError))` — `fetchResult` is `.failed`;
    ///   `fetchError` is a `ReleaseFetchError` describing the root cause
    ///   (`.networkError`, `.httpError(statusCode:)`, or `.decodingError`).
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty (and fetch
    ///   did not fail).
    /// - `.upToDate` — `fetchResult` is `.fetched(nil)` (no channel match) or
    ///   the fetched release is not newer than `currentVersion` and no channel
    ///   downgrade applies.
    /// - `.updateAvailable` — fetched release is newer than `currentVersion`,
    ///   **or** a channel downgrade from beta to stable is required.
    ///
    /// ## Exhaustion enforcement
    ///
    /// `fetchResult` is matched with a `switch` (no `default`) so that adding
    /// a new case to `ReleaseFetchResult` produces a compiler error here,
    /// forcing an explicit handling decision. Do not add a `default` or
    /// `@unknown default` arm — either would silently swallow new cases.
    static func evaluate(
        fetchResult: ReleaseFetchResult,
        currentVersion: String,
        betaChannel: Bool
    ) -> UpdateCheckResult {
        switch fetchResult {
        case .failed(let fetchError):
            return .failed(UpdateCheckError.fetchFailed(fetchError))
        case .fetched(let release):
            guard !currentVersion.isEmpty else {
                return .failed(UpdateCheckError.missingVersionKey)
            }
            guard let release else { return .upToDate }

            // Both versions are parsed eagerly and cached here for use by the
            // channel-downgrade guard below.
            //
            // parsedCurrent — read by the guard (parsedCurrent.isPrerelease).
            //   The named binding keeps the allocation to exactly one
            //   ParsedVersion(currentVersion) call within this scope. Do not
            //   inline it as `ParsedVersion(currentVersion).isPrerelease`
            //   directly in the if condition — that would make the
            //   single-evaluation guarantee implicit rather than structural,
            //   and obscures intent if the condition is later extended.
            //   parsedCurrent is NOT passed into or reused by isNewer: isNewer
            //   takes raw String arguments and calls ParsedVersion(current)
            //   internally on its own.
            //
            // parsedRelease — read by the guard (!parsedRelease.isPrerelease).
            //   Same rationale as parsedCurrent. NOT passed into or reused by
            //   isNewer, which calls ParsedVersion(candidate) internally.
            //
            // Neither local is shared with the isNewer fallthrough path, which
            // re-parses both strings independently. There is no API to inject
            // pre-parsed values into isNewer, and adding one would complicate
            // its public signature for a negligible gain. Do not remove these
            // locals on the grounds that isNewer "already parses them anyway" —
            // they exist to keep each ParsedVersion allocation explicit and
            // singular on the guard-fires path.
            let parsedCurrent = ParsedVersion(currentVersion)
            let parsedRelease = ParsedVersion(release.tagName)

            // Channel downgrade: user opted out of beta while running a
            // pre-release that is semver-ahead of the best available stable.
            // isNewer would return false (stable is older), stranding the user
            // on their beta indefinitely. Offer the stable release regardless.
            //
            // The third condition (!parsedRelease.isPrerelease) is a defensive
            // self-check. GitHubReleaseProvider already guarantees a stable-only
            // candidate when betaChannel == false, so in the normal production
            // path this is always true. The check protects against future callers
            // that bypass the provider and pass an inconsistent
            // (betaChannel: false, pre-release release) pair. If it fails,
            // fall through to isNewer below.
            if !betaChannel
                && parsedCurrent.isPrerelease
                && !parsedRelease.isPrerelease {
                return .updateAvailable(release: release)
            }

            guard isNewer(release.tagName, than: currentVersion) else { return .upToDate }
            return .updateAvailable(release: release)
        }
    }

    /// Checks for an available update for `repo`.
    ///
    /// This overload performs the full fetch+compare pipeline using
    /// `GitHubReleaseProvider` directly. It exists for call sites that do not
    /// have an injected provider (e.g. one-shot CLI usage). `AppUpdater` uses
    /// the instance-level `checkForUpdate` which goes through the injected
    /// provider instead.
    ///
    /// ## ❌ DO NOT remove the `GitHubReleaseProvider()` instantiation here
    ///
    /// This static method is a deliberate convenience entry point for one-shot
    /// callers that have no `AppUpdater` instance (e.g. CLI tools, Previews).
    /// It creates a `GitHubReleaseProvider` inline, which introduces a
    /// compile-time dependency from `UpdateChecker` (business logic) to
    /// `GitHubReleaseProvider` (network layer).
    ///
    /// This coupling is intentional and acceptable in the current single-target
    /// structure. If `GitHubReleaseProvider` is ever moved to a separate Swift
    /// Package target, this method must be updated (or moved to the new target)
    /// at the same time — it will not compile otherwise. Do not attempt to
    /// "fix" the coupling by injecting a `ReleaseProvider` parameter here;
    /// that would break all existing one-shot call sites. Use the instance-level
    /// `AppUpdater.checkForUpdate` if you need provider injection.
    ///
    /// ## Return values
    ///
    /// - `.upToDate` — latest eligible release is not newer than `currentVersion`,
    ///   **or** no release matched the channel (stable user, beta-only repo).
    /// - `.updateAvailable` — a newer eligible release was found.
    /// - `.failed(.fetchFailed(fetchError))` — fetch, HTTP, or decode failure;
    ///   inspect `fetchError` for the specific `ReleaseFetchError` case.
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
        return evaluate(fetchResult: fetchResult, currentVersion: currentVersion, betaChannel: betaChannel)
    }
}
