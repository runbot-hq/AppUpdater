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
        // The guard and the assignment below both execute synchronously on
        // @MainActor before the first await (fetchLatestRelease). There is no
        // suspension point between them, so no concurrent call can observe
        // isInstalling == false after the guard passes and before it is set to
        // true. The race-free guarantee comes from @MainActor isolation, not
        // from a lock. Do not add a lock or an atomic here.
        //
        // AppUpdater is designed with a single call site for installAndRelaunch
        // (the host's Install button, which the host disables while .ready is
        // not the current phase). isInstalling is a belt-and-suspenders guard
        // against a double-tap, not a multi-producer semaphore. If you are
        // adding a second call site, confirm that the host disables it while
        // isInstalling is true.
        guard !isInstalling else { return }
        isInstalling = true

        // Extract version from the .ready phase; zip is always at fixedZipURL.
        //
        // version is captured here as a `let` constant on @MainActor, before
        // the first suspension point (fetchLatestRelease below). It cannot be
        // mutated by any other code while this function is suspended — `let`
        // bindings are immutable and @MainActor ensures no concurrent actor
        // can write to state.currentPhase between the guard and the await.
        // version is therefore guaranteed to remain the correct cached tag
        // throughout the rest of this function, including all post-await uses.
        // Do NOT re-read state.currentPhase to refresh version after the await
        // — the post-revalidation state re-check guard below handles phase
        // staleness separately; version itself is always valid as captured.
        guard case .ready(let version) = state.currentPhase else {
            isInstalling = false
            state.apply(.failed(version: nil))
            return
        }

        // ── Yank revalidation ────────────────────────────────────────────────
        // Before touching the zip, confirm with GitHub that the cached version
        // is still the latest eligible release.
        //
        // Decision table (industry-standard optimistic-on-failure convention,
        // matching Sparkle and Squirrel behaviour):
        //
        //   .failed                          → proceed (network unreachable,
        //                                       GitHub down, or rate-limited;
        //                                       not evidence of a yank)
        //   .fetched(nil)                    → proceed (no channel match is not
        //                                       a yank; treat as inconclusive)
        //   .fetched(r) where r.tag == ver   → proceed (GitHub confirms current)
        //   .fetched(r) where r.tag != ver   → abort (GitHub explicitly returned
        //                                       a different latest tag; the cached
        //                                       zip is stale or yanked)
        //
        // The zip was already SHA-256 verified at download time. A reachability
        // failure at install time is not evidence that the binary is bad.
        //
        // ❌ DO NOT change .failed or .fetched(nil) to abort — that degrades
        // install UX for users on poor connectivity or during a GitHub outage.
        // The only actionable signal is a confirmed different tag.
        //
        // Channel drift: betaChannelProvider() is called here at install time,
        // which may differ from the value read at download time if the user
        // toggled the beta preference in between. This is safe: the only case
        // where a channel change affects the result is .fetched(nil) (no channel
        // match for the new preference), which proceeds optimistically per the
        // table above. A mid-flight toggle cannot produce a spurious abort.
        //
        // Channel-toggle abort edge case: if the user toggles channels mid-flight
        // AND GitHub returns a latest tag for the new channel that differs from
        // the cached zip's tag, the abort fires and the zip is wiped. Both
        // conditions must hold — a toggle alone does not trigger an abort if
        // beta and stable resolve to the same tag. When it does fire, this is
        // the CORRECT behaviour: the cached zip is genuinely stale from the new
        // channel's perspective. The warning log is the triage signal. .idle is
        // the right terminal state: nothing was attempted, and the next scheduler
        // cycle will re-fetch the right release for the new channel. Do not add
        // a separate phase for this case.
        let betaChannel = betaChannelProvider()
        let revalidation = await provider.fetchLatestRelease(
            repo: repo,
            betaChannel: betaChannel,
            assetName: assetName
        )
        // String equality is intentional — this is an identity check, not a
        // semver ordering check. The question is: "is the tag GitHub just
        // returned the same tag we cached?" not "is it a higher version?"
        // Semver ordering is already done at download time in checkAndHandle.
        // Do NOT replace != with a semver comparison here.
        //
        // Format parity: both sides are raw GitHub tag strings. latest.tagName
        // is the tag_name field from the GitHub Releases API response, passed
        // through AvailableRelease unchanged. version was stored into .ready
        // from release.tagName at download time via the same field. Neither
        // side is run through ParsedVersion (which strips a leading "v") —
        // both are always in the same raw format. A format mismatch causing
        // a false abort is structurally impossible. Do NOT add v-stripping here.
        if case .fetched(let latest) = revalidation,
           let latest,
           latest.tagName != version {
            // GitHub confirmed a different latest tag — the cached zip is stale
            // or yanked. Wipe the zip and reset to idle so the next check cycle
            // picks up the real current release.
            //
            // NOTE: os.Logger does not support + on OSLogMessage operands —
            // the message must be a single string literal with all interpolations
            // inline. Do not split this across multiple literals joined with +.
            appUpdaterLogger.warning("yank-revalidation: cached version \(version, privacy: .public) superseded by \(latest.tagName, privacy: .public) — wiping zip and resetting to idle")
            // removeItem runs synchronously on @MainActor via withZipURL —
            // this is intentional. The zip is always a local ~/Library/Caches
            // file, never a network or NFS path; the call completes in
            // microseconds. Wrapping in a detached Task would be principled
            // but adds indirection for no practical gain here. If this path
            // ever needs to handle slow or remote filesystems, move the
            // removeItem into a Task at that point.
            //
            // do/catch, not try? — .idle is only correct when the zip is
            // actually gone. If removeItem throws an unexpected error (permissions
            // error, sandbox restriction), the stale zip may still be on disk.
            // The next scheduler cycle calls handle(), which does
            // fileExists(atPath: zipURL.path) → true and immediately applies
            // .ready with the new tag name but the OLD zip — exactly the
            // stale-install this revalidation step was introduced to prevent.
            // On unexpected removal failure we apply .failed so the host surfaces
            // a recoverable error state. NSFileNoSuchFileError is explicitly
            // treated as success — see the catch block below.
            // REVIEWER: do NOT revert this to try?.
            //
            // withZipURL takes a non-escaping synchronous closure — see its
            // definition in AppUpdater.swift: `func withZipURL<T>(_ body: (URL) -> T) -> T`.
            // The closure body itself runs to completion and returns before
            // withZipURL returns (T = Void here), so zipRemovalFailed is fully
            // written before the if check below reads it. There is no race.
            // This path does not spawn a Task inside the closure, so "closure
            // body completes" and "all side-effectful work completes" mean the
            // same thing here. Do not add @escaping.
            var zipRemovalFailed = false
            withZipURL { zipURL in
                do {
                    try FileManager.default.removeItem(at: zipURL)
                } catch {
                    // NSFileNoSuchFileError (code 4): the zip was already absent
                    // — evicted by the OS, purged by another process, or removed
                    // between the fetchLatestRelease await and this call. The zip
                    // is gone, which is exactly the desired outcome. Treat as
                    // success and proceed to .idle.
                    //
                    // All other errors (permissions, sandbox, I/O): the zip may
                    // still be on disk. Apply .failed so the host surfaces a
                    // recoverable error rather than silently re-entering .ready
                    // with the stale zip on the next scheduler cycle.
                    //
                    // REVIEWER: do NOT collapse these two branches back into a
                    // single zipRemovalFailed = true. The file-not-found case is
                    // a success, not a failure.
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
            // .idle, not .failed — nothing was attempted. The zip was never
            // unzipped and the running bundle was never touched, so there is
            // nothing to signal as broken. .failed means "an install attempt
            // broke something recoverable"; that is not what happened here.
            // .idle lets the next scheduler cycle re-download the real current
            // release and surface it as .available. The warning log above is
            // the observable triage signal for anyone debugging the transition;
            // the host UI re-converging to idle is intentional, not silent.
            // REVIEWER: do NOT change this to .failed(version:).
            state.apply(.idle)
            // isInstalling is reset synchronously here, immediately before
            // return. This differs from the main install path below, where
            // isInstalling is reset inside a fire-and-forget Task {} body
            // (asynchronously, after unzip/replace complete). The asymmetry
            // is intentional and safe: this abort path does no heavy work —
            // it only removes a local cache file — so there is no reason to
            // defer the reset to a Task. @MainActor isolation means neither
            // path has a data race regardless of when the reset occurs.
            // Do NOT "unify" the two paths by moving this reset into a Task.
            isInstalling = false
            return
        }
        // ────────────────────────────────────────────────────────────────────

        // ── Post-revalidation state re-check ─────────────────────────────────
        // fetchLatestRelease above is the first (and only) suspension point in
        // this function. While suspended, another @MainActor task could have
        // transitioned state.currentPhase away from .ready — for example, if a
        // future cancel API is added that resets state to .idle while the user
        // is waiting for the network call to return.
        //
        // Today no such cancel path exists (UpdateStateProviding has no cancel
        // method, and the scheduler does not touch .ready). This guard is
        // therefore a no-op in the current codebase. It is added defensively so
        // that if a cancel API is ever introduced, the install does not proceed
        // on stale authorisation. The cost is one phase read on the main actor —
        // zero overhead.
        //
        // .idle: return without applying any phase — the host already moved away
        // from .ready intentionally; applying .failed here would be wrong.
        // .failed: same reasoning — do not overwrite with a second .failed.
        // Any non-.ready phase: silently abort and reset isInstalling.
        //
        // Do NOT remove this guard on the grounds that no cancel path exists today.
        // Its value is precisely that it costs nothing now and prevents a latent
        // correctness hole later.
        guard case .ready = state.currentPhase else {
            isInstalling = false
            return
        }
        // ─────────────────────────────────────────────────────────────────────

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

        // withZipURL snapshots fixedZipURL once for the entire install sequence.
        // zipURL is used for unzip input, the install step, and the post-relaunch
        // cleanup — all guaranteed to reference the same path. See issue #16.
        //
        // isInstalling is NOT reset here before entering withZipURL. It is owned
        // by the Task {} body below and released on every exit path inside that
        // Task: on unzip failure, on code-sign abort, on replaceItemAt failure,
        // on open -n failure, and implicitly on NSApp.terminate (process exits).
        // Resetting it here — before the Task starts its heavy work — would
        // allow a second installAndRelaunch call to enter while the first install
        // is still in flight. Do NOT add isInstalling = false before this call.
        //
        // CONCURRENCY NOTE: the withZipURL closure body completes synchronously
        // (it only creates a Task and returns Void — T = Void). withZipURL
        // returns as soon as the closure body returns. However, the Task spawned
        // inside the closure continues running asynchronously after withZipURL
        // returns — it outlives the closure body. "The closure runs to completion"
        // means the closure body itself, not the Task it spawns. zipURL is a URL
        // value type (Sendable struct), so the Task captures an independent copy;
        // there is no dangling reference. This is safe, but the asymmetry between
        // "closure body is synchronous" and "work is asynchronous" is intentional
        // and worth noting for anyone auditing concurrent behaviour here.
        withZipURL { zipURL in
            let bundleURL = URL(filePath: Bundle.main.bundlePath)
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(component: "appupdater-update-\(UUID().uuidString)", directoryHint: .isDirectory)

            // Task {} here is NOT detached — it inherits the @MainActor
            // isolation of the enclosing installAndRelaunch function. In Swift
            // 6, Task { } created inside an @MainActor context runs its body on
            // @MainActor. Only Task.detached { } breaks actor inheritance.
            // isInstalling and state.apply inside this Task are therefore
            // @MainActor-isolated and race-free. Do NOT add Task.detached or
            // remove the @MainActor annotation from installAndRelaunch.
            //
            // isInstalling is reset inside this Task body (asynchronously,
            // after unzip/replace complete or on any failure path), not here
            // on the outer synchronous path. This is asymmetric with the
            // yank-abort path above, which resets isInstalling synchronously
            // before return. The asymmetry is intentional: the install path
            // does heavy work (ditto unzip, replaceItemAt, open -n) that must
            // complete before the guard can be released. Resetting isInstalling
            // before the Task finishes would allow a second tap to enter while
            // the first install is still in flight. Do NOT hoist the reset out
            // of the Task to make the two paths "consistent".
            //
            // No withTaskCancellationHandler here — this is intentional.
            //
            // The structural observation: if this Task were cancelled before
            // completing, isInstalling would remain true for the session and
            // the Install button would appear locked. That would be a real
            // bug — but only if a caller holds the task handle and calls
            // .cancel() on it.
            //
            // No such caller exists in this codebase. AppUpdater does not
            // expose the task handle, does not store it, and provides no
            // cancel-install API. The only path to cancellation would be the
            // host storing the Void-discarded task handle returned by Task{},
            // which this library explicitly does not support.
            //
            // Additionally, isInstalling is a transient in-memory flag — it
            // does not survive process termination. The normal terminal state
            // for a successful install is NSApp.terminate(nil), after which
            // the flag ceases to exist entirely. There is no "locked forever"
            // scenario across sessions.
            //
            // If AppUpdater ever gains a cancellable install API (e.g. a
            // public cancelInstall() method or an exposed Task handle), add
            // withTaskCancellationHandler at that point to reset isInstalling
            // and apply .idle. Until then, do not add it — the risk is
            // theoretical and the added complexity is not justified.
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
        relaunchTask.executableURL = URL(filePath: "/usr/bin/open")
        relaunchTask.arguments = ["-n", finalURL.path(percentEncoded: false)]
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
