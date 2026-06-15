<div align="center">
  <img src="ipaverse/ipaverse/Assets.xcassets/AppIcon.appiconset/Untitled-macOS-Default-1024x1024@1x.png" width="128" height="128" alt="ipaverse">
  <h1>ipaverse</h1>
  <p>Download, re-sign, and sideload iOS apps — without Xcode or Terminal.</p>

[![macOS](https://img.shields.io/badge/macOS-14.6+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0+-blue?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)

</div>

---

## Features

- Download App Store IPAs without Terminal
- Browse and archive historical app versions
- Re-sign DRM-free IPAs with your own certificate
- Install directly to connected iPhone/iPad
- Manage multiple Apple IDs securely via Keychain
- Switch App Store storefronts by region
- Built entirely with SwiftUI for macOS

> **Note:** Re-signing and installation only works with DRM-free IPAs. Most free apps qualify — paid apps are typically FairPlay-encrypted.

---

## Demo

### Download

![Download](Resource/download.gif)

### Re-sign IPA

![Edit and Sign](Resource/edit_and_sign.gif)

### Install to Device

![Install to Device](Resource/ipa_install_to_device.gif)

### Switch Account

![Account Switch](Resource/account_switch.gif)

### Change Storefront

![Country Change](Resource/country_change.gif)

---

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

---

## What works / What does not work

| Supported | Not supported |
|---|---|
| DRM-free apps | FairPlay-encrypted paid apps |
| App Store search | Pirated / cracked IPAs |
| Version history | DRM bypass |
| Re-signing own apps | App Store policy circumvention |

---

## Security & Privacy

ipaverse runs locally on your Mac.

- Apple ID credentials are stored in macOS Keychain.
- Authentication uses Apple's GrandSlam flow.
- Passwords are not transmitted directly; SRP-6a challenge/response is used.
- Anisette headers are generated locally using Apple frameworks.
- No external anisette server is required.
- ipaverse does not upload your Apple ID, password, certificates, provisioning profiles, or IPA files to any third-party server.

---

**Made with ❤️**
