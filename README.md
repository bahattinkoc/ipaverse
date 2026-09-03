<div align="center">
  <img src="ipaverse/ipaverse/Assets.xcassets/AppIcon.appiconset/Untitled-macOS-Default-1024x1024@1x.png" width="120" height="120" alt="ipaverse">

  <h1>ipaverse</h1>
  <p>Download, re-sign, and sideload iOS, iPadOS, macOS, tvOS, and visionOS apps — without Xcode or Terminal.<br>Manage Apple IDs, storefronts, and version history, all from a native SwiftUI app on your Mac.</p>

  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.6+-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14.6+"></a>
  <a href="https://developer.apple.com/xcode/swiftui/"><img src="https://img.shields.io/badge/SwiftUI-5.0-blue?style=flat-square&logo=swift&logoColor=white" alt="SwiftUI 5.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="MIT License"></a>
</div>

<br>

> Re-signing and installation only work with DRM-free IPAs. Most free apps qualify — paid apps are typically FairPlay-encrypted, unless you produce a decrypted copy first (see [Security Testing](#security-testing), which requires a jailbroken source device).

<br>

## Demo

<table>
<tr>
<td align="center" width="50%">
  <img src="Resource/download.gif" width="100%"><br>
  <sub><b>Download</b></sub>
</td>
<td align="center" width="50%">
  <img src="Resource/edit_and_sign.gif" width="100%"><br>
  <sub><b>Re-sign IPA</b></sub>
</td>
</tr>
<tr>
<td align="center">
  <img src="Resource/ipa_install_to_device.gif" width="100%"><br>
  <sub><b>Install to Device</b></sub>
</td>
<td align="center">
  <img src="Resource/account_switch.gif" width="100%"><br>
  <sub><b>Switch Account</b></sub>
</td>
</tr>
<tr>
<td align="center" colspan="2">
  <img src="Resource/country_change.gif" width="50%"><br>
  <sub><b>Change Storefront</b></sub>
</td>
</tr>
</table>

<br>

## Installation

```bash
brew install --cask ipaverse
```

Or build from source:

```bash
git clone https://github.com/bahattinkoc/ipaverse.git
cd ipaverse
open ipaverse.xcodeproj
```

<br>

## What works / What doesn't

| Supported | Not supported |
|---|---|
| DRM-free apps | Pirated / cracked IPAs |
| FairPlay-encrypted apps, given a jailbroken source device¹ | App Store policy circumvention |
| App Store search | |
| Version history | |
| Re-signing own or decrypted apps | |

¹ ipaverse never breaks FairPlay's cryptography itself. Given a jailbroken device where you're already legitimately running the app (e.g. under your own Apple ID), it can capture the memory iOS has already decrypted for execution and use that to produce a DRM-free copy for re-signing — see [Security Testing](#security-testing) below.

<br>

## Security Testing

ipaverse includes a small toolkit aimed at security researchers doing **authorized** iOS app testing (bug bounty programs, contracted pentests, or testing your own apps) — not general sideloading. All of it lives in the Re-sign and Downloaded screens. None of it is bundled into ipaverse.app itself (it would otherwise roughly double the download size) — Frida's components are downloaded once, on first use, and cached locally.

- **Security Testing Mode** — one toggle that disables ATS (`NSAllowsArbitraryLoads`) on the signed build so a MITM proxy (Burp, mitmproxy) can intercept its traffic. Every re-signed build is also always debuggable (`get-task-allow`). This does **not** bypass in-app certificate/public-key pinning — that's enforced in the app's own code, independent of ATS.
- **Inject Frida Gadget** — patches the app's main binary to load a bundled [Frida](https://frida.re) Gadget at launch, so you can attach with `frida -H <device-ip>:27042 -n Gadget` (or [objection](https://github.com/sensepost/objection)) and instrument it — including bypassing pinning — on a **non-jailbroken** device. No `frida-server`/root needed, since the agent runs in-process.
- **Dump Decrypted Copy** — for a real App Store IPA (which is FairPlay-encrypted even when the app is free), this reads the already-decrypted binary out of a *running* instance of the app on a **jailbroken** source device you control, and patches that into a DRM-free copy you can then re-sign and test on a separate, non-jailbroken target device. This is the same technique tools like `frida-ios-dump` use: it captures memory the OS already decrypted to execute the app, rather than breaking FairPlay's cryptography.

None of this replaces getting proper authorization before testing an app you don't own.

<br>

## Security & Privacy

ipaverse runs entirely on your Mac.

- Apple ID credentials are stored in macOS Keychain.
- Authentication uses Apple's GrandSlam flow.
- Passwords are never transmitted directly — an SRP-6a challenge/response is used instead.
- Anisette headers are generated locally using Apple frameworks; no external anisette server is required.
- Your Apple ID, password, certificates, provisioning profiles, and IPA files are never uploaded to any third-party server.

<br>

## License

ipaverse itself is [MIT licensed](LICENSE) and fully open source.

A few vendored components are licensed differently:

- The App Store sign-in flow statically links [Unicorn Engine](https://github.com/unicorn-engine/unicorn) (**GPL-2.0**, see [`ipaverse/Vendor/unicorn/LICENSE`](ipaverse/Vendor/unicorn/LICENSE)) to emulate Apple's own App Store signing challenge locally on your Mac — see [`ipaverse/Vendor/unicorn/README.md`](ipaverse/Vendor/unicorn/README.md) for what it does and how it's built. Because ipaverse's full source is already public here, GPL-2.0's source-availability requirement for the combined binary is satisfied by this repository itself.
- The [Security Testing](#security-testing) features embed [Frida](https://frida.re)'s Gadget and link its core library (**wxWindows Library Licence 3.1**, an LGPLv2-based license with a linking exception — see [`ipaverse/Vendor/frida/LICENSE`](ipaverse/Vendor/frida/LICENSE)). See [`ipaverse/Vendor/frida/README.md`](ipaverse/Vendor/frida/README.md) and [`ipaverse/Vendor/frida-core/README.md`](ipaverse/Vendor/frida-core/README.md) for what's vendored and why.

<div align="center">
<sub>bahattinkoc/ipaverse</sub>
</div>
