// AppUpdater.swift
// AppUpdater
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppUpdater

/// Drives the in-app auto-update flow: GitHub Releases poll → semver compare →
/// zip download → Ed25519 signature verification → host-state mutation → install &
/// relaunch on user confirmation.
///
/// `AppUpdater` is a configurable `@MainActor` class carrying no host-specific
/// state of its own beyond what the caller injects. All UI-facing state lives
/// in a caller-supplied `any UpdateStateProviding`; the single cached zip lives
/// at a fixed path derived from `schedulerIdentifier`.
///
/// ## Isolation model
///
/// The class is `@MainActor`, so `isInstalling` and the scheduler reference are
/// race-free without extra locking. The blocking work runs off the main thread
/// regardless: `URLSession` downloads suspend rather than block, checksum
/// verification runs in the `@concurrent` `verifySignature` free function, and
/// subprocess launches run in the `@concurrent` `runCommand` helper.
///
/// ## Typical usage
///
/// ```swift
/// let updater = AppUpdater(
///     repo: "your-org/your-repo",
///     currentVersion: "1.2.3",
///     assetName: { _ in "YourApp.zip" },
///     publicKey: Data(base64Encoded: "<your-32-byte-ed25519-public-key-base64>")!,
///     schedulerIdentifier: "com.your-org.update-check",
///     betaChannelProvider: { UserDefaults.standard.bool(forKey: "betaChannel") }
/// )
/// await updater.checkAndHandle(state: myState)
/// updater.scheduleBackgroundCheck(state: myState)
/// ```
@MainActor
public final class AppUpdater {

    // MARK: - Public configuration

    /// `"owner/name"` GitHub repository slug polled for releases.
    public let repo: String

    /// The running app's version (full semver incl. any pre-release suffix).
    public let currentVersion: String

    /// Reverse-DNS identifier for the background scheduler; also used to scope
    /// this updater's cache directory under `~/Library/Caches`.
    ///
    /// Must not be empty and must not contain `/` — both are enforced by
    /// `precondition` at init time.
    public let schedulerIdentifier: String

    /// How often `NSBackgroundActivityScheduler` fires a background update check.
    ///
    /// Injected at init time. Defaults to 24 hours in release builds and
    /// 60 seconds in DEBUG builds. Pass a custom value in tests to control
    /// scheduler cadence without shared mutable static state.
    public let checkInterval: TimeInterval

    // MARK: - Internal configuration

    /// Maps a release tag name to the expected zip asset filename.
    let assetName: @Sendable (String) -> String

    /// Reads the host's current beta-channel preference.
    let betaChannelProvider: @MainActor () -> Bool

    /// The release-fetch abstraction. Defaults to `GitHubReleaseProvider()`.
    let provider: any ReleaseProvider

    // MARK: - Fixed zip URL

