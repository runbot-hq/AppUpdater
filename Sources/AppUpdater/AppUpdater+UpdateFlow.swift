// AppUpdater+UpdateFlow.swift
// AppUpdater
import Foundation

// MARK: - Update flow entry points

/// Update-flow entry points: check and handle available releases.
extension AppUpdater {

    // MARK: - Public entry points

    /// Runs a full update check and handles the result.
    ///
    /// This is the single gate for `automaticUpdatesEnabled`: returns immediately
    /// when the flag is `false`, covering every entry point — launch-time check,
    /// Settings-entry check, and the background scheduler callback (which calls
    /// this method directly). The scheduler lifecycle is not affected.
    ///
    /// On `.updateAvailable` the release is downloaded/cached via `handle`.
    ///
    /// `.upToDate` clears a stuck `.failed` phase and is otherwise a no-op.
    /// The narrow `case .failed` guard is deliberate — do NOT widen it to an
    /// unconditional `state.apply(.idle)`:
    ///
    /// - `.ready` must survive. A cached, verified, installable zip is not
    ///   invalidated by a later check that finds nothing newer.
    /// - `.available` / `.downloading` must survive. This method is re-entrant
    ///   (launch check, Settings check, the README's Retry button) and a
    ///   concurrent call must not wipe an in-flight download's phase.
    ///
    /// Only `.failed` is cleared, because only `.failed` is stuck: nothing else
    /// in the flow ever leaves it, so a user who hits a transient network error
    /// and then retries successfully would otherwise keep seeing the failure
    /// affordance forever with no way to learn the app is up to date. The
    /// background scheduler already clears state on `.upToDate`; this makes the
    /// foreground path agree with it. See issue #69 (A2).
    ///
    /// `.failed` logs a granular message per `ReleaseFetchError` sub-case so
    /// triage does not require a proxy or network capture to distinguish
    /// offline failures from API rejections.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        guard automaticUpdatesEnabled else { return }
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
            // Clear a stuck .failed only — see the doc comment above for why
            // this guard must stay narrow.
            if case .failed = state.currentPhase {
                appUpdaterLogger.debug("clearing stale .failed phase after a successful up-to-date check")
                state.apply(.idle)
            }
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
    /// 1. If a zip already exists at the fixed zip URL, delegates to `handleCachedZip`,
    ///    which either consumes it (`.ready` / `.idle`) or discards it as
    ///    unattributable and returns `false` so the normal download runs.
    /// 2. If the release has no matching asset or no signature sidecar URL,
    ///    logs a warning and returns — no phase change.
    /// 3. Otherwise advances to `.available` and starts a background download.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {
        withZipURL { zipURL in
            if FileManager.default.fileExists(atPath: zipURL.path(percentEncoded: false)) {
                // false means the zip could not be attributed to this release and
                // has been deleted — fall through and download it properly.
                if handleCachedZip(release: release, state: state, zipURL: zipURL) {
                    return
                }
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
            // See runbot-hq/run-bot#1859 for the full rationale.
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

    /// Decides what to do with a zip that already exists on disk when `handle`
    /// is called.
    ///
    /// - Returns: `true` if the zip was consumed (a phase was applied and the
    ///   caller should stop), `false` if it could not be attributed to `release`
    ///   and was deleted (the caller should download).
    ///
    /// ## The bytes on disk are not self-describing
    ///
    /// The cache path is fixed — `update.zip`, no version in the filename, no
    /// sidecar — so nothing on disk says which release a cached zip belongs to.
    /// The only trustworthy attribution is the in-memory phase: `AppUpdater`
    /// applies `.ready(version:)` exactly once, immediately after verifying and
    /// moving that specific download into place. So a zip is attributable to
    /// `release` if and only if the host is currently in `.ready` for this exact
    /// tag; anything else is a leftover and is discarded.
    ///
    /// This closes issue #69 (A1). Previously `.ready(release.tagName)` was
    /// applied for whatever bytes happened to be present, so a zip downloaded
    /// for an earlier release — a user who skipped an update, or who toggled the
    /// beta channel off — was announced as the newer release and then installed
    /// over the running app before anything checked it.
    ///
    /// ## ❌ This is still not a version sidecar
    ///
    /// The existing directive stands: do NOT add a version sidecar and do NOT
    /// encode the version into the zip filename. This fix deliberately adds no
    /// new state at all — it reads `UpdatePhase`, which already carries the
    /// version, so Principles 1 and 7 are untouched.
    ///
    /// The cost is one extra download when the host restarts while a zip is
    /// cached but uninstalled: the phase is `.idle` on a cold start, so the
    /// leftover is unattributable by construction and is re-fetched. That is the
    /// intended trade — a redundant download is cheap, a mis-install is not.
    ///
    /// ## Zip-deletion race guard (issue #58) — checked first
    /// After `installAndRelaunch`, the zip is deleted synchronously after swap
    /// verification but before relaunch (Step 4 in `replaceAndRelaunch`). The new
    /// process can still reach this point before deletion returns and find a zip on
    /// disk for the version it is already running. Applying `.ready` here would show
    /// the Install button spuriously on an already-updated binary.
    ///
    /// `currentVersion` is baked into `AppUpdater` at `init()` from `Bundle.main` of
    /// the running process — it is always authoritative regardless of what is on disk.
    /// The comparison is race-free. This guard runs before the attribution check
    /// because it must win: the zip is spent either way, and `.idle` is the
    /// correct phase, not a re-download.
    private func handleCachedZip(
        release: AvailableRelease,
        state: any UpdateStateProviding,
        zipURL: URL
    ) -> Bool {
        let tagVersion = UpdateChecker.bundleVersion(forTag: release.tagName)
        if tagVersion == currentVersion {
            appUpdaterLogger.debug("post-relaunch zip leftover detected: \(release.tagName, privacy: .public) matches running version — applying .idle (issue #58)")
            state.apply(.idle)
            return true
        }

        guard case .ready(let cachedVersion) = state.currentPhase,
              cachedVersion == release.tagName else {
            appUpdaterLogger.debug("""
                cached zip is not attributable to \(release.tagName, privacy: .public) \
                (phase is \(String(describing: state.currentPhase), privacy: .public)) \
                — discarding and re-downloading (issue #69 A1)
                """)
            do {
                try FileManager.default.removeItem(at: zipURL)
            } catch {
                let nsErr = error as NSError
                if !(nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError) {
                    // Not fatal: downloadUpdate removes the destination again
                    // before moving the verified zip into place.
                    appUpdaterLogger.error("""
                        could not delete unattributable zip, download will overwrite it: \
                        \(String(describing: error), privacy: .public)
                        """)
                }
            }
            return false
        }

        state.apply(.ready(version: release.tagName))
        return true
    }
}
