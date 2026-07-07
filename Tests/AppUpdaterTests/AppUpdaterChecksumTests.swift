// AppUpdaterChecksumTests.swift
// AppUpdaterTests
import CryptoKit
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterChecksumTests

/// Tests for `verifyChecksum` (a free function) and
/// `AppUpdater.fixedZipURL`.
///
/// Both verifyChecksum and fixedZipURL require no network.
@MainActor
struct AppUpdaterChecksumTests {

    // MARK: - Helpers

    private func makeUpdater() -> AppUpdater {
        let domain = "AppUpdaterChecksumTests.\(UUID().uuidString)"
        return AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: domain
        )
    }

    /// Writes `contents` to a temp file and returns the URL. Caller owns cleanup.
    private func writeTempFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("checksum-\(UUID().uuidString).zip")
        try contents.write(to: url)
        return url
    }

    /// Computes the lowercase SHA-256 hex digest of `data`.
    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of zero bytes — a well-known constant used in the zero-byte tests.
    private let emptyDataSHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: - verifyChecksum — matching digest

    @Test func verifyChecksum_matchingDigest_doesNotThrow() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let expectedHex = sha256Hex(payload)
        try await verifyChecksum(zipURL: url, expectedHex: expectedHex)
    }

    // MARK: - verifyChecksum — mismatched digest

    @Test func verifyChecksum_mismatchedDigest_throwsCannotDecodeContentData() async throws {
        let payload = Data("original content".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }
        let wrongHex = sha256Hex(Data("different content".utf8))
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: wrongHex)
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    /// An empty `expectedHex` string can never match any real SHA-256 digest,
    /// so `verifyChecksum` must throw `URLError.cannotDecodeContentData`.
    @Test func verifyChecksum_emptyExpectedHex_throwsCannotDecodeContentData() async throws {
        let url = try writeTempFile(Data("any content".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: "")
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    // MARK: - verifyChecksum — zero-byte file

    /// A zero-byte file is distinct from a missing file: it opens successfully
    /// and produces a real SHA-256 (the empty-data digest). When the expected
    /// hex matches that digest, `verifyChecksum` must not throw.
    @Test func verifyChecksum_zeroByteFile_matchingEmptyDigest_doesNotThrow() async throws {
        let url = try writeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        // Must not throw — the file exists and its digest matches.
        try await verifyChecksum(zipURL: url, expectedHex: emptyDataSHA256)
    }

    /// When the expected hex does NOT match the zero-byte file’s digest,
    /// `verifyChecksum` must throw `URLError.cannotDecodeContentData` —
    /// the same error as any other mismatch.
    @Test func verifyChecksum_zeroByteFile_wrongDigest_throwsCannotDecodeContentData() async throws {
        let url = try writeTempFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let wrongHex = sha256Hex(Data("not empty".utf8))
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: wrongHex)
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    // MARK: - verifyChecksum — missing file

    @Test func verifyChecksum_missingFile_throwsError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).zip")
        var thrown: Error?
        do {
            try await verifyChecksum(zipURL: url, expectedHex: "abc123")
        } catch {
            thrown = error
        }
        #expect(thrown != nil)
    }

    // MARK: - fixedZipURL

    /// The zip is always named `update.zip` — verify both the full filename and
    /// the extension in one assertion to avoid redundant checks.
    @Test func fixedZipURL_hasExpectedFilename() {
        let updater = makeUpdater()
        #expect(updater.fixedZipURL.lastPathComponent == "update.zip")
        #expect(updater.fixedZipURL.pathExtension == "zip")
    }

    @Test func fixedZipURL_scopedToSchedulerIdentifier() {
        let updater = makeUpdater()
        let parentDir = updater.fixedZipURL.deletingLastPathComponent().lastPathComponent
        #expect(parentDir == updater.schedulerIdentifier)
    }

    @Test func fixedZipURL_differentIdentifiers_differentPaths() {
        let updaterA = AppUpdater(
            repo: "o/r", currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.a"
        )
        let updaterB = AppUpdater(
            repo: "o/r", currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            schedulerIdentifier: "com.test.b"
        )
        #expect(updaterA.fixedZipURL != updaterB.fixedZipURL)
    }
}
