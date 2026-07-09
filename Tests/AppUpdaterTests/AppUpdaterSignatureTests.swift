// AppUpdaterSignatureTests.swift
// AppUpdaterTests
import CryptoKit
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterSignatureTests

/// Tests for `verifySignature` (a @concurrent free function) and
/// `AppUpdater.fixedZipURL`.
///
/// All signature tests use baked-in Ed25519 test vectors generated once
/// via `Curve25519.Signing.PrivateKey` — no live key generation at test time.
/// Network I/O is never required.
@MainActor
@Suite("AppUpdater.signature")
struct AppUpdaterSignatureTests {

    // MARK: - Test vectors
    //
    // Generated with:
    //   let priv = Curve25519.Signing.PrivateKey()
    //   let sig  = try priv.signature(for: Data("hello world".utf8))
    //   print(priv.publicKey.rawRepresentation.hexString)
    //   print(sig.hexString)
    //
    // Payload: "hello world" (UTF-8)

    /// Raw 32-byte Ed25519 public key that signed `helloWorldSignatureHex`.
    private let publicKeyHex    = "e93518e72ee94d5277d3d79556b045376caddd541a35109d2d1647f250ac754b"

    /// Raw 64-byte Ed25519 signature of "hello world" under `publicKeyHex`.
    private let signatureHex    = "8dad4b054f8db867b7ec2aadf0640fee22c7accb630ab8657661bdc9e3b0ca80ac2034f19fbebaeebfd1bbbbff8a0a6eebe99e72b164f766c019a0b81f8b4605"

    /// A different valid 32-byte public key — not the one that signed the payload.
    private let wrongPublicKeyHex = "c5685cccd63e7e705aea6239a49feda80b6cadd65a80e13e8ac1f4b7307800b8"

    private func data(fromHex hex: String) -> Data {
        precondition(hex.count.isMultiple(of: 2), "data(fromHex:) requires an even-length hex string, got \(hex.count) chars")
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                preconditionFailure("data(fromHex:) encountered non-hex characters in '\(hex[index..<next])'")
            }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: - Helpers

    private func makeUpdater() -> AppUpdater {
        let domain = "AppUpdaterSignatureTests.\(UUID().uuidString)"
        return AppUpdater(
            repo: "owner/repo",
            currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            publicKey: dummyPublicKey,
            schedulerIdentifier: domain
        )
    }

    /// Writes `contents` to a temp file and returns the URL. Caller owns cleanup.
    private func writeTempFile(_ contents: Data, ext: String = "zip") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sig-test-\(UUID().uuidString).\(ext)")
        try contents.write(to: url)
        return url
    }

    // MARK: - verifySignature — valid signature

    @Test func verifySignature_validSignature_doesNotThrow() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        try await verifySignature(
            zipURL: url,
            signatureBytes: data(fromHex: signatureHex),
            publicKeyBytes: data(fromHex: publicKeyHex)
        )
    }

    // MARK: - verifySignature — wrong public key

    /// A valid signature verified against the wrong key must throw
    /// `.cannotDecodeContentData`.
    @Test func verifySignature_wrongPublicKey_throwsCannotDecodeContentData() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        var thrown: Error?
        do {
            try await verifySignature(
                zipURL: url,
                signatureBytes: data(fromHex: signatureHex),
                publicKeyBytes: data(fromHex: wrongPublicKeyHex)
            )
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    // MARK: - verifySignature — tampered payload

    /// The correct key and sig, but the zip content was modified after signing.
    @Test func verifySignature_tamperedPayload_throwsCannotDecodeContentData() async throws {
        let tampered = Data("TAMPERED content".utf8)
        let url = try writeTempFile(tampered)
        defer { try? FileManager.default.removeItem(at: url) }

        var thrown: Error?
        do {
            try await verifySignature(
                zipURL: url,
                signatureBytes: data(fromHex: signatureHex),
                publicKeyBytes: data(fromHex: publicKeyHex)
            )
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    // MARK: - verifySignature — invalid public key bytes

    /// Passing fewer than 32 bytes as the public key must throw
    /// `.cannotDecodeContentData` (invalid key parse).
    @Test func verifySignature_invalidPublicKeyBytes_throwsCannotDecodeContentData() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        let truncatedKey = Data(data(fromHex: publicKeyHex).prefix(16)) // 16 bytes — not a valid Ed25519 key
        var thrown: Error?
        do {
            try await verifySignature(
                zipURL: url,
                signatureBytes: data(fromHex: signatureHex),
                publicKeyBytes: truncatedKey
            )
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    // MARK: - verifySignature — empty signature bytes

    /// An empty signature (zero bytes) is not a valid Ed25519 signature;
    /// `isValidSignature` returns false, so the call must throw
    /// `.cannotDecodeContentData`.
    @Test func verifySignature_emptySignatureBytes_throwsCannotDecodeContentData() async throws {
        let payload = Data("hello world".utf8)
        let url = try writeTempFile(payload)
        defer { try? FileManager.default.removeItem(at: url) }

        var thrown: Error?
        do {
            try await verifySignature(
                zipURL: url,
                signatureBytes: Data(),
                publicKeyBytes: data(fromHex: publicKeyHex)
            )
        } catch {
            thrown = error
        }
        let urlError = try #require(thrown as? URLError)
        #expect(urlError.code == .cannotDecodeContentData)
    }

    // MARK: - verifySignature — missing file

    @Test func verifySignature_missingFile_throwsError() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).zip")
        var thrown: Error?
        do {
            try await verifySignature(
                zipURL: url,
                signatureBytes: data(fromHex: signatureHex),
                publicKeyBytes: data(fromHex: publicKeyHex)
            )
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
            publicKey: dummyPublicKey,
            schedulerIdentifier: "com.test.a"
        )
        let updaterB = AppUpdater(
            repo: "o/r", currentVersion: "1.0.0",
            assetName: { _ in "App.zip" },
            publicKey: dummyPublicKey,
            schedulerIdentifier: "com.test.b"
        )
        #expect(updaterA.fixedZipURL != updaterB.fixedZipURL)
    }
}
