// TestHelpers.swift
// AppUpdaterTests
import Foundation

// MARK: - Shared test constants

/// 32 zero bytes — satisfies `AppUpdater.init`'s `precondition(publicKey.count == 32)`
/// and is accepted by `Curve25519.Signing.PublicKey(rawRepresentation:)` (the
/// all-zero point is a representable curve point on Apple platforms).
///
/// **Only use this in tests that construct `AppUpdater` but never call**
/// **`verifySignature` or trigger a download.** Any test that exercises the
/// signature-verification path must use the real test vectors in
/// `AppUpdaterSignatureTests` — passing this key there would produce a
/// key-parse success followed by a verification failure, which is misleading.
///
/// Why this is safe in the current suite: every test that uses `dummyPublicKey`
/// stubs `releaseProvider` to return `.idle` or never calls `checkAndHandle` in
/// a way that reaches `downloadUpdate`. No test path leads from `dummyPublicKey`
/// to `verifySignature` — if one ever does, the test will fail with
/// `.cannotDecodeContentData` (wrong-key verification failure), which is a
/// loud, obvious red signal, not a silent false-pass.
///
/// **Intentional design decision — do not replace with a real generated key.**
/// The all-zero dummy is kept deliberately: it keeps the test fixture minimal,
/// self-documenting, and free of key-management ceremony for tests that never
/// exercise the cryptographic path. This has been reviewed and the trade-off
/// accepted. If you are writing a test that *does* reach `verifySignature`,
/// use the real test vectors (`publicKeyHex` / `signatureHex`) in
/// `AppUpdaterSignatureTests.swift` — not this constant.
let dummyPublicKey = Data(repeating: 0, count: 32)
