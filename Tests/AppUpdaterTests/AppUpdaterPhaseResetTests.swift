// AppUpdaterPhaseResetTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterPhaseResetTests

/// Pins the `.upToDate` phase-reset policy of `checkAndHandle` (issue #69, A2).
///
/// A successful check that finds nothing newer must clear a stuck `.failed`
/// phase — and must leave every other phase alone, because `checkAndHandle` is
/// re-entrant and a concurrent call must not wipe a cached zip or an in-flight
/// download.
@MainActor
@Suite("AppUpdater.checkAndHandle phase reset")
struct AppUpdaterPhaseResetTests {

    /// Builds an updater whose provider always reports "no channel match",
    /// which `UpdateChecker.evaluate` maps to `.upToDate`.
    private func makeUpToDateStack() -> (AppUpdater, MockUpdateState) {
        let updater = AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            publicKey: dummyPublicKey,
            schedulerIdentifier: "PhaseReset.\(UUID().uuidString)",
            betaChannelProvider: { false },
            releaseProvider: MockReleaseProvider(fetchResultToReturn: .fetched(nil))
        )
        return (updater, MockUpdateState())
    }

    // MARK: - .failed is cleared

    /// The README wires its Retry button to `checkAndHandle`. A retry that
    /// succeeds and finds nothing newer must return the host to `.idle`,
    /// otherwise the failure affordance is displayed forever.
    @Test func upToDate_clearsStuckFailedPhase() async throws {
        let (updater, state) = makeUpToDateStack()
        state.apply(.failed(version: "v2.0.0"))

        await updater.checkAndHandle(state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.last == .idle)
    }

    /// `.failed(version: nil)` is the shape `installAndRelaunch` applies when it
    /// cannot determine a version; it must clear too.
    @Test func upToDate_clearsFailedWithNilVersion() async throws {
        let (updater, state) = makeUpToDateStack()
        state.apply(.failed(version: nil))

        await updater.checkAndHandle(state: state)

        #expect(state.currentPhase == .idle)
    }

    // MARK: - Every other phase survives

    /// A verified, cached, installable zip is not invalidated by a later check
    /// that finds nothing newer. Widening the guard to an unconditional
    /// `.idle` would silently drop a ready update — this test pins that.
    @Test func upToDate_preservesNonFailedPhases() async throws {
        let preserved: [UpdatePhase] = [
            .ready(version: "v2.0.0"),
            .available(version: "v2.0.0"),
            .downloading(version: "v2.0.0")
        ]

        for phase in preserved {
            let (updater, state) = makeUpToDateStack()
            state.apply(phase)
            let appliedBefore = state.appliedPhases.count

            await updater.checkAndHandle(state: state)

            #expect(state.currentPhase == phase, "\(phase) must survive an .upToDate check")
            #expect(
                state.appliedPhases.count == appliedBefore,
                "\(phase) must not trigger any apply() call"
            )
        }
    }

    /// An already-`.idle` host must not be churned with a redundant transition.
    @Test func upToDate_idleStaysIdleWithoutReapplying() async throws {
        let (updater, state) = makeUpToDateStack()

        await updater.checkAndHandle(state: state)

        #expect(state.currentPhase == .idle)
        #expect(state.appliedPhases.isEmpty)
    }
}
