<div align="center">
  <img src="ipaverse/ipaverse/Assets.xcassets/AppIcon.appiconset/Untitled-macOS-Default-1024x1024@1x.png" width="128" height="128" alt="ipaverse">
  <h1>ipaverse</h1>
  <p>Download, re-sign, and sideload iOS apps — without Xcode or Terminal.</p>

[![macOS](https://img.shields.io/badge/macOS-14.6+-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0+-blue?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/)

</div>

---

## Features

- Search the App Store and download IPA files
- Browse full version history for any app
- Re-sign IPAs with your own developer certificate
- Install directly to a connected iPhone/iPad over USB
- Manage multiple Apple IDs with Keychain storage
- Switch storefronts across regions

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

**Made with ❤️**
