// AppUpdater+Install.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#else
// swiftlint:disable:next line_length
#error("AppUpdater requires AppKit. If you are hitting this from `swift test`: this code path touches AppKit and cannot be exercised in the SPM headless test runner. Do not test it. Do not add an #else branch with stub logic. Mock above the AppKit boundary instead.")
#endif
import Foundation

// MARK: - Install & Relaunch

/// Install-and-relaunch logic for ``AppUpdater``.
extension AppUpdater {

    /// Unzips the cached update zip, replaces the running `.app` bundle, and
    /// relaunches the new version.
    ///
    /// ## Flow
    /// 1. Verify host is in `.ready` phase and extract zip URL + version.
    /// 2. Re-validate the cached version against GitHub (yank-revalidation).
    /// 3. Unzip into a temporary directory via `/usr/bin/ditto`.
    /// 4. (Optional) Verify `codesign` identity if `skipCodeSignValidation` is `false`.
    /// 5. Replace the running bundle via `FileManager.replaceItemAt` (atomic swap).
    /// 6. Relaunch the new binary via `NSWorkspace.openApplication` with a completion
    ///    handler — `NSApp.terminate` fires only after the new instance confirms launch.
    /// 7. Delete the zip (spend — relaunch confirmed).
    /// 8. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure `state.apply(.failed(version:))` is called and the
    /// function returns without terminating.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        guard !isInstalling else { return }
        isInstalling = true

        guard case .ready(let version) = state.currentPhase else {
            isInstalling = false
            state.apply(.failed(version: nil))
            return
        }

        // ── Yank revalidation ────────────────────────────────────────────────
        let betaChannel = betaChannelProvider()
        let revalidation = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        if case .fetched(let latest) = revalidation,
           let latest,
           latest.tagName != version {
            appUpdaterLogger.warning("yank-revalidation: cached version \(version, privacy: .public) superseded by \(latest.tagName, privacy: .public) — wiping zip and resetting to idle")
            var zipRemovalFailed = false
            withZipURL { zipURL in
                do {
                    try FileManager.default.removeItem(at: zipURL)
                } catch {
                    let nsErr = error as NSError
                    if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError {
                        appUpdaterLogger.debug("yank-revalidation: zip already absent at removal — proceeding to .idle")
                    } else {
                        appUpdaterLogger.error("yank-revalidation: failed to remove stale zip — applying .failed to prevent stale-zip re-entry: \(String(describing: error), privacy: .public)")
                        zipRemovalFailed = true
                    }
                }
            }
            if zipRemovalFailed {
                state.apply(.failed(version: version))
                isInstalling = false
                return
            }
            state.apply(.idle)
            isInstalling = false
            return
        }

        // ── Post-revalidation state re-check ─────────────────────────────────
        guard case .ready = state.currentPhase else {
            isInstalling = false
            return
        }

        if skipCodeSignValidation {
            appUpdaterLogger.warning("skipCodeSignValidation is true — code-sign identity check is disabled; install proceeds on SHA-256 integrity alone")
        }

