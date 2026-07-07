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
    /// `.upToDate` and `.failed` are no-ops here — the background scheduler
    /// owns the stale-row-clearing policy.
    public func checkAndHandle(state: any UpdateStateProviding) async {
        let beta = betaChannelProvider()
        switch await checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            appUpdaterLogger.debug("update available: \(release.tagName, privacy: .public) (beta=\(beta, privacy: .public))")
            await handle(release, state: state)
        case .upToDate:
            appUpdaterLogger.debug("no update available (beta=\(beta, privacy: .public))")
        case .failed(let error):
            appUpdaterLogger.debug("update check failed: \(String(describing: error), privacy: .public) (beta=\(beta, privacy: .public))")
        }
    }

    /// Runs a channel-aware update check via the injected `ReleaseProvider`.
    func checkForUpdate(betaChannel: Bool) async -> UpdateCheckResult {
        let fetchResult = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        return UpdateChecker.evaluate(fetchResult: fetchResult, currentVersion: currentVersion)
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
        withZipURL { zipURL in
            // Use .path(percentEncoded: false) — .path is deprecated in macOS 13+.
            if FileManager.default.fileExists(atPath: zipURL.path(percentEncoded: false)) {
                state.apply(.ready(version: release.tagName))
                return
            }

            let wantedAsset = assetName(release.tagName)
            guard let asset = release.assets.first(where: { $0.name == wantedAsset }) else {
                appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no asset named \(wantedAsset, privacy: .public) — skipping download")
                return
            }
            guard let checksumURL = release.checksumURL else {
                appUpdaterLogger.warning("release \(release.tagName, privacy: .public) has no checksum sidecar — skipping download")
                return
            }

            state.apply(.available(version: release.tagName))
            let downloadURL = asset.browserDownloadURL
            let tagName = release.tagName

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
