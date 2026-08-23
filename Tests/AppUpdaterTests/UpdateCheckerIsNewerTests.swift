// UpdateCheckerIsNewerTests.swift
// AppUpdaterTests
import Testing
@testable import AppUpdater

// MARK: - UpdateCheckerIsNewerTests

/// Single comparison-contract test for `UpdateChecker.isNewer(_:than:)`.
///
/// All semver dimensions (major/minor/patch ordering, numeric vs lexicographic,
/// v-prefix stripping, stable-vs-prerelease precedence, beta ordering, partial
/// and malformed versions) are covered as data-driven cases in one loop.
@Suite("UpdateChecker.isNewer")
struct UpdateCheckerIsNewerTests {

    // MARK: - Comparison contract

    @Test
    func comparisonContract() {
        struct Case {
            let candidate: String
            let current: String
            let expected: Bool
            let label: String
        }

        let cases: [Case] = [
            Case(
                candidate: "2.0.0",
                current: "1.0.0",
                expected: true,
                label: "higher major"
            ),
            Case(
                candidate: "1.0.0",
                current: "2.0.0",
                expected: false,
                label: "lower major"
            ),
            Case(
                candidate: "1.1.0",
                current: "1.0.0",
                expected: true,
                label: "higher minor"
            ),
            Case(
                candidate: "1.0.0",
                current: "1.1.0",
                expected: false,
                label: "lower minor"
            ),
            Case(
                candidate: "1.10.0",
                current: "1.9.0",
                expected: true,
                label: "numeric minor comparison"
            ),
            Case(
                candidate: "1.0.1",
                current: "1.0.0",
                expected: true,
                label: "higher patch"
            ),
            Case(
                candidate: "1.0.0",
                current: "1.0.1",
                expected: false,
                label: "lower patch"
            ),
            Case(
                candidate: "1.0.0",
                current: "1.0.0",
                expected: false,
                label: "equal stable"
            ),
            Case(
                candidate: "v2.0.0",
                current: "1.0.0",
                expected: true,
                label: "candidate v prefix"
            ),
            Case(
                candidate: "2.0.0",
                current: "v1.0.0",
                expected: true,
                label: "current v prefix"
            ),
            Case(
                candidate: "1.0.0",
                current: "1.0.0-beta.1",
                expected: true,
                label: "stable beats same-base beta"
            ),
            Case(
                candidate: "1.0.0-beta.1",
                current: "1.0.0",
                expected: false,
                label: "beta does not beat stable"
            ),
            Case(
                candidate: "1.0.0-beta.2",
                current: "1.0.0-beta.1",
                expected: true,
                label: "higher beta"
            ),
            Case(
                candidate: "1.0.0-beta.1",
                current: "1.0.0-beta.2",
                expected: false,
                label: "lower beta"
            ),
            Case(
                candidate: "1.0.0-beta.10",
                current: "1.0.0-beta.9",
                expected: true,
                label: "numeric beta comparison"
            ),
            Case(
                candidate: "1.0.0-beta.2",
                current: "1.0.0-beta.2",
                expected: false,
                label: "equal beta"
            ),
            Case(
                candidate: "2.0.0-beta.1",
                current: "1.9.9",
                expected: true,
                label: "higher-base beta beats lower stable"
            ),
            Case(
                candidate: "2.0",
                current: "1.9",
                expected: true,
                label: "partial versions"
            ),
            Case(
                candidate: "",
                current: "",
                expected: false,
                label: "empty versions"
            ),
            Case(
                candidate: "v",
                current: "v",
                expected: false,
                label: "prefix without version"
            )
        ]

        for testCase in cases {
            #expect(
                UpdateChecker.isNewer(
                    testCase.candidate,
                    than: testCase.current
                ) == testCase.expected,
                """
                \(testCase.label):
                candidate=\(testCase.candidate)
                current=\(testCase.current)
                """
            )
        }
    }
}
