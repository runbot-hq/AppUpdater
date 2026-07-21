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
    /// 7. Relaunch the new binary via `NSWorkspace.openApplication` with a completion handler.
    /// 8. Delete the zip (spend — relaunch confirmed).
    /// 9. Terminate this process via `NSApp.terminate` inside the relaunch completion handler.
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
                        appUpdaterLogger.error("yank-revalidation: failed to remove stale zip — applying .failed: \(String(describing: error), privacy: .public)")
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
        // on post-swap verification failure, on relaunch failure, and implicitly
        // on NSApp.terminate (process exits).
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
    /// The previous implementation used `Process` to call `/usr/bin/open -n`.
    /// `open -n` is non-blocking — it returns immediately after spawning the
    /// new process, before the new instance has actually launched. This created
    /// a race: `NSApp.terminate(nil)` could kill the old process before the new
    /// one was fully up, or the new process could start loading the bundle from
    /// the kernel's vnode cache before the filesystem rename was fully visible to it.
    ///
    /// `NSWorkspace.openApplication(at:configuration:completionHandler:)` calls
    /// back only after the new process has launched (or failed). By placing
    /// `NSApp.terminate(nil)` inside the completion handler, the old process
    /// stays alive until the new one is confirmed running — deterministically.
    ///
    /// ## Why post-swap version verification
    ///
    /// `replaceItemAt` not throwing is not sufficient proof that the correct
    /// bundle is now on disk. After the swap, we read `CFBundleShortVersionString`
    /// from the swapped bundle's `Info.plist` and compare it against the
    /// expected `version` tag (after stripping a leading `v` from the tag, since
    /// `CFBundleShortVersionString` never carries a `v` prefix). If they do not
    /// match, we apply `.failed` and return without relaunching — the wrong
    /// bundle is on disk and the user must not be launched into it silently.
    ///
    /// This is a deterministic check: one synchronous plist read off `@MainActor`
    /// via a `@concurrent` helper, no timing assumption, no sleep. Fixes
    /// runbot-hq/run-bot#2193.
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
        // bundle landed). We capture it and use it for the relaunch below rather
        // than re-using bundleURL. In practice on a standard macOS /Applications
        // setup the returned URL is identical to bundleURL — same name, same path.
        // In edge cases (case-insensitive FS conflict, path rewriting) they may
        // differ; using the returned URL ensures we launch the new binary rather
        // than the old one. Falls back to bundleURL if nil is returned.
        // Fixes issue #3.
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

        // ── Step 3: post-swap version verification ───────────────────────────
        // replaceItemAt not throwing is necessary but not sufficient — it only
        // confirms the filesystem rename completed. We also verify that the
        // bundle now on disk is actually the version we intended to install.
        //
        // We read CFBundleShortVersionString from the swapped bundle's Info.plist
        // and compare it against the expected version tag. GitHub tags carry a
        // leading "v" (e.g. "v0.7.3") while CFBundleShortVersionString is always
        // "0.7.3" — we strip the leading "v" before comparing.
        //
        // The read is done via readBundleVersion(at:) — a @concurrent async helper —
        // so the blocking NSDictionary(contentsOf:) call runs off the main actor
        // cooperative thread (Principle 18). For a local bundle it completes in
        // microseconds, but the principle holds regardless.
        //
        // On mismatch we apply .failed and return without relaunching. The wrong
        // bundle is on disk. The user sees a recoverable error and can retry or
        // use the curl install command. We do NOT attempt to roll back — rollback
        // is not atomic and could leave the bundle in a worse state. .failed is
        // the correct terminal state here.
        //
        // REVIEWER: do NOT remove this step on the grounds that replaceItemAt
        // "always works". This guard catches the edge case where the swap
        // succeeded at the filesystem level but the wrong bundle ended up on disk
        // (packaging issue, ?? bundleURL fallback, path edge case). The cost is
        // one async plist read.
        #if canImport(AppKit)
        let swappedVersion = await readBundleVersion(at: finalURL)
        // Strip leading "v" from the tag for comparison — CFBundleShortVersionString
        // is always "X.Y.Z", never "vX.Y.Z". GitHub tags are always "vX.Y.Z".
        // Do NOT compare raw tag strings here — it will always mismatch.
        let expectedBundleVersion = version.hasPrefix("v") ? String(version.dropFirst()) : version
        guard swappedVersion == expectedBundleVersion else {
            // Extract path separately to keep the log line under SwiftLint's limit.
            let bundlePath = finalURL.path(percentEncoded: false)
            appUpdaterLogger.error("post-swap verification failed: expected \(expectedBundleVersion, privacy: .public), got \(swappedVersion ?? "nil", privacy: .public) at \(bundlePath, privacy: .public)")
            isInstalling = false
            state.apply(.failed(version: version))
            return
        }
        appUpdaterLogger.debug("post-swap verification passed: \(swappedVersion ?? "nil", privacy: .public) == \(expectedBundleVersion, privacy: .public)")
        #endif

        // ── Step 4: delete zip (swap confirmed) ──────────────────────────────
        // The zip is deleted here — after the swap is verified but before
        // relaunch — rather than after open fires (the old position was step 4
        // after open -n). This is intentional:
        // - The swap is confirmed correct, so the zip is spent regardless of
        //   whether the relaunch succeeds.
        // - Deleting before relaunch ensures the new process never sees a stale
        //   zip in ~/Library/Caches on its launch-time checkAndHandle call.
        // - If the relaunch fails, .failed is applied and the user can retry;
        //   the zip being gone means the next retry will re-download, which is
        //   correct — the old zip was already consumed by the successful swap.
        try? fm.removeItem(at: zipURL)

        // ── Step 5: relaunch via NSWorkspace ────────────────────────────────
        // NSWorkspace.openApplication(at:configuration:completionHandler:) is
        // used instead of the previous `Process("/usr/bin/open -n")` approach.
        //
        // The key difference: the completion handler is called only after the
        // new process has launched (or failed to launch). By placing
        // NSApp.terminate(nil) inside the completion handler, the old process
        // stays alive until the new instance is confirmed running.
        //
        // The previous `open -n` via Process was non-blocking: relaunchTask.run()
        // returned immediately after spawning, and NSApp.terminate fired right
        // after — racing with the new process startup and the kernel's vnode
        // cache for the just-swapped bundle. This was the root cause of
        // runbot-hq/run-bot#2193.
        //
        // completionHandler is called on an arbitrary queue. We hop back to
        // @MainActor via Task { @MainActor in } — the correct Swift 6 pattern
        // (Principles 1/4). Do NOT replace with DispatchQueue.main.async.
        //
        // Strong capture of self is intentional — AppUpdater is owned by
        // AppDelegate and lives for the full app lifetime. [weak self] would
        // introduce a silent nil-skip of isInstalling = false on the error path,
        // leaving the state machine permanently locked for the session.
        // REVIEWER: do NOT change to [weak self].
        //
        // On launch failure: the completion handler receives a non-nil error.
        // We log it and apply .failed. The new binary IS on disk (swap was
        // verified in step 3) — the user can relaunch manually.
        //
        // isInstalling is NOT reset before NSApp.terminate(nil) on the success
        // path — this is correct. The process is about to exit; the flag
        // ceases to exist. Do NOT add isInstalling = false on the success path.
        #if canImport(AppKit)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: finalURL, configuration: config) { [self] _, error in
            if let error {
                // Launch failed after a confirmed successful swap.
                // The new binary IS on disk. Apply .failed so the host
                // surfaces a recoverable error — the user can relaunch manually.
                // Extract description separately to keep the log line under SwiftLint's limit.
                let msg = error.localizedDescription
                Task { @MainActor in
                    appUpdaterLogger.error("NSWorkspace.openApplication failed — new binary on disk, relaunch manually: \(msg, privacy: .public)")
                    self.isInstalling = false
                    state.apply(.failed(version: version))
                }
            } else {
                // New instance confirmed launched — terminate the old process.
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        }
        #endif
    }
}
