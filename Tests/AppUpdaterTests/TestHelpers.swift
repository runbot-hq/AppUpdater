// TestHelpers.swift
// AppUpdaterTests
import Foundation

// MARK: - Shared test constants

/// 32 zero bytes used as a placeholder public key in tests that **never reach
/// `verifySignature` or trigger a download.** That invariant — not curve-point
/// representability — is what makes this safe. Every test that uses
/// `dummyPublicKey` stubs `releaseProvider` or never calls `checkAndHandle` in
/// a way that reaches `downloadUpdate`, so the key is never presented to
/// CryptoKit. If that invariant is ever broken the test will fail loudly with
/// `.cannotDecodeContentData`, not silently pass.
///
/// For completeness: the all-zero sequence is also accepted by
/// `Curve25519.Signing.PublicKey(rawRepresentation:)` on Apple platforms (the
/// identity point is representable), so `AppUpdater.init`'s length precondition
/// passes too. But that is incidental — the safety guarantee is the no-verify
/// invariant above, not the curve-point property.
///
/// **Intentional design decision — do not replace with a real generated key.**
/// The all-zero dummy keeps the fixture minimal and free of key-management
/// ceremony for tests that never exercise the cryptographic path. This has been
/// reviewed and the trade-off accepted. If you are writing a test that *does*
/// reach `verifySignature`, use the real test vectors (`publicKeyHex` /
/// `signatureHex`) in `AppUpdaterSignatureTests.swift` — not this constant.
let dummyPublicKey = Data(repeating: 0, count: 32)
