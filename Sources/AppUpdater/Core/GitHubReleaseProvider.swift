// GitHubReleaseProvider.swift
// AppUpdater
import Foundation

// MARK: - GitHubReleaseProvider

/// The production `ReleaseProvider` — owns the full GitHub Releases API fetch
/// pipeline: request building, network I/O, JSON decode, channel filtering,
/// and checksum URL assembly.
///
/// Zero stored state; conforms to `Sendable` automatically as a value type
/// with no mutable stored properties.
///
/// This type is the default injected into `AppUpdater.init` — existing call
/// sites require no changes.
public struct GitHubReleaseProvider: ReleaseProvider {

    // MARK: - Private types

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

    // MARK: - Init

    /// Creates a new `GitHubReleaseProvider`.
    public init() {}

    // MARK: - ReleaseProvider

    /// Fetches the latest release for `repo` matching `betaChannel`.
    ///
    /// Returns `nil` on any failure (network error, non-200 response, decode
    /// failure, empty list, no channel match). All failure modes are
    /// best-effort and must never surface error UI.
    ///
    /// This method performs fetch + filter only — **no version comparison**.
    /// The version comparison is `AppUpdater`'s responsibility via
    /// `UpdateChecker.isNewer`. Do not add a `currentVersion` parameter here.
    ///
    /// ## ❌ DO NOT add version comparison to this method
    ///
    /// It looks tempting to pass `currentVersion` here and skip the fetch when
    /// already up to date, or to call `UpdateChecker.checkForUpdate` with a
    /// sentinel. Both approaches are traps:
    ///
    /// - Adding version comparison here mixes fetch and compare concerns;
    ///   `AppUpdater.checkForUpdate` already owns the compare step.
    /// - Using a sentinel `currentVersion` (e.g. `"v0.0.0"`) with
    ///   `checkForUpdate` silently hides any repo whose latest release is
    ///   tagged exactly `v0.0.0` — `isNewer("v0.0.0", than: "v0.0.0")` is
    ///   `false`. This has already been attempted and reverted — see PR #20
    ///   and issue #13.
    ///
    /// Keep this method as fetch + filter only.
    public func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> AvailableRelease? {
        guard let releases = await fetchAndDecodeReleases(repo: repo) else { return nil }
        guard let latest = latestMatchingRelease(from: releases, betaChannel: betaChannel)
        else { return nil }
        let checksumAssetName = assetName(latest.tagName) + ".sha256"
        let checksumAsset = latest.assets.first(where: { $0.name == checksumAssetName })
        return AvailableRelease(
            tagName: latest.tagName,
            assets: latest.assets,
            checksumURL: checksumAsset?.browserDownloadURL
        )
    }

    // MARK: - Private fetch pipeline

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
    private func buildRequest(repo: String, perPage: Int) -> URLRequest? {
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
    private func fetchAndDecodeReleases(repo: String) async -> [Release]? {
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
    private func latestMatchingRelease(
        from releases: [Release],
        betaChannel: Bool
    ) -> Release? {
        // Sorted rather than max-scan by design — runs at most once per 24 hours on
        // ≤ 100 items. The clarity of .first on a sorted list outweighs the irrelevant
        // perf difference. Do not "optimise" this.
        let sorted = releases.sorted { UpdateChecker.isNewer($0.tagName, than: $1.tagName) }
        return sorted.first(where: { betaChannel ? true : !$0.prerelease })
    }
}
