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
    /// 6. Verify the swapped bundle's version matches the expected version.
    /// 7. Delete the zip (swap verified — zip is spent).
    /// 8. Relaunch the new binary via `NSWorkspace.openApplication` with a completion handler.
    /// 9. Terminate this process via `NSApp.terminate` inside the relaunch completion handler.
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

        // ── Yank revalidation ─────────────────────────────────────────────────
        // Extracted to yankRevalidate(version:state:) — see that function's doc
        // for the full decision table and rationale.
        let yanked = await yankRevalidate(version: version, state: state)
        if yanked { return }

        // ── Post-revalidation state re-check ──────────────────────────────────
        // fetchLatestRelease inside yankRevalidate is the first suspension point.
        // While suspended another @MainActor task could have moved state away
        // from .ready (e.g. a future cancel API). Guard defensively; cost is zero.
        guard case .ready = state.currentPhase else {
            isInstalling = false
            return
        }

        if skipCodeSignValidation {
            appUpdaterLogger.warning("""
                skipCodeSignValidation is true — code-sign identity check is disabled; \
                install proceeds on SHA-256 integrity alone
                """)
        }

        withZipURL { zipURL in
            let bundleURL = URL(filePath: Bundle.main.bundlePath)
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(component: "appupdater-update-\(UUID().uuidString)", directoryHint: .isDirectory)

            // Task {} is NOT detached — inherits @MainActor isolation from
            // installAndRelaunch. isInstalling and state.apply are race-free.
            // Do NOT add Task.detached or remove @MainActor from installAndRelaunch.
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

    /// Performs yank-revalidation: confirms with GitHub that the cached version
    /// is still the latest eligible release before touching the zip.
    ///
    /// ## Decision table (optimistic-on-failure, matching Sparkle / Squirrel)
    ///
    /// | Revalidation result              | Action  |
    /// |----------------------------------|---------|
    /// | `.failed`                        | proceed — network unreachable / GitHub down / rate-limited; not evidence of a yank |
    /// | `.fetched(nil)`                  | proceed — no channel match is not a yank; treat as inconclusive |
    /// | `.fetched(r)` where `r.tag == ver` | proceed — GitHub confirms current |
    /// | `.fetched(r)` where `r.tag != ver` | **abort** — GitHub returned a different tag; zip is stale or yanked |
    ///
    /// On abort the stale zip is removed and `.idle` is applied so the next
    /// scheduler cycle re-downloads the real current release.
    ///
    /// - Returns: `true` if install should be aborted (zip was yanked), `false` to proceed.
    @MainActor
    private func yankRevalidate(version: String, state: any UpdateStateProviding) async -> Bool {
        let betaChannel = betaChannelProvider()
        let revalidation = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        guard case .fetched(let latest) = revalidation,
              let latest,
              latest.tagName != version else {
            return false
        }
        // GitHub confirmed a different latest tag — zip is stale or yanked.
        appUpdaterLogger.warning("""
            yank-revalidation: cached version \(version, privacy: .public) \
            superseded by \(latest.tagName, privacy: .public) \
            — wiping zip and resetting to idle
            """)
        var zipRemovalFailed = false
        withZipURL { zipURL in
            do {
                try FileManager.default.removeItem(at: zipURL)
            } catch {
                let nsErr = error as NSError
                if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError {
                    appUpdaterLogger.debug("yank-revalidation: zip already absent at removal — proceeding to .idle")
                } else {
                    appUpdaterLogger.error("""
                        yank-revalidation: failed to remove stale zip \
                        — applying .failed: \(String(describing: error), privacy: .public)
                        """)
                    zipRemovalFailed = true
                }
            }
        }
        if zipRemovalFailed {
            state.apply(.failed(version: version))
            isInstalling = false
            return true
        }
        state.apply(.idle)
        isInstalling = false
        return true
    }

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// first `.app` bundle found at the archive root, or `nil` on any failure.
    ///
    /// AppUpdater picks the **first** `.app` at the zip root — packaging exactly
    /// one `.app` at the root is the consumer's contract. Multiple `.app` bundles
    /// is a consumer packaging error; AppUpdater silently picks the first.
    /// REVIEWER: do NOT add a uniqueness assertion here.
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

    /// Reads `CFBundleShortVersionString` from a bundle's `Info.plist` off the
    /// main actor (blocking I/O must not run on actor cooperative threads).
    ///
    /// `@concurrent` requires `async` — the function is marked async so the
    /// compiler can schedule it off the calling actor's executor. The body is
    /// synchronous (one local plist read), but the `async` declaration is the
    /// mechanism that allows `@concurrent` to take effect.
    ///
    /// Returns `nil` if the plist is absent or the key is missing.
    @concurrent
    private func readBundleVersion(at bundleURL: URL) async -> String? {
        let infoPlistURL = bundleURL.appending(path: "Contents/Info.plist")
        let info = NSDictionary(contentsOf: infoPlistURL)
        return info?["CFBundleShortVersionString"] as? String
    }

    /// Atomically replaces the running bundle, verifies the swap, relaunches
    /// via `NSWorkspace.openApplication`, then terminates via `NSApp.terminate`
    /// inside the completion handler.
    ///
    /// ## Atomic swap
    /// `replaceItemAt` is atomic — on failure `bundleURL` is preserved exactly
    /// as it was. Do NOT replace with `removeItem + copyItem`.
    ///
    /// ## Post-swap version verification
    /// `replaceItemAt` not throwing is necessary but not sufficient. We read
    /// `CFBundleShortVersionString` from the swapped bundle and compare it to
    /// the expected tag (leading `v` stripped). Mismatch → `.failed`, no relaunch.
    /// Fixes runbot-hq/run-bot#2193.
    ///
    /// ## Why `NSWorkspace` instead of `open -n`
    /// `open -n` returns before the new process is up. `openApplication` calls
    /// back only after launch, making `NSApp.terminate` deterministic.
    @MainActor // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
    private func replaceAndRelaunch(
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        version: String,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default

        // ── Step 1: atomic bundle swap ────────────────────────────────────────
        let finalURL: URL
        do {
            finalURL = (try fm.replaceItemAt(bundleURL, withItemAt: appInZip)) ?? bundleURL
            appUpdaterLogger.debug("""
                replaceItem succeeded — new bundle at \
                \(finalURL.path(percentEncoded: false), privacy: .public)
                """)
        } catch {
            appUpdaterLogger.error("replaceItem failed: \(String(describing: error), privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── Step 2: clean up scratch dir ─────────────────────────────────────
        try? fm.removeItem(at: tmpDir)

        // ── Steps 3–5: verify, delete zip, relaunch ───────────────────────────
        // All three steps share one #if block — verification, zip deletion, and
        // relaunch form one logical unit. Do NOT split into separate #if blocks.
        #if canImport(AppKit)

        // ── Step 3: post-swap version verification ────────────────────────────
        let swappedVersion = await readBundleVersion(at: finalURL)
        let expectedBundleVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard swappedVersion == expectedBundleVersion else {
            appUpdaterLogger.error("""
                post-swap verification failed: \
                expected \(expectedBundleVersion, privacy: .public), \
                got \(swappedVersion ?? "nil", privacy: .public) \
                at \(finalURL.path(percentEncoded: false), privacy: .public) \
                — aborting relaunch
                """)
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }
        appUpdaterLogger.debug("""
            post-swap verification passed: \
            \(swappedVersion ?? "nil", privacy: .public) == \(expectedBundleVersion, privacy: .public)
            """)

        // ── Step 4: delete zip (swap verified) ────────────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 5: relaunch via NSWorkspace ──────────────────────────────────
        await relaunchApp(at: finalURL, version: version, state: state)

        #endif // canImport(AppKit)
    }

    /// Relaunches the app at `finalURL` via `NSWorkspace.openApplication` and
    /// terminates the current process inside the completion handler.
    ///
    /// Extracted from `replaceAndRelaunch` to satisfy `function_body_length`.
    /// The two functions form one logical unit.
    ///
    /// ## Capture semantics
    /// Strong capture of `self` is intentional — AppUpdater is owned by
    /// AppDelegate and lives for the full app lifetime. `[weak self]` would
    /// silently skip `isInstalling = false` on the error path, permanently
    /// locking the state machine. REVIEWER: do NOT change to `[weak self]`.
    @MainActor
    private func relaunchApp(
        at finalURL: URL,
        version: String,
        state: any UpdateStateProviding
    ) async {
        #if canImport(AppKit)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: finalURL, configuration: config) { [self] _, error in
            if let error {
                Task { @MainActor in
                    appUpdaterLogger.error("""
                        NSWorkspace.openApplication failed after verified swap \
                        — new binary is on disk, relaunch manually: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    self.isInstalling = false
                    state.apply(.failed(version: version))
                }
            } else {
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
        #endif
    }
}
