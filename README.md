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
open ipaverse/ipaverse.xcodeproj
```

Apple Silicon only (arm64), macOS 14.6 (Sonoma) or later.

<br>

## Features

- Search and download iOS, iPadOS, macOS, tvOS, and visionOS apps from the App Store.
- Manage multiple Apple ID accounts, switch storefronts/regions, and browse version history.
- Re-sign IPAs with your own certificate and provisioning profile, including a standalone Resign window.
- Install re-signed apps to a device over USB or Wi-Fi.
- An authorized security-testing toolkit for pentesters (see below).

Full usage guide, screen by screen → **[USAGE.md](USAGE.md)**

<br>

## Security Testing

ipaverse includes a small toolkit aimed at security researchers doing authorized iOS app testing: a **Security Testing Mode** toggle (disables ATS for MITM proxying), **Frida Gadget injection**, and a **Dump Decrypted Copy** tool for FairPlay apps on a jailbroken source device. These — plus **Move to New Identity** in the Re-sign window — stay disabled until you turn on **Evil Mode**, a flame toggle in the main window's toolbar; the static **Security Scan** is read-only and always available regardless. Details on each → [USAGE.md § Security Testing](USAGE.md#security-testing).

> ⚠️ **Educational and authorized use only.** These tools are meant for bug bounty programs, contracted pentests, or testing apps you own. Do not use them against apps, accounts, or systems you don't have explicit permission to test — misuse may violate Apple's terms of service and/or the law. ipaverse and its author take no responsibility for misuse.

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
