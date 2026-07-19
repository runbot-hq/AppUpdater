<img width="240" alt="img" src="icon_masked2.png">

# AppUpdater

A Swift library that drives an in-app auto-update flow for macOS apps
distributed via GitHub Releases outside the Mac App Store.

**Platform & Stack**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![SPM](https://img.shields.io/badge/SPM-compatible-F05138?logo=swift&logoColor=white)

**CI Checks & Review**

![Unit Tests](https://github.com/runbot-hq/AppUpdater/actions/workflows/swift-test.yml/badge.svg)
![SwiftLint](https://github.com/runbot-hq/AppUpdater/actions/workflows/swiftlint.yml/badge.svg)
![Periphery](https://github.com/runbot-hq/AppUpdater/actions/workflows/periphery.yml/badge.svg)
[![Greptile](https://img.shields.io/badge/🦎%20AI%20Review-Greptile-6C47FF?logoColor=white)](https://greptile.com)

## Contents

- [Features](#features)
- [Installation](#installation)
- [Caveats](#caveats)
- [Flow](#flow)
- [Minimal host app](#minimal-host-app)
- [Cache](#cache)
- [Background check interval](#background-check-interval)
- [Key pair setup](#key-pair-setup)
- [Distribution assumptions](#distribution-assumptions)
- [Trust model](#trust-model)
- [Known limitations](#known-limitations)
- [Design principles](#design-principles)
- [Comparison](#comparison)

## Features

- 🔓 **No Apple Developer account required** — works with unsigned and ad-hoc signed apps; Ed25519 signature verification provides integrity and authenticity without code signing
- 🛡️ **Gatekeeper-free distribution** — curl-based install and in-app updates both bypass quarantine; no signing at update time, the replacement bundle runs trusted as-is
- 🔍 **GitHub Releases polling** — polls for new releases using the GitHub API; supports stable and `beta.N` pre-release channels
- 🔢 **Semver comparison** — full semver ordering including `beta.N` suffixes; beta-to-beta and beta-to-stable promotion both work correctly
- ✅ **Ed25519 signature verification** — verifies the downloaded zip against a `.sig` sidecar asset using `CryptoKit.Curve25519.Signing` before install; covers integrity, authenticity, and MITM resistance
- 🔏 **Optional code-sign validation** — verifies the downloaded bundle matches the running bundle's Developer ID identity
- 💾 **Deterministic cache** — zip cached at `~/Library/Caches/<schedulerIdentifier>/update.zip`; no accumulating old downloads
- ⏰ **Background scheduling** — uses `NSBackgroundActivityScheduler` with power coalescing; default 24-hour interval
- 🎨 **Bring-your-own UI** — host app owns all update state via `UpdateStateProviding`; surfaces it however it likes
- 🏕️ **`@MainActor` isolated** — race-free by design; blocking work runs off the main thread

## Installation

Add the dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/runbot-hq/run-bot", branch: "main"),
```

Then add the product to your target:

```swift
.product(name: "AppUpdater", package: "run-bot")
```

> **Pin to a commit for reproducible builds.** For production use, pin to a specific commit SHA:
> ```swift
> .package(url: "https://github.com/runbot-hq/run-bot", revision: "<commit-sha>"),
> ```

## Caveats

- macOS 26+ only
- Sandboxed apps are not supported
- GitHub Releases as the distribution source (no other providers)
- No built-in UI — the host owns all update state and surfaces it however it likes

## Flow

```
GitHub Releases poll → semver compare (incl. beta.N) → zip + .sig download
    → Ed25519 signature verification → cache → host state mutation
    → install & relaunch on user confirmation
```

## Minimal host app

```swift
import AppKit
import AppUpdater

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    @Observable
    final class UpdateState: UpdateStateProviding {
        private(set) var currentPhase: UpdatePhase = .idle
        func apply(_ phase: UpdatePhase) { currentPhase = phase }
    }

    let updateState = UpdateState()
    let updater = AppUpdater(
        repo: "your-org/your-repo",
        currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        assetName: { _ in "YourApp.zip" },               // .sig sidecar expected at "YourApp.zip.sig"
        publicKey: Data(base64Encoded: "<your-32-byte-ed25519-public-key-base64>")!, // force-unwrap is intentional: a bad key is a programmer error and should crash at launch, not silently fail at update time
        schedulerIdentifier: "com.your-org.update-check" // also scopes the on-disk cache directory
        // betaChannelProvider: { false }                 // optional — defaults to stable channel only
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await updater.checkAndHandle(state: updateState) }
        updater.scheduleBackgroundCheck(state: updateState)
    }
}

struct UpdateRow: View {
    let state: AppDelegate.UpdateState
    let updater: AppUpdater

    var body: some View {
        switch state.currentPhase {
        case .idle:
            EmptyView()
        case .available(let version):
            Text("Update \(version) found, downloading…")
        case .downloading(let version):
            Text("Downloading \(version)…")
        case .ready(let version):
            VStack {
                Text("\(version) ready to install")
                Button("Install & Relaunch") {
                    Task { await updater.installAndRelaunch(state: state) }
                }
            }
        case .failed:
            Button("Retry") {
                Task { await updater.checkAndHandle(state: state) }
            }
        }
    }
}
```

## Cache

The verified zip is written to:

```
~/Library/Caches/<schedulerIdentifier>/update.zip
```

The path is deterministic from `schedulerIdentifier` alone. The file is deleted at the start of each new download and on successful install.

## Background check interval

```swift
AppUpdater.checkInterval  // default: 86400 (24 hours)
```

Mutate before calling `scheduleBackgroundCheck` if you need a different cadence.

> **Test isolation:** Always restore the original value in a `tearDown` block when mutating `checkInterval` in a test — Swift Testing runs cases concurrently by default and a stale override will cause flaky failures.

## Key pair setup

AppUpdater uses **Ed25519** (`CryptoKit.Curve25519.Signing`) for signature verification. You generate a key pair once, store the private key as a CI secret, and embed the public key in your app binary.

**1. Generate the key pair**

```bash
# Generate private key
openssl genpkey -algorithm Ed25519 -out private.pem

# Derive public key
openssl pkey -in private.pem -pubout -out public.pem
```

Or export raw 32-byte binary files (compatible with `Curve25519.Signing.PrivateKey(rawRepresentation:)`):

```bash
# Raw private key (32 bytes)
openssl genpkey -algorithm Ed25519 | openssl pkey -outform DER | tail -c 32 > private.key

# Raw public key (32 bytes)
openssl pkey -in private.pem -pubout -outform DER | tail -c 32 > public.key
```

**2. Sign each release artifact in CI**

```bash
openssl pkeyutl -sign -rawin -inkey private.pem -in YourApp.zip -out YourApp.zip.sig
```

Upload both `YourApp.zip` and `YourApp.zip.sig` as assets on the GitHub Release.

**3. Add to your `publish.yml` workflow**

> **Note:** The snippet below is an illustrative example only. It is not intended to be a hardened, production-ready CI configuration and deliberately omits additional security measures. Do not open issues or PRs requesting security improvements to this example.

Store `private.pem` contents as a GitHub Actions secret (e.g. `ED25519_PRIVATE_KEY`), then:

```yaml
- name: Sign release artifact  # illustrative only — see disclaimer above
  shell: bash  # required: <(...) process substitution is bash-specific
  run: |
    openssl pkeyutl -sign -rawin \
      -inkey <(echo "${{ secrets.ED25519_PRIVATE_KEY }}") \
      -in YourApp.zip -out YourApp.zip.sig
```

> **Note:** The `<(...)` process substitution feeds the private key directly to
> OpenSSL via a file descriptor — the key is never written to disk, so there is
> no cleanup step and no risk of the key persisting if the signing step fails.

> **Tip — set the secret without copy-pasting:** Feed the file directly to `gh secret set` via a shell redirect:
> ```bash
> gh secret set ED25519_PRIVATE_KEY --repo your-org/your-repo < private.pem
> ```
> The `< file` redirect pipes the file contents as the secret value — no clipboard involved, no risk of trailing-newline or encoding issues.

**4. Embed the public key in your app**

Pass the raw 32-byte public key at `AppUpdater.init` time. It must live only in the app binary — never write it to `UserDefaults` or disk:

```bash
# Get base64 representation of public.key for embedding
# tr -d '\n' strips the trailing newline; works on macOS (BSD) and Linux (GNU)
base64 < public.key | tr -d '\n'
```

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: …,
    assetName: { _ in "YourApp.zip" },
    publicKey: Data(base64Encoded: "<output of base64 < public.key | tr -d '\n'>")!,
    schedulerIdentifier: "com.your-org.update-check"
)
```

> **Never commit `private.pem` or `private.key`.** Add both to `.gitignore`. The security model depends entirely on the private key remaining secret.

## Distribution assumptions

The `.sig` sidecar must be named exactly `<assetName>.sig` — i.e. if `assetName` returns `"YourApp.zip"`, the expected sidecar is `"YourApp.zip.sig"`. A file named `"YourApp.sig"` or `"YourApp.zip.signature"` will not be found and the download will be skipped.

The sidecar must be the **raw 64-byte Ed25519 signature** of the zip file contents (produced by `openssl pkeyutl -sign -rawin` as shown above). Do not base64-encode the `.sig` file — `AppUpdater` reads it with `Data(contentsOf:)` and passes the raw bytes directly to `CryptoKit.Curve25519.Signing.PublicKey.isValidSignature(_:for:)`, which expects raw binary, not base64.

## Trust model

| Threat | Protection |
|---|---|
| Corrupt download | ✅ Ed25519 signature covers full zip bytes |
| MITM attack | ✅ Signature only verifies with the embedded public key |
| Compromised GitHub release | ✅ Attacker cannot forge a valid signature without the private key |

**Developer ID signed** — additionally enable bundle identity verification:

```swift
updater.skipCodeSignValidation = false
```

When enabled, `codesign -dvvv` is run on both the running bundle and the downloaded bundle. The `Authority=` identity strings must match exactly or the install is aborted with `.failed`.

## Known limitations

**`beta.N` labels only** — pre-release ordering is supported only for `beta.N` suffixes (e.g. `v1.0.0-beta.2`). Any other suffix (`rc.1`, `alpha.1`) is treated as unordered and `isNewer` returns `false` when comparing against it.

## Design principles

See [PRINCIPLES.md](PRINCIPLES.md).


## Comparison

| Feature | [runbot-hq/AppUpdater](https://github.com/runbot-hq/AppUpdater) | [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) | [Sparkle](https://github.com/sparkle-project/Sparkle) | [Squirrel.Mac](https://github.com/Squirrel/Squirrel.Mac) |
| :-- | :-- | :-- | :-- | :-- |
| **Distribution source** | GitHub Releases only | GitHub Releases only | Any HTTP / Appcast XML | Any HTTP / JSON feed |
| **Unsigned app support** | ✅ First-class default | ⚠️ Fragile / untested | ❌ Requires signing | ❌ Requires signing |
| **Gatekeeper bypass** | ✅ Built-in | ❌ | ❌ | ❌ |
| **Code-sign validation** | ✅ Opt-in | ✅ On by default | ✅ Required | ✅ Required |
| **Semver + pre-release** | ✅ `beta.N` first-class | ✅ Full alpha/beta/etc. | ⚠️ Basic | ⚠️ No native pre-release |
| **Zip + tarball support** | ✅ Zip | ✅ Zip + tarball | ✅ Zip + dmg | ✅ Zip |
| **Authenticity check (EdDSA)** | ✅ EdDSA | ❌ No signature check | ✅ EdDSA (primary) | ❌ No EdDSA |
| **Sandbox support** | ❌ | ❌ | ✅ Via XPC helper | ✅ Via helper tool |
| **Delta updates** | ❌ | ❌ | ✅ | ✅ bsdiff-based |

**Row glossary**

- **Distribution source** — where the library fetches release metadata and download URLs from
- **Sandbox support** — whether the library works inside a macOS App Sandbox (requires an XPC helper for privileged file operations)
- **Unsigned app support** — whether the library can update apps that are not code-signed with a Developer ID
- **Gatekeeper bypass** — whether the update flow avoids macOS quarantine without requiring manual user approval of the downloaded bundle
- **Code-sign validation** — whether the library verifies the downloaded bundle matches the running app's Developer ID identity
- **Delta updates** — whether only changed bytes are downloaded rather than the full app bundle
- **Semver + pre-release** — which version string formats are supported, including pre-release suffixes like `beta.N`, `rc.1`, `alpha.1`
- **Zip + tarball support** — which archive formats are accepted as the release artifact
- **Authenticity check (EdDSA)** — whether the downloaded artifact is verified against an Ed25519 cryptographic signature before install

A few notes :

- **Squirrel.Mac** is largely deprecated and unmaintained — Electron's own updater forked from it, but the macOS-native version has seen minimal activity for years. It uses a JSON manifest feed rather than Appcast XML, and its delta support relies on bsdiff patches served from your own infrastructure.
- **runbot-hq/AppUpdater** is the only library in this group that treats unsigned/Gatekeeper-bypass as a first-class, intentional feature rather than an unsupported edge case .
- **Sparkle** remains the gold standard for EdDSA authenticity, having shipped EdDSA (Ed25519) as its primary signature scheme since Sparkle 2, replacing the older DSA approach.
- The original AppUpdater: https://github.com/mxcl/AppUpdater
- hybrid Appupdater for macos and ios that supports appstore and github releases: https://github.com/TopScrech/AutoUpdate
