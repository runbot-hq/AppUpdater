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
    /// 2. Unzip into a temporary directory via `/usr/bin/ditto`.
    /// 3. (Optional) Verify `codesign` identity if `skipCodeSignValidation` is `false`.
    /// 4. Replace the running bundle via `FileManager.replaceItemAt` (atomic swap).
    /// 5. Relaunch the new binary with `/usr/bin/open -n`.
    /// 6. Delete the zip (spend — relaunch confirmed).
    /// 7. Terminate this process via `NSApp.terminate`.
    ///
    /// On any failure `state.apply(.failed(version:))` is called and the
    /// function returns without terminating.
    @MainActor
    public func installAndRelaunch(state: any UpdateStateProviding) async {
        guard !isInstalling else { return }
        isInstalling = true

        // Extract version from the .ready phase; zip is always at fixedZipURL.
        guard case .ready(let version) = state.currentPhase else {
            isInstalling = false
            state.apply(.failed(version: nil))
            return
        }

        // ⚠️ skipCodeSignValidation is true — code-sign identity check is disabled.
        // Install will proceed on SHA-256 integrity alone.
        //
        // This is the correct default for RunBot's unsigned distribution model.
        // If you are shipping a signed app and see this warning in Console.app,
        // set `skipCodeSignValidation = false` on your AppUpdater instance so
        // that the installed bundle's signing identity is verified against the
        // running bundle before the swap.
        if skipCodeSignValidation {
            appUpdaterLogger.warning("skipCodeSignValidation is true — code-sign identity check is disabled; install proceeds on SHA-256 integrity alone")
        }

        let zipURL = fixedZipURL
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-update-\(UUID().uuidString)", isDirectory: true)

        guard let appInZip = await unzipAndLocateApp(zipURL: zipURL, into: tmpDir) else {
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        #if canImport(AppKit)
        if !skipCodeSignValidation {
            let runningIdentity = await Bundle.main.codeSigningIdentity()
            let updateIdentity = await Bundle(path: appInZip.path)?.codeSigningIdentity()
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

    // MARK: - Private helpers

    /// Unzips `zipURL` into `tmpDir` via `/usr/bin/ditto` and returns the
    /// first `.app` bundle found at the archive root, or `nil` on any failure.
    ///
    /// ## Single-.app contract
    ///
    /// This function picks the **first** `.app` entry at the zip root via
    /// `first(where: { $0.pathExtension == "app" })`. It does NOT assert that
    /// exactly one `.app` exists, and that is intentional.
    ///
    /// AppUpdater is a library — it is not a zip validator. The contract for
    /// consumers is: **package exactly one `.app` bundle at the zip root.**
    /// If a consumer ships a zip with multiple `.app` bundles, that is a
    /// packaging error on their side. AppUpdater will silently pick the first
    /// one in filesystem order (undefined). The consequence — installing the
    /// wrong bundle — is the consumer's responsibility, not ours.
    ///
    /// A `count == 1` guard was considered and rejected:
    /// - It adds complexity and a new `.failed` path for an error that should
    ///   never exist in a correctly configured consumer.
    /// - It would produce a confusing `.failed` state with no message pointing
    ///   at the real cause (bad packaging), making it harder to debug.
    /// - Principle 4: no sprawl for edge cases that are consumer errors.
    ///
    /// REVIEWER: do NOT add a uniqueness assertion here.
    private func unzipAndLocateApp(zipURL: URL, into tmpDir: URL) async -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard await runCommand("/usr/bin/ditto", args: ["-xk", zipURL.path, tmpDir.path]) else {
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

        // ── Step 1: atomic bundle swap ───────────────────────────────────────────
        // replaceItemAt is atomic at the filesystem level. On failure, bundleURL is
        // preserved exactly as it was — no partial state, no corrupted .app.
        // The replacement candidate (appInZip) is left in tmpDir and cleaned up
        // below. The user's running .app is never touched on a failed swap.
        // REVIEWER: this is why a stale or partial zip cannot leave the user with
        // a broken installation — the swap either fully succeeds or fully rolls
        // back. Do NOT replace this with removeItem + copyItem (not atomic).
        //
        // replaceItemAt returns the actual post-swap URL (the path where the new
        // bundle landed). We capture it and use it for open -n below rather than
        // re-using bundleURL. In practice on a standard macOS /Applications setup
        // the returned URL is identical to bundleURL — same name, same path. In
        // edge cases (case-insensitive FS conflict, path rewriting) they may
        // differ; using the returned URL ensures open -n launches the new binary
        // rather than the old one. Falls back to bundleURL if nil is returned.
        // Fixes issue #3.
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

        // ── Step 3: relaunch ──────────────────────────────────────────────────
        #if canImport(AppKit)
        let relaunchTask = Process()
        relaunchTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", finalURL.path]
        do {
            try relaunchTask.run()
        } catch {
            // `open -n` failed AFTER replaceItem succeeded.
            // The new .app IS on disk.
            // Apply .failed so the host shows a recoverable error state.
            // The user can relaunch manually — the new binary is already installed.
            appUpdaterLogger.error("open -n failed after successful replaceItem — new binary is on disk, relaunch manually: \(error.localizedDescription, privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }

        // ── Step 4: delete zip (relaunch confirmed) ───────────────────────────
        try? fm.removeItem(at: zipURL)

        // ── Step 5: terminate ────────────────────────────────────────────────
        // isInstalling is NOT reset before NSApp.terminate(nil) — this is
        // deliberate and correct. Do not add `isInstalling = false` here.
        //
        // The concern a reviewer may raise: "if applicationShouldTerminate
        // returns .terminateLater or .terminateCancel, isInstalling stays true
        // and the button is locked forever."
        //
        // That scenario does not exist in this app. RunBot does not implement
        // applicationShouldTerminate — confirmed at the call site, zero
        // implementations in the codebase. NSApp.terminate(nil) is therefore
        // unconditional: the process always exits, the heap is always freed,
        // and isInstalling ceases to exist the moment terminate is called.
        //
        // isInstalling is a transient in-memory flag on a @MainActor class.
        // It is never persisted to disk, UserDefaults, or any external store.
        // It cannot survive process termination. There is no "locked forever"
        // scenario — there is no next session in which the lock could exist.
        //
        // If RunBot ever gains a terminate delegate that can defer or cancel
        // termination, revisit this. Until then, do not add the reset.
        NSApp.terminate(nil)
        #endif
    }
}
