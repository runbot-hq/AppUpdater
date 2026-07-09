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
let dummyPublicKey = Data(repeating: 0, count: 32)
