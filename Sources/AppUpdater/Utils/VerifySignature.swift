// VerifySignature.swift
// AppUpdater
import CryptoKit
import Foundation

// MARK: - Ed25519 signature verification

/// Reads `zipURL` from disk and verifies its Ed25519 signature against
/// `signatureBytes` using `publicKeyBytes`.
///
/// Implemented as a `@concurrent` async free function so the synchronous
/// `Data(contentsOf:)` read runs on the cooperative thread pool's concurrent
/// executor rather than blocking an actor serial executor (Pillar 5).
///
/// ## `Data(contentsOf:)` is INTENTIONAL — do not refactor to streaming
///
/// The distributed zip is guaranteed small (< 10 MB for RunBot). `@concurrent`
/// already satisfies Pillar 5. Streaming would add real complexity for zero
/// practical benefit at this file size.
///
/// ## Signature format
///
/// `signatureBytes` must be the raw 64-byte Ed25519 signature produced by
/// `openssl pkeyutl -sign` or equivalent. The `.sig` sidecar is the binary
/// signature file — not base64, not PEM, not hex-encoded.
///
/// `publicKeyBytes` must be the raw 32-byte Ed25519 public key (RFC 8032
/// compressed point format), matching the private key used to sign.
///
/// ## Error convention
///
/// Throws `URLError(.cannotDecodeContentData)` on:
/// - `publicKeyBytes` cannot be parsed as a valid Ed25519 key (wrong length or
///   invalid point)
/// - signature verification fails (wrong key, tampered zip, or wrong sig file)
///
/// Propagates any `Data(contentsOf:)` error on read failure.
@concurrent
func verifySignature(zipURL: URL, signatureBytes: Data, publicKeyBytes: Data) async throws {
    let zipData = try Data(contentsOf: zipURL)

    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes) else {
        throw URLError(.cannotDecodeContentData)
    }

    guard publicKey.isValidSignature(signatureBytes, for: zipData) else {
        throw URLError(.cannotDecodeContentData)
    }
}