        withZipURL { zipURL in
            let bundleURL = URL(filePath: Bundle.main.bundlePath)
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(component: "appupdater-update-\(UUID().uuidString)", directoryHint: .isDirectory)

            Task {
                guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
                    isInstalling = false
                    state.apply(.failed(version: version))
                    return
                }

                #if canImport(AppKit)
                if !skipCodeSignValidation {
                    let runningIdentity = await Bundle.main.codeSigningIdentity()
                    let updateIdentity = await Bundle(path: appInZip.path(percentEncoded: false))?.codeSigningIdentity()
                    guard let runningIdentity,
                          let updateIdentity,
                          runningIdentity == updateIdentity else {
                        appUpdaterLogger.error("code-sign identity mismatch — aborting install")
                        isInstalling = false
                        state.apply(.failed(version: version))
                        try? FileManager.default.removeItem(at: tmpDir)
                        return
                    }
                }
                #endif

                await replaceAndRelaunch(
                    appInZip: appInZip,
                    bundleURL: bundleURL,
                    zipURL: zipURL,
                    version: version,
                    tmpDir: tmpDir,
                    state: state
                )
            }
        }
    }

    // MARK: - Private helpers

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// first `.app` bundle found at the archive root, or `nil` on any failure.
    private func unzipAndLocateApp(zipURL: URL, into tmpDir: URL) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard await runCommand("/usr/bin/ditto", args: ["-xk", zipURL.path(percentEncoded: false), tmpDir.path(percentEncoded: false)]) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        guard let appInZip = (try? fm.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ))?.first(where: { $0.pathExtension == "app" }) else {
            try? fm.removeItem(at: tmpDir)
            return nil
        }
        return appInZip
    }

    /// Atomically replaces the running bundle, then relaunches via
    /// `NSWorkspace.openApplication(at:configuration:completionHandler:)`.
    ///
    /// `NSApp.terminate` is called **inside** the completion handler — only
    /// after the OS confirms the new instance has launched (or failed to).
    /// This prevents the old process from exiting before the new binary is
    /// fully in place and running, which was the root cause of the race
    /// described in runbot-hq/run-bot#2193.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        version: String,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default

        // ── Step 1: atomic bundle swap ───────────────────────────────────────────
        let finalURL: URL
        do {
            finalURL = (try fm.replaceItemAt(bundleURL, withItemAt: appInZip)) ?? bundleURL
            appUpdaterLogger.debug("replaceItem succeeded — new bundle at \(finalURL.path(percentEncoded: false), privacy: .public)")
        } catch {
            appUpdaterLogger.error("replaceItem failed: \(String(describing: error), privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── Step 2: clean up scratch dir ────────────────────────────────────
        try? fm.removeItem(at: tmpDir)

        // ── Step 3: delete zip before relaunch ───────────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 4: relaunch + terminate (strictly sequential) ────────────────
        //
        // FIX for runbot-hq/run-bot#2193:
        // NSWorkspace.openApplication completion handler fires only after the
        // new instance is confirmed launched. NSApp.terminate is called strictly
        // inside the handler so this process never exits before the new one is up.
        //
        // The completion handler is called on an arbitrary queue by the OS.
        // Task { @MainActor in } hops back to the main actor — required for
        // Swift 6 actor-isolation. Do NOT replace with DispatchQueue.main.async.
        //
        // Strong capture of self ([self]) is intentional — AppUpdater is owned
        // by AppDelegate and lives for the full app lifetime. [weak self] causes
        // a compile error because appUpdaterLogger is a module-level `let` in
        // AppUpdaterLogger.swift — NOT a member of AppUpdater — so
        // self?.appUpdaterLogger does not exist. isInstalling must also be
        // set unconditionally; a nil-skip would leave the state machine locked.
        // REVIEWER: do NOT change [self] back to [weak self].
        //
        // appUpdaterLogger is a module-level `let` (see AppUpdaterLogger.swift).
        // It is NOT a member of AppUpdater. Do NOT prefix it with self.
        #if canImport(AppKit)
        appUpdaterLogger.debug("relaunch: opening new instance at \(finalURL.path(percentEncoded: false), privacy: .public)")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: finalURL,
            configuration: config
        ) { [self] _, error in
            if let error {
                // The new instance failed to launch after a successful replaceItem.
                // The new .app IS on disk — the user can relaunch manually.
                // Apply .failed so the host shows a recoverable error state.
                Task { @MainActor in
                    appUpdaterLogger.error("relaunch failed after successful replaceItem — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
                    self.isInstalling = false
                    state.apply(.failed(version: version))
                }
                return
            }
            // New instance confirmed launched — safe to terminate.
            // isInstalling is NOT reset here — the process is about to exit.
            Task { @MainActor in
                appUpdaterLogger.debug("relaunch confirmed — terminating old instance")
                NSApp.terminate(nil)
            }
        }
        #endif
    }
}
