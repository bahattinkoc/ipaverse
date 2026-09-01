<div align="center">
  <img src="ipaverse/ipaverse/Assets.xcassets/AppIcon.appiconset/Untitled-macOS-Default-1024x1024@1x.png" width="120" height="120" alt="ipaverse">

  <h1>ipaverse</h1>
  <p>Download, re-sign, and sideload iOS, iPadOS, macOS, tvOS, and visionOS apps — without Xcode or Terminal.<br>Manage Apple IDs, storefronts, and version history, all from a native SwiftUI app on your Mac.</p>

  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.6+-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14.6+"></a>
  <a href="https://developer.apple.com/xcode/swiftui/"><img src="https://img.shields.io/badge/SwiftUI-5.0-blue?style=flat-square&logo=swift&logoColor=white" alt="SwiftUI 5.0"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="MIT License"></a>
</div>

<br>

> Re-signing and installation only work with DRM-free IPAs. Most free apps qualify — paid apps are typically FairPlay-encrypted.

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
| DRM-free apps | FairPlay-encrypted paid apps |
| App Store search | Pirated / cracked IPAs |
| Version history | DRM bypass |
| Re-signing own apps | App Store policy circumvention |

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

One vendored component is licensed differently: the App Store sign-in flow statically links [Unicorn Engine](https://github.com/unicorn-engine/unicorn) (**GPL-2.0**, see [`ipaverse/Vendor/unicorn/LICENSE`](ipaverse/Vendor/unicorn/LICENSE)) to emulate Apple's own App Store signing challenge locally on your Mac — see [`ipaverse/Vendor/unicorn/README.md`](ipaverse/Vendor/unicorn/README.md) for what it does and how it's built. Because ipaverse's full source is already public here, GPL-2.0's source-availability requirement for the combined binary is satisfied by this repository itself.

<div align="center">
<sub>bahattinkoc/ipaverse</sub>
</div>
