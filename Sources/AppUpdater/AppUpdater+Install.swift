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
    /// 6. Relaunch the new binary with `/usr/bin/open -n`.
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

        if case .fetched(let latest) = revalidation, let latest, latest.tagName != version {
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
            // Use URL(filePath:) — URL(fileURLWithPath:) is deprecated in macOS 13+.
            let bundleURL = URL(filePath: Bundle.main.bundlePath)
            // Use appending(component:directoryHint:) — appendingPathComponent(_:isDirectory:)
            // is superseded in macOS 13+.
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
                    guard let runningIdentity, let updateIdentity,
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
        // Use .path(percentEncoded: false) — .path is deprecated in macOS 13+.
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

    /// Atomically replaces the running bundle, relaunches via `open -n`, deletes
    /// the zip once relaunch is confirmed, then terminates via `NSApp.terminate`.
    private func replaceAndRelaunch( // skipcq: SW-R1002 — reviewed; sequential install steps, complexity is inherent
        appInZip: URL,
        bundleURL: URL,
        zipURL: URL,
        version: String,
        tmpDir: URL,
        state: any UpdateStateProviding
    ) async {
        let fm = FileManager.default

        // ── Step 1: atomic bundle swap ──────────────────────────────────────────
        let finalURL: URL
        do {
            finalURL = (try fm.replaceItemAt(bundleURL, withItemAt: appInZip)) ?? bundleURL
        } catch {
            appUpdaterLogger.error("replaceItem failed: \(String(describing: error), privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            try? fm.removeItem(at: tmpDir)
            return
        }

        // ── Step 2: clean up scratch dir ────────────────────────────────────
        try? fm.removeItem(at: tmpDir)

        // ── Step 3: relaunch ─────────────────────────────────────────────────
        #if canImport(AppKit)
        let relaunchTask = Process()
        // Use URL(filePath:) — URL(fileURLWithPath:) is deprecated in macOS 13+.
        relaunchTask.executableURL = URL(filePath: "/usr/bin/open")
        // Use .path(percentEncoded: false) — .path is deprecated in macOS 13+.
        relaunchTask.arguments = ["-n", finalURL.path(percentEncoded: false)]
        do {
            try relaunchTask.run()
        } catch {
            appUpdaterLogger.error("open -n failed after successful replaceItem — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        // ── Step 4: delete zip (relaunch confirmed) ───────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 5: terminate ────────────────────────────────────────────────
        NSApp.terminate(nil)
        #endif
    }
}
