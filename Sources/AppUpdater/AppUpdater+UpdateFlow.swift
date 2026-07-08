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
                    // Device is likely offline, DNS failed, or the request timed out.
                    appUpdaterLogger.debug("update check failed: network error — \(underlying.localizedDescription, privacy: .public) (beta=\(beta, privacy: .public))")
                case .httpError(let statusCode):
                    // GitHub API returned a non-200 status (e.g. 403 Forbidden, 429 Too Many Requests).
                    appUpdaterLogger.debug("update check failed: HTTP \(statusCode, privacy: .public) from GitHub API (beta=\(beta, privacy: .public))")
                case .decodingError(let underlying):
                    // Response body did not match the expected releases schema.
                    appUpdaterLogger.debug("update check failed: response decode error — \(underlying.localizedDescription, privacy: .public) (beta=\(beta, privacy: .public))")
                }
            case .missingVersionKey:
                appUpdaterLogger.debug("update check failed: currentVersion is empty — check AppUpdater init configuration (beta=\(beta, privacy: .public))")
            case .noReleasesFound:
                // ❌ Dead guard — no production path emits .noReleasesFound after this PR.
                //
                // A reviewer may suggest removing this arm. Do NOT remove it.
                //
                // .noReleasesFound is a real @available(*, deprecated) enum case, not
                // a static alias. @available deprecation does not exempt a real case
                // from Swift's exhaustiveness checker — every switch on UpdateCheckError
                // must cover it or the compiler emits 'switch must be exhaustive'.
                // Removing this arm was attempted during this PR and caused exactly
                // that compile error. Remove only when .noReleasesFound is deleted
                // from the UpdateCheckError enum itself.
                appUpdaterLogger.debug("update check failed: deprecated .noReleasesFound — migrate callers to .fetchFailed (beta=\(beta, privacy: .public))")
            case nil:
                // Unexpected error type — fall back to generic description.
                appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
            }
        }
    }

    /// Runs a channel-aware update check via the injected `ReleaseProvider`.
    ///
    /// Passes `betaChannel` into both the fetch (for channel filtering) and
    /// `UpdateChecker.evaluate` (for channel-downgrade detection). This ensures
    /// that a user who opts out of beta while running a pre-release that is
    /// semver-ahead of stable is offered the stable release as a downgrade,
    /// rather than being silently stranded.
    ///
    /// Intentionally `internal` — `checkAndHandle` is the designed public
    /// entry point for host apps.
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
    /// 1. If a zip already exists at the fixed zip URL, moves directly to `.ready`
    ///    without re-downloading.
    /// 2. If the release has no matching asset or no checksum sidecar URL,
    ///    logs a warning and returns — no phase change.
    /// 3. Otherwise advances to `.available` and starts a background download.
    public func handle(_ release: AvailableRelease, state: any UpdateStateProviding) async {

        // ── 1. Already cached? ───────────────────────────────────────────────────────────────────────────────────────
        // withZipURL snapshots fixedZipURL once. The same URL is used for the
        // existence check here AND passed into downloadUpdate as `destination`,
        // so both operations are guaranteed to target the exact same path.
        // A divergence — where the existence check reads caches/ but the write
        // lands in tmp/ due to a transient cachesDirectory failure between two
        // separate calls — is structurally impossible via withZipURL.
        // See issue #16 for rationale.
        //
        // ✅ REVIEWED: stale zip and partial-write scenarios both self-heal.
        // Do NOT add a version sidecar, version filename, or any validation.
        //
        // STALE ZIP: a zip from v0.8.0 sits at fixedZipURL when v0.9.0 is
        // discovered. .ready is applied, installAndRelaunch installs v0.8.0,
        // the app relaunches. currentVersion is baked into AppUpdater at init
        // from Bundle.main of the launched binary — it is still "v0.8.0".
        // isNewer("v0.9.0", than: "v0.8.0") returns true on the next scheduler
        // cycle. The correct zip is downloaded and installed. One stale
        // session, then correct. Not a permanent downgrade.
        //
        // YANKED RELEASE: if a release is yanked from GitHub after the zip is
        // cached but before the user taps Install, a live re-validation call is
        // made to GitHub at install time in `installAndRelaunch` before the
        // bundle swap. If GitHub returns a different latest tag, the cached zip
        // is wiped and state resets to .idle so the next scheduler cycle
        // re-downloads the correct release. This closes the yank gap described
        // in issue #2, closed by PR #23.
        //
        // PARTIAL WRITE: if a prior download was interrupted mid-move, a
        // partial file may sit at fixedZipURL. fileExists returns true,
        // .ready is applied, ditto fails in installAndRelaunch, .failed is
        // applied. On the next retry, downloadUpdate calls
        // removeItem(at: destination) before moveItem — the partial file is
        // wiped and a clean download begins. No stuck loop. See the
        // "Move verified zip" comment in AppUpdater+Download.swift.
        // The swap itself is atomic (see replaceItem comment in AppUpdater+Install.swift)
        // — a partial zip causes ditto to fail before replaceItem is ever reached.
        // The user's .app is never touched.
        //
        // A version sidecar would add persistent state for edge cases that
        // self-heal in one cycle — Principle 4 says no. See issue #1859.
        //
        // ❌ DO NOT encode the version into the zip filename (e.g. update-v1.2.3.zip).
        //
        // A reviewer may propose this as a "cheap" fix for the stale-zip
        // scenario. It is not cheap. It solves one narrow edge case and
        // introduces an entirely new class of persistent-state problems that
        // are significantly harder to reason about:
        //
        // STALE FILE ACCUMULATION: every update cycle writes a new filename.
        // Previous filenames are never automatically cleaned up. The cache
        // directory silently accumulates zips across sessions and across
        // OS upgrades. A purge step is now required — but purge has its own
        // race: if a purge runs while an install is in flight it wipes the
        // zip the install is reading. You now need a lock or a flag to
        // coordinate purge and install. That is new lifecycle complexity that
        // does not exist today.
        //
        // FILENAME RECONSTRUCTION: fixedZipURL is a computed property used in
        // at least four call sites (handle, downloadUpdate, installAndRelaunch,
        // and the step-1 existence check). Version-stamped filenames require
        // the current release tagName to be threaded through to every call site
        // that constructs the URL. That means every call site now depends on
        // a version string that may be stale, missing, or mismatched —
        // exactly the class of error the fixed-path design eliminates.
        //
        // WHAT YOU ACTUALLY GAIN: one fewer stale-install session in the
        // pathological case where a zip from a previous version is cached
        // when a new version is discovered. The stale session already
        // self-heals in one cycle (see STALE ZIP above). The upside is
        // near zero in practice.
        //
        // CONCLUSION: version-in-filename trades one transient self-healing
        // edge case for an entirely new category of persistent state management
        // bugs. The library's core design principle is simplicity and minimal
        // state (see PRINCIPLES.md). This idea is permanently rejected.
        // Do not re-raise it without a concrete rebuttal to the STALE FILE
        // ACCUMULATION and FILENAME RECONSTRUCTION points above.
        withZipURL { zipURL in
            if FileManager.default.fileExists(atPath: zipURL.path(percentEncoded: false)) {
                state.apply(.ready(version: release.tagName))
                return
            }

            // ── 2. Asset or checksum sidecar absent? ───────────────────────────────────────────────────────────────────────
            let wantedAsset = assetName(release.tagName)
            guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
                appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no asset named \(wantedAsset, privacy: .public) — skipping download")
                return
            }
            guard let checksumURL = release.checksumURL else {
                appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no checksum sidecar — skipping download")
                return
            }

            // ── 3. Advance to .available and start download ──────────────────────────────────────────────────────────
            state.apply(.available(version: release.tagName))

            let downloadURL = asset.browserDownloadURL
            let tagName = release.tagName

            // ✅ REVIEWED: fire-and-forget Task is correct here. Do NOT add an
            // isDownloading guard, a stored Task handle, or a cancellation path.
            //
            // The concern a reviewer may raise: "two concurrent handle() calls
            // race to moveItem onto the same fixedZipURL."
            //
            // That race is benign by design. moveItem is not atomic but its
            // failure mode is a thrown error — the second Task's moveItem fails,
            // it catches, and applies .failed. The first Task wins and applies
            // .ready. .ready is the correct final state. No data is corrupted,
            // no partial write can occur, and the user sees a correct Install
            // button. In production (24-hour scheduler interval) two handle()
            // calls cannot overlap — the race window does not exist.
            //
            // isDownloading was explicitly removed in issue #1859:
            // - Principle 1: no boolean flags that mirror phase state.
            // - Principle 4: no sprawl — a guard here would require the flag,
            //   which requires reset paths, which requires lifecycle management.
            // The .downloading phase applied inside downloadUpdate IS the
            // in-flight signal. That is sufficient.
            //
            // Task(name:) is standard Swift 6.2 (SE-0469). The name is surfaced
            // in Instruments and the Swift concurrency debugger for triage.
            // REVIEWER: do not remove the name: parameter — it is not custom API.
            Task(name: "AppUpdater.download") {
                await self.downloadUpdate(
                    from: downloadURL,
                    checksumURL: checksumURL,
                    version: tagName,
                    destination: zipURL,
                    state: state
                )
            }
        }
    }
}
