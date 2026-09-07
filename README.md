<div align="center">
  <img src="ipaverse/ipaverse/Assets.xcassets/AppIcon.appiconset/Untitled-macOS-Default-1024x1024@1x.png" width="120" height="120" alt="ipaverse">

  <h1>ipaverse</h1>
  <p>Search and download App Store packages for iOS, iPadOS, macOS, tvOS, and visionOS.<br>Inspect, re-sign, and install compatible IPAs from a native SwiftUI app on your Mac.</p>

  <a href="https://developer.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14.6+-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14.6+"></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-5.0-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.0"></a>
  <a href="#license"><img src="https://img.shields.io/badge/License-MIT%20%2B%20third--party-lightgrey?style=flat-square" alt="MIT and third-party licenses"></a>
</div>

<br>

> App Store downloads normally remain FairPlay-encrypted, including free apps; downloading an app does not decrypt it. An original download may only launch with its associated Apple Account/license. Re-signing requires a self-built, DRM-free, or lawfully decrypted IPA (see [Security Testing](#security-testing)).

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

Requirements and device-install notes:

- Apple Silicon Mac (`arm64`) running macOS 14.6 (Sonoma) or later.
- Building from source requires Xcode; the latest stable release is recommended.
- Device installation targets iPhone and iPad. The CoreDevice path uses Xcode's `xcrun devicectl`; a bundled libimobiledevice fallback supports older devices over USB.
- Wi-Fi installation requires the device to be paired over USB first and **Connect via network** to be enabled in Xcode's Devices window.

<br>

## Features

- Search the iOS, iPadOS, macOS, tvOS, and visionOS App Store catalogs and download available packages. ipaverse can acquire licenses for free apps; paid apps must already be licensed to the active Apple Account.
- Manage multiple Apple ID accounts, switch storefronts/regions, and browse version history.
- Import existing IPAs and keep downloaded, imported, re-signed, and decrypted copies in one library with source tags.
- Edit IPA properties/files and re-sign DRM-free IPAs with your own certificate and provisioning profile, including from a standalone Resign window.
- Install compatible IPAs on an iPhone or iPad over USB or Wi-Fi.
- Run local static analysis, browse Objective-C classes, and use an authorized live Frida toolkit; manage optional external analysis tools from Settings.

Full usage guide, screen by screen → **[USAGE.md](USAGE.md)**

<br>

## Security Testing

ipaverse includes a toolkit aimed at security researchers doing authorized iOS app testing: a **Security Testing Mode** toggle (disables ATS for MITM proxying), **Frida Gadget injection**, a **Dump Decrypted Copy** tool for FairPlay apps on a jailbroken source device, and **Reverse Engineer** — local static analysis, an Objective-C class browser, and live Frida tools for bypasses, method tracing, `NSURLSession` interception, UI hierarchy inspection, and app-data inspection.

In the data tools, NSUserDefaults string/number values are editable; Keychain output is limited to item metadata, and matching sandbox files can be listed and downloaded. These features — plus **Move to New Identity** in the Re-sign window — stay disabled until you turn on **Evil Mode** from the main toolbar. Evil Mode is a deliberate UI guardrail, not a substitute for authorization.

Frida Gadget and `libfrida-core` are not bundled in the app. They are downloaded from this repository's GitHub Releases on first use, checked against pinned file sizes and SHA-256 digests, and cached in Application Support. Dumping a decrypted copy requires a jailbroken USB device with `frida-server` running and the target app open. Details and live-tool prerequisites → [USAGE.md § Security Testing](USAGE.md#security-testing).

> ⚠️ **Educational and authorized use only.** These tools are meant for bug bounty programs, contracted pentests, or testing apps you own. Do not use them against apps, accounts, or systems you don't have explicit permission to test — misuse may violate Apple's terms of service and/or the law. ipaverse and its author take no responsibility for misuse.

<br>

## Security & Privacy

ipaverse is local-first, but it is not an offline application:

- Authentication, App Store search/license/download requests, artwork loading, and the initial SAP asset fetch communicate directly with Apple services.
- Authentication uses Apple's GrandSlam SRP-6a flow. The raw password is used locally to produce the SRP proof and is not sent directly; anisette headers are generated locally with macOS's AOSKit, without an external anisette service.
- Account/session credentials are stored in macOS Keychain. A password is retained for quick login only when **Remember Me** is enabled; non-secret profile metadata and preferences are stored in UserDefaults.
- IPA extraction, patching, signing, static analysis, report generation, and security-test data processing happen locally. Certificates, provisioning profiles, and IPA contents are not uploaded by ipaverse.
- GitHub is contacted only for an explicit update check and for on-demand Frida downloads. Installing optional tools contacts Homebrew, pip, or the selected vendor site. These requests do not include Apple credentials, certificates, profiles, or IPA contents.
- The project has no project-operated authentication relay, analytics service, or telemetry backend.

Please report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

<br>

## License

The original ipaverse source code in this repository is provided under the [MIT License](LICENSE). Distributed builds also contain or load third-party components whose own license terms continue to apply; the app as distributed should not be described as MIT-only.

Notable components include:

- [Unicorn Engine](https://github.com/unicorn-engine/unicorn) 2.1.4 is statically linked for the App Store signing challenge and is distributed under **GPL-2.0**. See its [license](ipaverse/Vendor/unicorn/LICENSE) and [build notes](ipaverse/Vendor/unicorn/README.md).
- The bundled USB compatibility libraries use [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) and related libraries under **LGPL-2.1-or-later**, plus OpenSSL under Apache-2.0. See the [component notes and source references](ipaverse/Vendor/libimobiledevice/README.md).
- [Frida](https://frida.re) Gadget and core binaries are downloaded on demand under the **wxWindows Library Licence 3.1**. The repository keeps Frida headers/license notices and ipaverse's integration scripts/metadata. See the [Gadget notes](ipaverse/Vendor/frida/README.md) and [frida-core notes](ipaverse/Vendor/frida-core/README.md).

<div align="center">
<sub>bahattinkoc/ipaverse</sub>
</div>
