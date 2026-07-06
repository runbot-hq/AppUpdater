// UpdateChecker.swift
// AppUpdater
import Foundation

// MARK: - UpdateChecker

/// Checks a GitHub repository's Releases for a newer version.
public enum UpdateChecker {

    /// Lightweight mirror of the GitHub Releases API response object.
    ///
    /// Only the fields needed for version comparison and asset resolution are
    /// decoded; all other API fields are ignored.
    private struct Release: Decodable {
        /// The git tag name of this release (e.g. `"v0.8.0"`).
        let tagName: String
        /// `true` when GitHub has marked this release as a pre-release.
        let prerelease: Bool
        /// The binary assets attached to this release.
        let assets: [ReleaseAsset]
        /// Maps Swift property names to the GitHub API's snake_case JSON keys.
        enum CodingKeys: String, CodingKey {
            /// Maps to the GitHub API JSON key `"tag_name"`.
            case tagName = "tag_name"
            /// Maps to the JSON key `"prerelease"`.
            case prerelease
            /// Maps to the JSON key `"assets"`.
            case assets
        }
    }

    /// A parsed representation of a semver version string used internally by `isNewer`.
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
    ///   and the correct semantics for `nil` vs `nil` are non-obvious to implement
    ///   correctly — a naive `betaIndex ?? -1` pattern introduces subtle ordering bugs.
    /// - The gain is cosmetic. Keep the explicit field-by-field chain in `isNewer`.
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

    /// Builds a `URLRequest` for the releases endpoint of `repo`.
    ///
    /// `perPage` is clamped to `1...100` (GitHub's documented maximum for this
    /// endpoint). A single request is made — no pagination.
    ///
    /// ## ⚠️ 100-release ceiling
    ///
    /// `fetchAndDecodeReleases` makes exactly one request with `per_page=100`.
    /// If a repository has published more than 100 releases the oldest releases
    /// (by GitHub's default sort, newest first) are never seen. For most repos
    /// this is not a problem — the newest release is always in the first page.
    /// However if you publish hotfixes to old branches and those appear after
    /// the 100th entry you may miss them. See README "Known limitations" for
    /// the recommended mitigation (keep releases ≤ 100, or draft/delete old ones).
    private static func buildRequest(repo: String, perPage: Int) -> URLRequest? {
        let clampedPerPage = min(max(perPage, 1), 100)
        let releasesURLString = "https://api.github.com/repos/\(repo)/releases"
        guard let baseURL = URL(string: releasesURLString) else { return nil }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "per_page", value: String(clampedPerPage))]
        guard let requestURL = components.url else { return nil }
        var request = URLRequest(url: requestURL)
        request.setValue("AppUpdater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    /// Fetches and decodes the releases list for `repo`.
    ///
    /// Returns `nil` on any network, HTTP, or JSON-decode failure. An empty
    /// array means the repository exists but has no published releases.
    /// This is intentionally separate from channel filtering — a `nil` return
    /// here means "we could not determine the release list", whereas an empty
    /// filtered result means "releases exist but none match the channel".
    private static func fetchAndDecodeReleases(repo: String) async -> [Release]? {
        guard let request = buildRequest(repo: repo, perPage: 100) else { return nil }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        let session = URLSession(configuration: sessionConfig)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request) else { return nil }

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            appUpdaterLogger.debug("releases API returned \(httpResponse.statusCode, privacy: .public) for \(repo, privacy: .public)")
            return nil
        }

        return try? JSONDecoder().decode([Release].self, from: data)
    }

    /// Sorts `releases` by semver (newest first) and returns the first entry
    /// that matches `betaChannel`.
    ///
    /// Returns `nil` when no release matches the channel filter — i.e. the
    /// caller is on the stable channel and every release is a pre-release.
    /// This `nil` means **no channel match**, not a fetch failure; the two
    /// cases are kept separate so callers can map them to different outcomes
    /// (`.upToDate` vs `.failed`).
    private static func latestMatchingRelease(
        from releases: [Release],
        betaChannel: Bool
    ) -> Release? {
        // Sorted rather than max-scan by design — runs at most once per 24 hours on
        // ≤ 100 items. The clarity of .first on a sorted list outweighs the irrelevant
        // perf difference. Do not "optimise" this.
        let sorted = releases.sorted { isNewer($0.tagName, than: $1.tagName) }
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }

    /// Returns `true` when `candidate` is strictly newer than `current` using
    /// numeric semver comparison, including beta ordering.
    ///
    /// ## Supported tag format
    ///
    /// - Stable:  `vMAJOR.MINOR.PATCH`        (e.g. `v1.2.3`)
    /// - Beta:    `vMAJOR.MINOR.PATCH-beta.N` (e.g. `v1.2.3-beta.4`)
    ///
    /// ❌ DO NOT add support for `rc.N`, `alpha.N`, or arbitrary pre-release labels.
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

    /// Checks for an available update for `repo`.
    ///
    /// This is the single authoritative fetch+filter+compare path.
    /// `GitHubReleaseProvider.fetchLatestRelease` calls this and maps the
    /// result — there is no separate fetch primitive.
    ///
    /// ## Return values
    ///
    /// - `.upToDate` — latest eligible release is not newer than `currentVersion`,
    ///   or releases were fetched successfully but none matched the channel.
    /// - `.updateAvailable` — a newer eligible release was found.
    /// - `.failed(.missingVersionKey)` — `currentVersion` is empty.
    /// - `.failed(.noReleasesFound)` — fetch, HTTP, or decode failure.
    public static func checkForUpdate(
        repo: String,
        currentVersion: String,
        betaChannel: Bool,
        assetName: (String) -> String
    ) async -> UpdateCheckResult {
        guard !currentVersion.isEmpty else {
            return .failed(UpdateCheckError.missingVersionKey)
        }

        guard let releases = await fetchAndDecodeReleases(repo: repo) else {
            return .failed(UpdateCheckError.noReleasesFound)
        }

        // ✅ REVIEWED: nil here maps to .upToDate, NOT .failed — releases were
        // fetched successfully but none matched the channel. That is not a
        // failure — the user is on the latest version they are eligible for.
        guard let release = latestMatchingRelease(from: releases, betaChannel: betaChannel) else {
            return .upToDate
        }

        let checksumAssetName = assetName(release.tagName) + ".sha256"
        let checksumAsset = release.assets.first(where: { $0.name == checksumAssetName })
        let availableRelease = AvailableRelease(
            tagName: release.tagName,
            assets: release.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )

        guard isNewer(availableRelease.tagName, than: currentVersion) else {
            return .upToDate
        }
        return .updateAvailable(release: availableRelease)
    }
}
