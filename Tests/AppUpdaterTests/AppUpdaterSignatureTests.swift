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

    /// Raw 32-byte Ed25519 public key that signed `signatureHex`.
    private let publicKeyHex    = "e93518e72ee94d5277d3d79556b045376caddd541a35109d2d1647f250ac754b"

    /// Raw 64-byte Ed25519 signature of "hello world" under `publicKeyHex`.
    /// Written as two 64-char (32-byte) halves so the length is visually
    /// verifiable by inspection. The `assert` below enforces 128 chars at
    /// test runtime — if this were truncated, `verifySignature_validSignature_doesNotThrow`
    /// would throw and the suite would fail, not silently pass.
    private let signatureHex =
        // bytes  1–32 (64 hex chars):
        "8dad4b054f8db867b7ec2aadf0640fee22c7accb630ab8657661bdc9e3b0ca80" +
        // bytes 33–64 (64 hex chars):
        "ac2034f19fbebaeebfd1bbbbff8a0a6eebe99e72b164f766c019a0b81f8b4605"

    /// A different valid 32-byte public key — not the one that signed the payload.
    private let wrongPublicKeyHex = "c5685cccd63e7e705aea6239a49feda80b6cadd65a80e13e8ac1f4b7307800b8"

    init() {
        // Sanity-check the baked-in test vectors at suite initialisation time.
        // If signatureHex were truncated, this assert fires before any test runs
        // — making a transcription error immediately visible rather than causing
        // a confusing failure inside verifySignature_validSignature_doesNotThrow.
        assert(signatureHex.count == 128, "signatureHex must be 128 hex chars (64 bytes); got \(signatureHex.count)")
        assert(publicKeyHex.count == 64,  "publicKeyHex must be 64 hex chars (32 bytes); got \(publicKeyHex.count)")
    }

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
    /// `.badServerResponse` (invalid key parse — misconfigured public key).
    @Test func verifySignature_invalidPublicKeyBytes_throwsBadServerResponse() async throws {
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
        #expect(urlError.code == .badServerResponse)
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

    // MARK: - openssl ↔ CryptoKit round-trip

    /// Runs `executable` with `args` and returns stdout as `Data`, or `nil` on
    /// non-zero exit. Test-only helper — production code uses `runCommand`
    /// (Bool return, stdout discarded) because `ditto` produces no useful stdout.
    @concurrent
    private func runCommandOutput(_ executable: String, args: [String]) async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError  = FileHandle.nullDevice
            process.terminationHandler = { p in
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: p.terminationStatus == 0 ? output : nil)
            }
            try? process.run()
        }
    }

    /// Signs a payload with `openssl pkeyutl -sign -rawin` and verifies the
    /// resulting signature with `verifySignature` (CryptoKit).
    ///
    /// This test exists specifically to catch format incompatibilities between
    /// the `openssl` signing path documented in the README and the CryptoKit
    /// verification path in production code. The baked-in test vectors above
    /// only exercise the CryptoKit-to-CryptoKit path.
    ///
    /// Returns early (graceful skip) when `openssl` is not found in PATH — the
    /// test is an integration smoke-check, not a hard CI requirement.
    @Test func verifySignature_opensslSignedPayload_doesNotThrow() async throws {
        // Locate openssl — return early (skip) if not available.
        // Previously used withCheckedThrowingContinuation which propagated a
        // throw and marked the test FAILED instead of skipping gracefully.
        guard let pathData = await runCommandOutput("/usr/bin/which", args: ["openssl"]),
              let opensslPath = String(data: pathData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !opensslPath.isEmpty else { return }

        let tmp = FileManager.default.temporaryDirectory
        let privatePEM = tmp.appendingPathComponent("test-\(UUID().uuidString).pem")
        let payloadURL = tmp.appendingPathComponent("test-\(UUID().uuidString).zip")
        let sigURL     = tmp.appendingPathComponent("test-\(UUID().uuidString).sig")
        defer {
            try? FileManager.default.removeItem(at: privatePEM)
            try? FileManager.default.removeItem(at: payloadURL)
            try? FileManager.default.removeItem(at: sigURL)
        }

        // 1. Generate an Ed25519 private key.
        let genResult = await runCommand(opensslPath, args: [
            "genpkey", "-algorithm", "Ed25519", "-out", privatePEM.path
        ])
        guard genResult else {
            Issue.record("openssl genpkey failed — skipping round-trip test")
            return
        }

        // 2. Write a known payload to disk.
        let payload = Data("openssl-cryptokit-roundtrip".utf8)
        try payload.write(to: payloadURL)

        // 3. Sign with openssl pkeyutl -sign -rawin (the README-documented path).
        let signResult = await runCommand(opensslPath, args: [
            "pkeyutl", "-sign", "-rawin",
            "-inkey", privatePEM.path,
            "-in",    payloadURL.path,
            "-out",   sigURL.path
        ])
        guard signResult else {
            Issue.record("openssl pkeyutl -sign failed — skipping round-trip test")
            return
        }

        // 4. Extract the raw 32-byte public key via DER tail using the async
        //    runCommandOutput helper — consistent with the rest of this test's
        //    async pattern and avoids blocking waitUntilExit() on @MainActor.
        //    `openssl pkey -pubout -outform DER` last 32 bytes are the raw
        //    RFC 8032 compressed point that CryptoKit expects.
        guard let derBytes = await runCommandOutput(opensslPath, args: [
            "pkey", "-in", privatePEM.path, "-pubout", "-outform", "DER"
        ]) else {
            Issue.record("openssl pkey DER extraction failed — skipping round-trip test")
            return
        }
        // The last 32 bytes of the DER-encoded SubjectPublicKeyInfo are the raw key.
        let publicKeyBytes = derBytes.suffix(32)
        #expect(publicKeyBytes.count == 32, "DER public key extraction yielded \(publicKeyBytes.count) bytes — expected 32")

        // 5. Read the openssl-produced signature.
        let signatureBytes = try Data(contentsOf: sigURL)
        #expect(signatureBytes.count == 64, "openssl signature is \(signatureBytes.count) bytes — expected 64")

        // 6. Verify with CryptoKit via the real production function.
        try await verifySignature(
            zipURL: payloadURL,
            signatureBytes: signatureBytes,
            publicKeyBytes: Data(publicKeyBytes)
        )
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
