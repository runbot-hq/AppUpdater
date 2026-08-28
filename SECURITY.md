# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/runbot-hq/AppUpdater/security/advisories/new)
rather than opening a public issue. Include the affected version or commit, a
description of the impact, and reproduction steps if you have them.

Non-sensitive robustness problems (a crash, a stuck state machine, a wrong
version comparison) are fine as ordinary issues.

## What AppUpdater protects

AppUpdater downloads a zip from GitHub Releases and verifies it against an
Ed25519 signature sidecar using a public key the host app embeds at
`init` time. The signature covers the full zip. Verification happens before the
zip is cached and before anything is installed.

| Threat | Protected |
|---|---|
| Corrupt or truncated download | ✅ signature covers the full zip bytes |
| Network MITM | ✅ a substituted zip cannot produce a valid signature |
| Compromised GitHub account or release | ✅ an attacker without the private key cannot forge a signature |
| Compromised **private signing key** | ❌ — see below |
| Local attacker already running as the same user | ❌ — out of scope; they can replace the app bundle directly |

## Known limitations

These are documented rather than fixed. Please do not file them as new
vulnerabilities; they are tracked in
[#69](https://github.com/runbot-hq/AppUpdater/issues/69).

**No key rotation or revocation.** The host app embeds exactly one 32-byte
public key, compiled into the binary. If the corresponding private key leaks,
already-deployed installs have no recovery path: they will keep trusting
anything signed with the leaked key, and there is no mechanism to distribute a
replacement key to them. Because code-sign validation is off by default
(`skipCodeSignValidation = true`), this signature is the entire trust model.
Treat the private key with the care that implies — CI secret only, never on
disk, never in the repository.

**The cached zip is verified once, at download time.** It is then stored at
`~/Library/Caches/<schedulerIdentifier>/update.zip` and installed later without
re-verification. This only matters against an attacker who can already write to
the user's home directory, which is not a meaningful escalation.

**No transport pinning.** AppUpdater relies on App Transport Security for HTTPS
enforcement. A host app that sets `NSAllowsArbitraryLoads` weakens that, though
the signature check still prevents a substituted zip from being installed.

## Signing releases

See [Key pair setup](README.md#key-pair-setup) in the README for generating the
key pair, signing artifacts in CI without writing the private key to disk, and
embedding the public key in your app.
