// MockReleaseProvider.swift
// AppUpdaterTests
@testable import AppUpdater

// MARK: - MockReleaseProvider

/// A configurable test double for `ReleaseProvider`.
///
/// `actor` isolation ensures mutation of call-capture properties is safe
/// when tests `await` recorded values — no `@unchecked Sendable` required
/// (Pillar 6). Zero `DispatchQueue` usage (Pillar 5).
///
/// ## Usage
///
/// ```swift
/// let provider = MockReleaseProvider()
/// await provider.set(releaseToReturn: AvailableRelease(tagName: "v2.0.0", assets: [], checksumURL: nil))
/// // or simulate a fetch failure:
/// await provider.set(fetchResultToReturn: .failed)
/// ```
actor MockReleaseProvider: ReleaseProvider {

    // MARK: - Configuration

    /// The `ReleaseFetchResult` to return from `fetchLatestRelease`.
    /// Defaults to `.fetched(nil)` (simulates a successful fetch with no
    /// channel match — the safest default for tests that don't configure a
    /// release).
    var fetchResultToReturn: ReleaseFetchResult = .fetched(nil)

    /// Convenience accessor: unwraps the associated value of `.fetched(_)`.
    ///
    /// **Getter**: returns the `AvailableRelease?` associated with
    /// `.fetched(_)`. Crashes via `preconditionFailure` when
    /// `fetchResultToReturn` is `.failed` — reading this property back to
    /// assert a failure condition is a test bug; use `fetchResultToReturn`
    /// directly instead.
    ///
    /// **Setter**: wraps `newValue` in `.fetched(newValue)` and assigns to
    /// `fetchResultToReturn`. Pass `nil` to simulate no channel match
    /// (`.fetched(nil)`).
    var releaseToReturn: AvailableRelease? {
        get {
            switch fetchResultToReturn {
            case .fetched(let r):
                return r
            case .failed:
                preconditionFailure(
                    "releaseToReturn getter called when fetchResultToReturn is .failed. "
                    + "This is a test bug: use fetchResultToReturn directly to assert "
                    + "failure state instead of reading releaseToReturn."
                )
            }
        }
        set { fetchResultToReturn = .fetched(newValue) }
    }

    /// Convenience: number of simulated async yield points per fetch call.
    var simulatedSteps: Int = 1

    // MARK: - Call capture

    /// Number of times `fetchLatestRelease` was called.
    private(set) var fetchCallCount: Int = 0

    /// Alias kept for backward compatibility with existing tests.
    var callCount: Int { fetchCallCount }

    /// The `betaChannel` value last passed to `fetchLatestRelease`.
    private(set) var capturedBetaChannel: Bool?

    /// The `repo` value last passed to `fetchLatestRelease`.
    private(set) var capturedRepo: String?

    // MARK: - Init

    /// Creates a mock with an optional pre-configured release.
    /// Pass a `ReleaseFetchResult` to control the exact return value,
    /// or pass an `AvailableRelease?` via the convenience init.
    init(releaseToReturn: AvailableRelease? = nil) {
        self.fetchResultToReturn = .fetched(releaseToReturn)
    }

    init(fetchResultToReturn: ReleaseFetchResult) {
        self.fetchResultToReturn = fetchResultToReturn
    }

    /// Mutates `fetchResultToReturn` from a test body.
    func set(fetchResultToReturn: ReleaseFetchResult) {
        self.fetchResultToReturn = fetchResultToReturn
    }

    /// Convenience: wraps `release` in `.fetched` and assigns.
    func set(releaseToReturn: AvailableRelease?) {
        self.fetchResultToReturn = .fetched(releaseToReturn)
    }

    // MARK: - ReleaseProvider

    func fetchLatestRelease(
        repo: String,
        betaChannel: Bool,
        assetName: @Sendable (String) -> String
    ) async -> ReleaseFetchResult {
        fetchCallCount += 1
        capturedRepo = repo
        capturedBetaChannel = betaChannel
        for _ in 0..<simulatedSteps { await Task.yield() }
        return fetchResultToReturn
    }
}
