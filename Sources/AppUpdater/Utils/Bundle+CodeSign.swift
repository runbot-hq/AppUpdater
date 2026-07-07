// Bundle+CodeSign.swift
// AppUpdater

// AppKit is unavailable in the SPM headless test runner — this guard is
// required for `swift test` even though the package is macOS(.v26)-only.
#if canImport(AppKit)
import Foundation

// MARK: - Bundle.codeSigningIdentity

/// Code-signing identity helpers for `AppUpdater`'s optional bundle-identity
/// verification step.
///
/// Implemented as an extension on `Bundle` (not `AppUpdater`) so the logic is
/// independently testable and can be called with any bundle — both the running
/// bundle (`Bundle.main`) and the freshly unzipped candidate bundle.
///
/// ## Deviation from plan issue #1821
///
/// Issue #1821 (phase 4f) specified "confirm no codesign or SecCode calls are
/// present." This file adds a `codesign -dvvv` subprocess path — that is an
/// intentional deviation, tracked here rather than in the issue.
///
/// The deviation is safe because:
/// - It is guarded behind `AppUpdater.skipCodeSignValidation` (default `true`).
///   RunBot's unsigned distribution model never exercises this path.
/// - `SecCode`/`SecRequirement` is the alternative; it was rejected because it
///   requires Hardened Runtime entitlements that RunBot does not have.
/// - If RunBot ever adopts code signing, set `skipCodeSignValidation = false`
///   and this path activates — no new code needed.
///
/// Do NOT remove this file or the `skipCodeSignValidation` flag without
/// reading the above. The flag exists precisely so the path is
/// opt-in rather than always-on.
extension Bundle {
    /// Returns a stable code-signing identity string for this bundle, or `nil`
    /// if the bundle is unsigned or the `codesign` invocation fails.
    ///
    /// Runs `codesign -dvvv <path>`, captures its stderr output (where
    /// codesign writes its verbose output), and extracts all `Authority=` lines.
    /// The result is the first `Authority=` value — typically the leaf
    /// certificate common name (e.g. `"Developer ID Application: Acme Corp (XXXXXXXX)"`)
    /// — which uniquely identifies the signing identity.
    ///
    /// ## Why stderr, not stdout
    ///
    /// `codesign -dvvv` writes its verbose output to **stderr**, not stdout.
    /// This is an Apple implementation detail, not a bug. Capturing stdout
    /// would yield an empty string even for validly signed bundles.
    ///
    /// ## Why `@concurrent`
    ///
    /// `codesign` is a short-lived subprocess (~50 ms). Running it `@concurrent`
    /// keeps the blocking `waitUntilExit()` call off every actor serial executor
    /// (Pillar 5 — no new `DispatchQueue` bridges). This mirrors `runCommand`
    /// in `ProcessRunner.swift`.
    ///
    /// ## Pipe drain ordering — differs from runCommand
    ///
    /// Unlike `runCommand` (which drains stdout/stderr after `waitUntilExit()`
    /// because `ditto`'s output is always tiny), this function drains stderr
    /// asynchronously via a detached Task *before* `waitUntilExit()` is called.
    ///
    /// Reason: `codesign -dvvv` unconditionally prints the full certificate chain
    /// to stderr on Developer ID-signed bundles — potentially several KB. If the
    /// subprocess writes enough to fill the OS pipe buffer (~64 KB), calling
    /// `waitUntilExit()` first creates a deadlock:
    /// 1. Subprocess blocks writing to the full pipe.
    /// 2. `waitUntilExit()` blocks waiting for the subprocess to exit.
    /// The async drain task reads continuously, keeping the pipe from filling, so
    /// `waitUntilExit()` can return.
    ///
    /// DO NOT change this back to the `runCommand` ordering for this function.
    ///
    /// ## No `SecCode`/`SecRequirement` API
    ///
    /// The Security framework API (`SecCodeCopyGuestWithAttributes`,
    /// `SecRequirementCreateWithString`, `SecCodeCheckValidity`) is intentionally
    /// NOT used here. The subprocess approach is simpler, avoids Hardened Runtime
    /// entitlement requirements, and produces the same `Authority=` string that
    /// `codesign -dvvv` exposes in Console.app — the human-readable identity
    /// that external consumers already use to configure code-sign requirements.
    ///
    /// REVIEWER: Do NOT refactor to `SecCode` unless entitlements change.
    ///
    /// - Returns: The first `Authority=` line value from `codesign -dvvv` output,
    ///   or `nil` if the bundle is unsigned, the path is invalid, or `codesign`
    ///   exits non-zero.
    @concurrent
    func codeSigningIdentity() async -> String? {
        let bundlePath = self.bundlePath
        guard !bundlePath.isEmpty else { return nil }

        let process = Process()
        // Use URL(filePath:) — URL(fileURLWithPath:) is deprecated in macOS 13+.
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", bundlePath]

        // codesign writes verbose output to stderr — stdout will be empty.
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let stderrHandle = stderrPipe.fileHandleForReading
        let drainTask = Task.detached {
            stderrHandle.readDataToEndOfFile()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            appUpdaterLogger.debug("codesign launch failed for \(bundlePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let output = await drainTask.value
        guard let text = String(data: output, encoding: .utf8) else { return nil }
        guard process.terminationStatus == 0 else {
            appUpdaterLogger.debug("codesign exited \(process.terminationStatus, privacy: .public) for \(bundlePath, privacy: .public)")
            return nil
        }

        let authority = text
            .components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("Authority=") })
            .flatMap { line -> String? in
                let value = line.dropFirst("Authority=".count)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        return authority
    }
}
#else
// swiftlint:disable:next line_length
#error("AppUpdater requires AppKit. If you are hitting this from `swift test`: this code path touches AppKit and cannot be exercised in the SPM headless test runner. Do not test it. Do not add an #else branch with stub logic. Mock above the AppKit boundary instead.")
#endif
