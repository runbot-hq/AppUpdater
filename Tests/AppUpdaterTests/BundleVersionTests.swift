// BundleVersionTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - BundleVersionTests

/// Covers the two pieces of the pre-swap verification gate (issue #69, A1) that
/// can be exercised without AppKit: the tag→bundle-version conversion, and the
/// `Info.plist` read it is compared against.
///
/// The orchestration in `replaceAndRelaunch` cannot be tested here — it calls
/// `replaceItemAt` on `Bundle.main`, which in a test process is the test runner.
/// Pinning both inputs to the guard is what is achievable, and is what makes a
/// silent divergence between the two sides of the comparison detectable.
@Suite("Pre-swap bundle version verification")
struct BundleVersionTests {

    // MARK: - Tag → CFBundleShortVersionString

    @Test func bundleVersionForTagContract() {
        let cases: [(tag: String, expected: String)] = [
            ("v1.2.3", "1.2.3"),
            ("1.2.3", "1.2.3"),
            ("v1.2.3-beta.4", "1.2.3-beta.4"),
            ("1.2.3-beta.4", "1.2.3-beta.4"),
            ("", ""),
            ("v", ""),
            // Only ONE leading "v" is stripped — a malformed tag must fail the
            // downstream comparison rather than be coerced into passing.
            ("vv1.2.3", "v1.2.3"),
            // "v" is only special in the leading position.
            ("version1.2.3", "ersion1.2.3")
        ]

        for testCase in cases {
            #expect(
                UpdateChecker.bundleVersion(forTag: testCase.tag) == testCase.expected,
                "tag \(testCase.tag)"
            )
        }
    }

    // MARK: - Reading CFBundleShortVersionString from a bundle

    /// Builds a minimal `.app` directory with an `Info.plist`.
    private func makeFakeBundle(version: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "BundleVersionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appURL = root.appending(component: "Fake.app", directoryHint: .isDirectory)
        let contents = appURL.appending(component: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = ["CFBundleName": "Fake"]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: contents.appending(component: "Info.plist"))
        return appURL
    }

    @MainActor
    private func makeUpdater() -> AppUpdater {
        AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            publicKey: dummyPublicKey,
            schedulerIdentifier: "BundleVersionTests.\(UUID().uuidString)",
            betaChannelProvider: { false }
        )
    }

    @Test @MainActor func readsShortVersionString() async throws {
        let updater = makeUpdater()
        let appURL = try makeFakeBundle(version: "1.2.3")
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        #expect(await updater.readBundleVersion(at: appURL) == "1.2.3")
    }

    /// A pre-release bundle version must round-trip verbatim — this is the pair
    /// that `bundleVersion(forTag: "v1.2.3-beta.4")` has to match.
    @Test @MainActor func readsPrereleaseShortVersionString() async throws {
        let updater = makeUpdater()
        let appURL = try makeFakeBundle(version: "1.2.3-beta.4")
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        let read = await updater.readBundleVersion(at: appURL)
        #expect(read == "1.2.3-beta.4")
        #expect(read == UpdateChecker.bundleVersion(forTag: "v1.2.3-beta.4"))
    }

    /// A missing key yields nil, which the guard treats as a mismatch — the
    /// swap is refused rather than allowed through.
    @Test @MainActor func missingKeyYieldsNil() async throws {
        let updater = makeUpdater()
        let appURL = try makeFakeBundle(version: nil)
        defer { try? FileManager.default.removeItem(at: appURL.deletingLastPathComponent()) }

        #expect(await updater.readBundleVersion(at: appURL) == nil)
        #expect(await updater.readBundleVersion(at: appURL) != UpdateChecker.bundleVersion(forTag: "v1.2.3"))
    }

    /// An absent bundle yields nil rather than throwing.
    @Test @MainActor func absentBundleYieldsNil() async throws {
        let updater = makeUpdater()
        let missing = FileManager.default.temporaryDirectory
            .appending(component: "does-not-exist-\(UUID().uuidString).app", directoryHint: .isDirectory)

        #expect(await updater.readBundleVersion(at: missing) == nil)
    }
}
