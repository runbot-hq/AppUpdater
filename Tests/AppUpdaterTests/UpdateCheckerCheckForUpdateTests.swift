// UpdateCheckerCheckForUpdateTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - UpdateCheckerCheckForUpdateTests

/// Outcome and error-priority state machine for `UpdateChecker.evaluate`.
///
/// Raw GitHub release decoding is covered by `GitHubReleaseProviderDecodeTests`,
/// channel selection by `GitHubReleaseProviderSelectionTests`, and semver
/// ordering by `UpdateCheckerIsNewerTests` — this file pins only the evaluator's
/// own contract: mapping a `ReleaseFetchResult` plus installed version to an
/// `UpdateCheckResult`.
@Suite("UpdateChecker.evaluate")
struct UpdateCheckerCheckForUpdateTests {

    // MARK: - Expected outcome

    /// `UpdateCheckResult` is not `Equatable`; this mirrors it for assertions.
    private enum ExpectedOutcome {
        case upToDate
        case updateAvailable(String)
        case missingVersion
    }

    // MARK: - Helpers

    /// Builds a minimal `AvailableRelease` with a custom tag and no assets.
    private func release(tagName: String) -> AvailableRelease {
        AvailableRelease(tagName: tagName, assets: [], signatureURL: nil)
    }

    /// Switch-based structural comparison of `ReleaseFetchError` cases.
    /// Never compares localized error strings — only the case shape (and,
    /// where meaningful, the associated value).
    private func assertSameFetchError(
        _ actual: ReleaseFetchError,
        _ expected: ReleaseFetchError,
        label: String
    ) {
        switch (actual, expected) {
        case (.networkError(let a), .networkError(let e)):
            #expect(
                (a as? URLError)?.code == (e as? URLError)?.code,
                "\(label): network error code mismatch"
            )
        case (.httpError(let a), .httpError(let e)):
            #expect(a == e, "\(label): HTTP status mismatch")
        case (.decodingError, .decodingError):
            break
        default:
            Issue.record("\(label): expected \(expected), got \(actual)")
        }
    }

    // MARK: - Evaluation contract

    @Test
    func evaluationContract() {
        struct Case {
            let label: String
            let fetchResult: ReleaseFetchResult
            let currentVersion: String
            let betaChannel: Bool
            let expected: ExpectedOutcome
        }

        let cases: [Case] = [
            Case(
                label: "no release",
                fetchResult: .fetched(nil),
                currentVersion: "1.0.0",
                betaChannel: false,
                expected: .upToDate
            ),
            Case(
                label: "newer release",
                fetchResult: .fetched(release(tagName: "v2.0.0")),
                currentVersion: "1.0.0",
                betaChannel: false,
                expected: .updateAvailable("v2.0.0")
            ),
            Case(
                label: "equal release",
                fetchResult: .fetched(release(tagName: "v1.0.0")),
                currentVersion: "1.0.0",
                betaChannel: false,
                expected: .upToDate
            ),
            Case(
                label: "older release",
                fetchResult: .fetched(release(tagName: "v0.9.0")),
                currentVersion: "1.0.0",
                betaChannel: false,
                expected: .upToDate
            ),
            Case(
                label: "missing current version",
                fetchResult: .fetched(release(tagName: "v2.0.0")),
                currentVersion: "",
                betaChannel: false,
                expected: .missingVersion
            ),
            Case(
                label: "malformed release tag",
                fetchResult: .fetched(release(tagName: "not-a-version")),
                currentVersion: "1.0.0",
                betaChannel: false,
                expected: .upToDate
            ),
            Case(
                label: "malformed current treated as older",
                fetchResult: .fetched(release(tagName: "v2.0.0")),
                currentVersion: "not-a-version",
                betaChannel: false,
                expected: .updateAvailable("v2.0.0")
            )
        ]

        for testCase in cases {
            let result = UpdateChecker.evaluate(
                fetchResult: testCase.fetchResult,
                currentVersion: testCase.currentVersion,
                betaChannel: testCase.betaChannel
            )

            switch (result, testCase.expected) {
            case (.upToDate, .upToDate):
                break

            case (.updateAvailable(let fetched), .updateAvailable(let expectedTag)):
                #expect(fetched.tagName == expectedTag, Comment(rawValue: testCase.label))

            case (.failed(let error), .missingVersion):
                guard let checkError = error as? UpdateCheckError,
                      case .missingVersionKey = checkError
                else {
                    Issue.record("\(testCase.label): wrong error \(error)")
                    continue
                }

            default:
                Issue.record(
                    """
                    \(testCase.label):
                    expected \(testCase.expected),
                    got \(result)
                    """
                )
            }
        }
    }

    // MARK: - Failure contract

    /// Verifies that a `.failed` fetch result propagates as
    /// `.failed(.fetchFailed(<same reason>))` regardless of `currentVersion`.
    ///
    /// ## ⚠️ currentVersion: "" is intentional for the last case — ordering
    ///
    /// One might expect `currentVersion: ""` to produce
    /// `.failed(.missingVersionKey)` instead. It does not, because
    /// `UpdateChecker.evaluate` checks `.failed` fetch results *before* the
    /// empty-version guard: a failed fetch is always a fetch failure regardless
    /// of what `currentVersion` contains.
    @Test
    func fetchFailureContract() {
        struct Case {
            let label: String
            let error: ReleaseFetchError
            let currentVersion: String
        }

        let cases: [Case] = [
            Case(
                label: "network",
                error: .networkError(underlying: URLError(.notConnectedToInternet)),
                currentVersion: "1.0.0"
            ),
            Case(
                label: "HTTP",
                error: .httpError(statusCode: 500),
                currentVersion: "1.0.0"
            ),
            Case(
                label: "decoding",
                error: .decodingError(
                    underlying: DecodingError.dataCorrupted(
                        .init(codingPath: [], debugDescription: "fixture decode failure")
                    )
                ),
                currentVersion: "1.0.0"
            ),
            Case(
                label: "fetch failure precedes missing version",
                error: .networkError(underlying: URLError(.badURL)),
                currentVersion: ""
            )
        ]

        for testCase in cases {
            let result = UpdateChecker.evaluate(
                fetchResult: .failed(testCase.error),
                currentVersion: testCase.currentVersion,
                betaChannel: false
            )

            guard case .failed(let error) = result,
                  let checkError = error as? UpdateCheckError,
                  case .fetchFailed(let propagated) = checkError
            else {
                Issue.record("\(testCase.label): expected fetch failure, got \(result)")
                continue
            }

            assertSameFetchError(propagated, testCase.error, label: testCase.label)
        }
    }
}
