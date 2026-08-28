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
/// executor rather than blocking an actor serial executor — this library never
/// performs blocking I/O on an actor's executor.
///
/// ## `Data(contentsOf:)` is INTENTIONAL — do not refactor to streaming
///
/// Release zips are expected to be modest — tens of MB at most — and
/// `@concurrent` already keeps the read off every actor executor. Streaming
/// would add real complexity for no practical benefit at that size.
///
/// That expectation is not load-bearing, because the zip's size is ultimately
/// server-controlled: a consumer's release asset can be any size. So
/// `.mappedIfSafe` is passed — the file is memory-mapped rather than copied
/// into the heap when the OS considers mapping safe, and falls back to an
/// ordinary read otherwise. That bounds resident memory for an unexpectedly
/// large zip at zero cost, which is what makes the "expected modest"
/// assumption above safe to rely on.
/// This is NOT streaming — the call site, error behaviour, and the `Data` value
/// handed to `isValidSignature` are unchanged. See issue #69 (B2).
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
/// Throws `URLError(.badServerResponse)` when `publicKeyBytes` cannot be
/// parsed as a valid Ed25519 key (wrong length or invalid curve point) —
/// this indicates a misconfigured public key in the host app, not a bad
/// download.
///
/// Throws `URLError(.cannotDecodeContentData)` when the signature is invalid
/// (wrong key, tampered zip, or mismatched `.sig` sidecar) — this indicates
/// a bad or forged download.
///
/// Propagates any `Data(contentsOf:)` error on read failure.
///
/// A zero-byte zip or a zero-byte signature sidecar both produce a
/// `false` return from `isValidSignature` and surface as
/// `.cannotDecodeContentData` — neither causes a silent pass.
@concurrent
func verifySignature(zipURL: URL, signatureBytes: Data, publicKeyBytes: Data) async throws {
    let zipData = try Data(contentsOf: zipURL, options: .mappedIfSafe)

    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes) else {
        appUpdaterLogger.error(
            """
            verifySignature: could not parse publicKeyBytes as a Curve25519 public key \
            — check that the key is a valid 32-byte Ed25519 raw public key \
            (not PEM, not DER, not base64)
            """
        )
        throw URLError(.badServerResponse)
    }

    guard publicKey.isValidSignature(signatureBytes, for: zipData) else {
        throw URLError(.cannotDecodeContentData)
    }
}
