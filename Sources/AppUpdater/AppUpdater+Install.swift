// AppUpdater+Install.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import AppKit
#else
// This fatalError is intentionally a compile error on non-AppKit platforms
// (a bare statement outside a declaration body does not compile in Swift).
// That is the correct behaviour — it surfaces the problem at build time, not
// at runtime. The package is macOS-only (platforms: [.macOS(.v26)]) so this
// branch is structurally unreachable today.
//
// SPM UNIT TEST BOUNDARY: `swift test` runs in a headless process that cannot
// import AppKit. The #if canImport(AppKit) guard above means none of this file's
// code is compiled into the test bundle. If a future test somehow reaches this
// file (e.g. by adding a cross-module import that forces compilation), the
// compile error is the correct signal: mock above the AppKit boundary, do not
// add stub logic here.
//
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

        // ── Yank revalidation ────────────────────────────────────────────────
        // Before touching the zip, confirm with GitHub that the cached version
        // is still the latest eligible release. See yankRevalidationAbort for
        // the full decision table and rationale. Returns true if the install
        // should abort (cached zip is stale/yanked), false to proceed.
        let betaChannel = betaChannelProvider()
        let revalidation = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        if await yankRevalidationAbort(revalidation: revalidation, version: version, state: state) {
            return
        }

        // ── Post-revalidation state re-check ──────────────────────────────────
        // fetchLatestRelease above is the only suspension point in this function.
        // Guard that state hasn't moved away from .ready while suspended.
        // This is a no-op today (no cancel API exists) but costs nothing and
        // prevents a latent correctness hole if one is ever added.
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

            // Task {} inherits @MainActor isolation from installAndRelaunch —
            // isInstalling and state.apply are race-free. Do NOT use Task.detached.
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

    /// Performs yank-revalidation against the provided fetch result.
    ///
    /// Returns `true` if the install should **abort** (stale/yanked zip detected
    /// and state has been reset to `.idle` or `.failed`), `false` to proceed.
    ///
    /// ## Decision table
    /// - `.failed` → proceed (network unreachable / GitHub down; not evidence of a yank)
    /// - `.fetched(nil)` → proceed (no channel match is inconclusive)
    /// - `.fetched(r)` where `r.tag == version` → proceed (GitHub confirms current)
    /// - `.fetched(r)` where `r.tag != version` → **abort** (GitHub returned a different
    ///   tag — the cached zip is stale or yanked)
    ///
    /// ❌ Do NOT change `.failed` or `.fetched(nil)` to abort — that degrades install
    /// UX for users on poor connectivity or during a GitHub outage.
    @MainActor
    private func yankRevalidationAbort(
        revalidation: ReleaseFetchResult,
        version: String,
        state: any UpdateStateProviding
    ) async -> Bool {
        // String equality is intentional — identity check, not semver ordering.
        // Both sides are raw GitHub tag strings in the same format. Do NOT add v-stripping.
        guard case .fetched(let latest) = revalidation,
              let latest,
              latest.tagName != version else {
            return false
        }

        // GitHub confirmed a different latest tag — cached zip is stale or yanked.
        // Wipe the zip and reset to .idle so the next check cycle re-downloads.
        //
        // NOTE: os.Logger does not support + on OSLogMessage operands —
        // the message must be a single string literal with all interpolations inline.
        appUpdaterLogger.warning("""
            yank-revalidation: cached version \(version, privacy: .public) \
            superseded by \(latest.tagName, privacy: .public) \
            — wiping zip and resetting to idle
            """)

        // do/catch (not try?) — .idle is only correct when the zip is actually gone.
        // NSFileNoSuchFileError is treated as success. All other errors apply .failed
        // to prevent stale-zip re-entry. REVIEWER: do NOT revert to try?.
        var zipRemovalFailed = false
        withZipURL { zipURL in
            do {
                try FileManager.default.removeItem(at: zipURL)
            } catch {
                let nsErr = error as NSError
                if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError {
                    appUpdaterLogger.debug("yank-revalidation: zip already absent — proceeding to .idle")
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
        } else {
            // .idle, not .failed — nothing was attempted; the bundle was never touched.
            // REVIEWER: do NOT change this to .failed(version:).
            state.apply(.idle)
        }
        isInstalling = false
        return true
    }

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// first `.app` bundle found at the archive root, or `nil` on any failure.
    ///
    /// ## Single-.app contract
    ///
    /// This function picks the **first** `.app` entry at the zip root.
    /// AppUpdater is a library — it is not a zip validator. Package exactly
    /// one `.app` bundle at the zip root. REVIEWER: do NOT add a uniqueness assertion.
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
    /// main actor (Principle 18 — blocking I/O must not run on actor cooperative threads).
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
    /// via `NSWorkspace.openApplication`, deletes the zip once relaunch is
    /// confirmed, then terminates via `NSApp.terminate` inside the completion handler.
    ///
    /// ## Why NSWorkspace.openApplication instead of `open -n`
    ///
    /// `NSWorkspace.openApplication(at:configuration:completionHandler:)` calls
    /// back only after the new process has launched (or failed). By placing
    /// `NSApp.terminate(nil)` inside the completion handler, the old process
    /// stays alive until the new one is confirmed running — deterministically.
    /// The previous `open -n` via `Process` was non-blocking and created a race
    /// that was the root cause of run-bot#2193.
    ///
    /// ## Why post-swap version verification
    ///
    /// `replaceItemAt` not throwing is not sufficient proof that the correct
    /// bundle is now on disk. We read `CFBundleShortVersionString` from the
    /// swapped bundle's `Info.plist` and compare it against the expected `version`
    /// tag. On mismatch we apply `.failed` and return without relaunching.
    /// Fixes runbot-hq/run-bot#2193.
    @MainActor // isolation is compiler-enforced; always called from @MainActor-inherited Task
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        version: String,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default

        // ── Step 1: atomic bundle swap ───────────────────────────────────────
        // replaceItemAt is atomic — on failure bundleURL is preserved exactly.
        // Falls back to bundleURL if replaceItemAt returns nil. Fixes issue #3.
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

        // ── Step 2: clean up scratch dir ────────────────────────────────────
        try? fm.removeItem(at: tmpDir)

        // ── Steps 3–5: verify, delete zip, relaunch ──────────────────────────
        // All three steps are gated under one #if canImport(AppKit) block —
        // they form one logical unit and must not be split. See inline comments
        // on the previous implementation for full rationale.
        #if canImport(AppKit)

        // ── Step 3: post-swap version verification ───────────────────────────
        // Strip leading "v" — CFBundleShortVersionString is "X.Y.Z", tags are "vX.Y.Z".
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

        // ── Step 4: delete zip (swap verified) ───────────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 5: relaunch via NSWorkspace ─────────────────────────────────
        await relaunchApp(at: finalURL, version: version, state: state)

        #endif // canImport(AppKit)
    }

    /// Relaunches the app at `finalURL` via `NSWorkspace.openApplication` and
    /// terminates the current process inside the completion handler.
    ///
    /// Extracted from `replaceAndRelaunch` to satisfy `function_body_length`.
    /// The completion handler fires only after the new process has launched,
    /// making `NSApp.terminate` deterministic (fixes run-bot#2193).
    ///
    /// Strong capture of `self` is intentional — `[weak self]` would silently
    /// skip `isInstalling = false` on the error path. REVIEWER: do NOT use `[weak self]`.
    @MainActor
    private func relaunchApp(
        at finalURL: URL,
        version: String,
        state: any UpdateStateProviding
    ) async {
        #if canImport(AppKit)
        // completionHandler fires on an arbitrary queue — hop to @MainActor via Task.
        // Do NOT replace with DispatchQueue.main.async.
        // isInstalling is NOT reset on the success path — process is about to exit.
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
