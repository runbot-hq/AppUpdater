// AppUpdater+UpdateFlow.swift
// AppUpdater
import Foundation

// MARK: - Update flow entry points

/// Update-flow entry points: check and handle available releases.
extension AppUpdater {

    // MARK: - Public entry points

    /// Runs a full update check and handles the result.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    /// `.upToDate` is a no-op here — the background scheduler owns the
    /// stale-row-clearing policy.
    /// `.failed` logs a granular message per `ReleaseFetchError` sub-case so
    /// triage does not require a proxy or network capture to distinguish
    /// offline failures from API rejections.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
        case .failed(let error):
            switch error as? UpdateCheckError {
            case .fetchFailed(let reason):
                switch reason {
                case .networkError(let underlying):
                    appUpdaterLogger.debug("update check failed: network error — \(underlying.localizedDescription, privacy: .public) (beta=\(beta, privacy: .public))")
                case .httpError(let statusCode):
                    appUpdaterLogger.debug("update check failed: HTTP \(statusCode, privacy: .public) from GitHub API (beta=\(beta, privacy: .public))")
                case .decodingError(let underlying):
                    appUpdaterLogger.debug("update check failed: response decode error — \(underlying.localizedDescription, privacy: .public) (beta=\(beta, privacy: .public))")
                }
            case .missingVersionKey:
                appUpdaterLogger.debug("update check failed: currentVersion is empty — check AppUpdater init configuration (beta=\(beta, privacy: .public))")
            case .noReleasesFound:
                // ❌ Dead guard — do NOT remove: .noReleasesFound is a real deprecated enum
                // case; Swift's exhaustiveness checker requires it to be covered.
                appUpdaterLogger.debug("update check failed: deprecated .noReleasesFound — migrate callers to .fetchFailed (beta=\(beta, privacy: .public))")
            case nil:
                appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
            }
        }
    }

    /// Runs a channel-aware update check via the injected `ReleaseProvider`.
    ///
    /// Intentionally `internal` — `checkAndHandle` is the designed public entry point.
    func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        let fetchResult = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        return UpdateChecker.evaluate(fetchResult: fetchResult, currentVersion: currentVersion, betaChannel: betaChannel)
    }

    // MARK: - Handle

    /// Responds to a newly discovered available release.
    ///
    /// 1. If a zip already exists at the fixed zip URL, delegates to `handleCachedZip`
    ///    which applies `.ready` or `.idle` (zip-deletion race guard, issue #58).
    /// 2. If the release has no matching asset or no signature sidecar URL,
    ///    logs a warning and returns — no phase change.
    /// 3. Otherwise advances to `.available` and starts a background download.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {
        withZipURL { zipURL in
            if FileManager.default.fileExists(atPath: zipURL.path(percentEncoded: false)) {
                handleCachedZip(release: release, state: state)
                return
            }

            // ── Asset or signature sidecar absent? ─────────────────────────────────────────────────────
            let wantedAsset = assetName(release.tagName)
            guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
                appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no asset named \(wantedAsset, privacy: .public) — skipping download")
                return
            }
            guard let signatureURL = release.signatureURL else {
                appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no signature sidecar — skipping download")
                return
            }

            // ── Advance to .available and start download ─────────────────────────────────────────────────
            state.apply(.available(version: release.tagName))
            let downloadURL = asset.browserDownloadURL
            let tagName = release.tagName
            // ✅ REVIEWED: fire-and-forget Task is correct here. Do NOT add an
            // isDownloading guard, a stored Task handle, or a cancellation path.
            // See issue #1859 for the full rationale.
            // Task(name:) is standard Swift 6.2 (SE-0469).
            Task(name: "AppUpdater.download") {
                await self.downloadUpdate(
                    from: downloadURL,
                    signatureURL: signatureURL,
                    version: tagName,
                    destination: zipURL,
                    state: state
                )
            }
        }
    }

    // MARK: - Cached zip

    /// Handles the case where a zip already exists on disk when `handle` is called.
    ///
    /// Applies `.ready` unless the cached release matches the currently running version,
    /// in which case the zip is a post-relaunch leftover and `.idle` is applied instead.
    ///
    /// ## Zip-deletion race guard (issue #58)
    /// After `installAndRelaunch`, the zip is deleted synchronously after swap
    /// verification but before relaunch (Step 4 in `replaceAndRelaunch`). The new
    /// process can still reach this point before deletion returns and find a zip on
    /// disk for the version it is already running. Applying `.ready` here would show
    /// the Install button spuriously on an already-updated binary.
    ///
    /// `currentVersion` is baked into `AppUpdater` at `init()` from `Bundle.main` of
    /// the running process — it is always authoritative regardless of what is on disk.
    /// The comparison is race-free.
    ///
    /// The leading `"v"` is stripped from `release.tagName` to match the
    /// `CFBundleShortVersionString` format used by `currentVersion`
    /// (e.g. tagName `"v0.7.7"` → `"0.7.7"` == `currentVersion` `"0.7.7"`).
    ///
    /// ## Self-healing edge cases
    /// STALE ZIP, YANKED RELEASE, and PARTIAL WRITE scenarios all self-heal without
    /// a version sidecar or version-in-filename. See the inline comments in `handle`
    /// (prior to this extraction) and PRINCIPLES.md for the full rationale.
    /// Do NOT add a version sidecar or encode the version into the zip filename.
    private func handleCachedZip(release: AvailableRelease, state: any UpdateStateProviding) {
        let tagVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        if tagVersion == currentVersion {
            appUpdaterLogger.debug("post-relaunch zip leftover detected: \(release.tagName, privacy: .public) matches running version — applying .idle (issue #58)")
            state.apply(.idle)
            return
        }
        state.apply(.ready(version: release.tagName))
    }
}
