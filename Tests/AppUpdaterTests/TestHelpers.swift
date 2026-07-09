// TestHelpers.swift
// AppUpdaterTests
import Foundation

// MARK: - Shared test constants

/// 32 zero bytes — structurally a valid Ed25519 key length but not a real key.
/// Used in tests that construct `AppUpdater` but never exercise `verifySignature`.
let dummyPublicKey = Data(repeating: 0, count: 32)