    /// The single fixed on-disk destination for the cached update zip.
    ///
    /// All update cycles write to this same path — no version-stamped filenames,
    /// no accumulation of old zips. The file is at:
    /// `~/Library/Caches/<schedulerIdentifier>/update.zip`
    ///
    /// Because the path is fixed, `purgeStaleZips` is no longer needed and
    /// `UserDefaults` is no longer used for zip-path persistence. The zip either
    /// exists at this path (install affordance available) or it doesn't (check
    /// + download needed).
    ///
    /// ## Why this is a computed property, not a `lazy let`
    ///
    /// `fixedZipURL` re-evaluates `FileManager` on every access. This is
    /// intentional: if `cachesDirectory` is transiently unavailable, subsequent
    /// accesses retry caches rather than permanently baking in the `/tmp`
    /// fallback (which a `lazy let` computed at `init` time would do).
    ///
    /// A `lazy var` would compute the path once at `init` time — but `init` runs
    /// synchronously on `@MainActor` and `FileManager.url(for:create:true)` can
    /// block. More critically, a `cachesDirectory` failure at init time would bake
    /// the `/tmp` fallback permanently for the session with no retry possible.
    /// The computed property retries on every access, so a transient failure
    /// self-heals on the next scheduler cycle.
    ///
    /// ## ✅ Use `withZipURL(_:)` at call sites — do not call this directly
    ///
    /// Any call site that needs this URL must use `withZipURL { url in ... }`
    /// rather than accessing `fixedZipURL` directly. The scoped accessor
    /// structurally enforces the single-snapshot rule: the URL is evaluated
    /// exactly once and provided to the closure, preventing any divergence
    /// between an existence check and a subsequent write targeting different
    /// base directories if `cachesDirectory` availability changes mid-operation.
    var fixedZipURL: URL {
        // Re-evaluated on every access by design — see doc comment above.
        let caches: URL
        if let url = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            caches = url
        } else {
            // ⚠️ cachesDirectory unavailable — zip lands in /tmp and may be evicted
            // by the OS before the user taps Install & Relaunch, producing a
            // confusing .failed state with no visible cause. If you see unexpected
            // .failed states in production, check whether ~/Library/Caches is
            // accessible on the affected machine.
            appUpdaterLogger.warning("cachesDirectory unavailable — falling back to temporaryDirectory; zip is evictable and may disappear before install")
            caches = FileManager.default.temporaryDirectory
        }
        return caches
            .appendingPathComponent(schedulerIdentifier, isDirectory: true)
            .appendingPathComponent("update.zip")
    }

    /// Evaluates `fixedZipURL` exactly once and passes the result to `body`.
    ///
    /// Use this at every call site that needs the zip URL — never call
    /// `fixedZipURL` directly. The closure scope makes it structurally
    /// impossible to evaluate the property twice in one logical operation,
    /// which eliminates the class of bug where a `cachesDirectory` flip
    /// between two accesses sends an existence check and a write to different
    /// base directories.
    ///
    /// - Parameter body: A closure that receives the snapshotted `URL`.
    /// - Returns: Whatever `body` returns.
    @discardableResult
    func withZipURL<T>(_ body: (URL) -> T) -> T {
        body(fixedZipURL)
    }

    // MARK: - Trust model

    /// Raw 32-byte Ed25519 public key used to verify the `.sig` sidecar
    /// downloaded alongside each release zip.
    ///
    /// Must match the private key used to produce the `.sig` files in GitHub
    /// Releases. Injected at init time so the library carries no hard-coded key.
    ///
    /// Stored as `Data` rather than `Curve25519.Signing.PublicKey` intentionally:
    /// this keeps the public API free of CryptoKit types and avoids a throwing
    /// or failable `init`. The `precondition(publicKey.count == 32)` at init
    /// catches misconfiguration immediately; parsing happens once per download
    /// (24 h cadence) — the re-parse cost is negligible.
    let publicKey: Data

    /// When `false`, `installAndRelaunch` verifies that the running bundle and
    /// the downloaded bundle share the same `codesign` `Authority=` identity.
    ///
    /// Default `true` — RunBot's unsigned distribution model skips code-sign
    /// validation; integrity is guaranteed by Ed25519 signature verification.
    public var skipCodeSignValidation: Bool = true

    // MARK: - Runtime flags

    /// `true` while `installAndRelaunch` is mid-flight — guards a double-tap.
    ///
    /// This is the only runtime boolean flag on `AppUpdater` and it will remain
    /// the only one. It is not update state (it is not expressed through
    /// `UpdatePhase`) because it guards execution flow inside the library, not
    /// anything the host needs to observe. Do not add `isChecking`,
    /// `isDownloading`, `isCancelling`, or any other flag. If a proposed feature
    /// requires a new flag, the correct response under Principle 1 is to ask
    /// whether the flag represents a phase transition — if yes, add it to
    /// `UpdatePhase`; if no, the feature is out of scope (Principle 4).
    var isInstalling: Bool = false

    // MARK: - Background scheduler storage

    #if canImport(AppKit)
    /// Retains the `NSBackgroundActivityScheduler` for the app's lifetime.
    ///
    /// Declared `nonisolated(unsafe)` so `deinit` (a nonisolated context) can
    /// call `invalidate()`. All non-deinit accesses are `@MainActor`-isolated.
    nonisolated(unsafe) var activity: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Init / deinit

    /// Creates a configured updater.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug.
    ///   - currentVersion: The running app's version string.
    ///   - assetName: Maps a tag name to the expected zip asset filename.
    ///   - publicKey: Raw 32-byte Ed25519 public key used to verify `.sig`
    ///     sidecar files. Must match the private key used when signing releases.
    ///   - schedulerIdentifier: Reverse-DNS scheduler id / cache directory name.
    ///     Must not be empty and must not contain `"/"`.
    ///   - betaChannelProvider: Returns the host's beta-channel preference.
    ///   - checkInterval: How often the background scheduler fires. Defaults to
    ///     24 hours in release builds and 60 seconds in DEBUG builds. Pass a
    ///     custom value in tests to control scheduler cadence per-instance
    ///     without shared mutable static state.
    ///   - releaseProvider: The `ReleaseProvider` to use. Defaults to `GitHubReleaseProvider()`.
    public init<P: ReleaseProvider>(
        repo: String,
        currentVersion: String,
        assetName: @escaping @Sendable (String) -> String,
        publicKey: Data,
        schedulerIdentifier: String,
        betaChannelProvider: @escaping @MainActor () -> Bool = { false },
        checkInterval: TimeInterval = {
            #if DEBUG
            return 60
            #else
            return 24 * 60 * 60
            #endif
        }(),
        releaseProvider: P = GitHubReleaseProvider()
    ) {
        precondition(!repo.isEmpty, "AppUpdater: repo must not be empty")
        precondition(!schedulerIdentifier.isEmpty, "AppUpdater: schedulerIdentifier must not be empty")
        precondition(
            !schedulerIdentifier.contains("/"),
            "AppUpdater: schedulerIdentifier must not contain '/' — used as a cache directory name component"
        )
        precondition(publicKey.count == 32, "AppUpdater: publicKey must be exactly 32 bytes (raw Ed25519 public key)")
        self.repo = repo
        self.currentVersion = currentVersion
        self.assetName = assetName
        self.publicKey = publicKey
        self.schedulerIdentifier = schedulerIdentifier
        self.betaChannelProvider = betaChannelProvider
        self.checkInterval = checkInterval
        self.provider = releaseProvider
    }

    deinit {
        #if canImport(AppKit)
        activity?.invalidate()
        #endif
    }
}
