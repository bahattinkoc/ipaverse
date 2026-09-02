# Frida Gadget (iOS) — downloaded, not vendored

- **Source**: https://github.com/frida/frida/releases/tag/17.17.0
- **Asset**: `frida-gadget-17.17.0-ios-universal.dylib.xz` (fat Mach-O dylib, `arm64` + `arm64e`)
- **License**: wxWindows Library Licence, Version 3.1 (LGPLv2 + a linking exception permitting distribution of binary object code under your own terms) — see [`LICENSE`](LICENSE).

## What it's for

ipaverse's Resigning flow can optionally inject this dylib into a re-signed app
(via a patched `LC_LOAD_DYLIB` load command in the main executable, see
`Services/DylibInjector.swift`). This turns the app into a Frida Gadget host,
letting a security researcher attach `frida` from a host machine and run
instrumentation scripts (e.g. SSL pinning bypass) against the app on a
**non-jailbroken** device — no `frida-server`/root required, since the agent
runs in-process.

This exists purely to support authorized security testing (bug bounty
programs, contracted pentests, testing your own apps). See the main
[README](../../../README.md) security/privacy section and
`Context/Resigning` UI copy for the user-facing disclaimer.

## Why this isn't bundled in the app

At ~40MB, statically bundling this into `ipaverse.app` would roughly double
the download size for every user — including the vast majority who never
touch the security-testing features. Instead, `Services/FridaRuntime.swift`
downloads it once, the first time "Inject Frida Gadget" is used, and caches
it at `~/Library/Application Support/ipaverse/Frida/FridaGadget.dylib`.
`DylibInjector` reads it from there.

The download comes from this repo's own GitHub Releases (tag
`frida-deps-17.17.0`), not directly from Frida's release, so ipaverse
controls exactly which build gets served and can pin it to the version
`Vendor/frida-core` (the host-side counterpart) expects.

## Updating

1. Download the new `frida-gadget-<version>-ios-universal.dylib.xz` release asset and decompress it (`xz -d`, or Python's `lzma` module if `xz` isn't installed) to get `FridaGadget.dylib`.
2. Upload it as an asset on a new `frida-deps-<version>` GitHub release of this repo.
3. Bump `FridaRuntime.version` to match, and keep it in lockstep with `Vendor/frida-core`'s version — host and target must speak the same Frida wire protocol.
