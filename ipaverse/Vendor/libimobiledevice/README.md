# libimobiledevice — bundled dylib chain

- **Source**: [libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) 1.4.0, obtained via Homebrew's precompiled bottles (macOS arm64) rather than built from source.
- **License**: LGPL-2.1-or-later (see [`LICENSE`](LICENSE)). Its dependencies (`libplist`, `libusbmuxd`, `libimobiledevice-glue`) are similarly LGPL-2.1-or-later; OpenSSL (`libssl`/`libcrypto`) is Apache License 2.0. Dynamic loading (dlopen, see below) rather than static linking is a deliberate choice partly because it keeps LGPL compliance simple — the library can be swapped out independently of ipaverse itself, which is exactly what LGPL's linking provision is about.

## What it's for

Backs `Services/ClassicDeviceInstaller.swift`, a fallback used when Apple's own
`xcrun devicectl` (the normal path in `Services/DeviceInstaller.swift`) can't
install to a device — which happens for **any device on iOS 16 or earlier**,
since `devicectl`'s live tunnel mechanism (RemoteXPC/CoreDevice) is an iOS
17+-only feature. For older devices, ipaverse falls back to the classic
`usbmuxd` → `lockdownd` → `AFC` → `installation_proxy` protocol stack that
tools like libimobiledevice, Sideloadly, and AltServer have used for years.

## Why bundled directly (not lazy-downloaded like Frida)

The whole chain is ~6MB — negligible next to Unicorn's already-bundled 1.5MB,
and nowhere near Frida's ~140MB (see `Vendor/frida`/`Vendor/frida-core`,
which *are* downloaded on first use for exactly that size reason). This is
also a mainstream compatibility feature, not an opt-in security-testing tool,
so it should work offline on first launch rather than requiring a network
fetch.

## Files

Each `.dylib` is renamed to `.dylib.bin` before being placed in the app
target's synchronized source folder (`ipaverse/ipaverse/Vendor/LibIMobileDevice/`),
so Xcode's build system treats it as opaque resource data rather than
something to link/embed — same trick used for the Frida Gadget. At runtime,
`ClassicDeviceInstaller` `dlopen()`s `libimobiledevice-1.0.6.dylib.bin`
straight out of `Bundle.main`; its dependencies resolve automatically because
every file's install name and inter-references were rewritten to
`@loader_path/...` (see Updating below) and they all land together in
`Contents/Resources/`.

Chain: `libimobiledevice` → `libssl`/`libcrypto` (OpenSSL, for the TLS pairing
session), `libusbmuxd` (talks to the system `usbmuxd` daemon), `libimobiledevice-glue`,
`libplist` (Apple binary/XML plist parsing).

## Code signing note

Homebrew's bottled dylibs carry Homebrew's own signature, which doesn't
survive `install_name_tool` rewriting (it re-applies a plain ad-hoc signature
with no Team ID). Since ipaverse runs under Hardened Runtime, loading dylibs
signed by a different Team ID than ipaverse's own would normally be refused —
this is why `ipaverse.entitlements` carries
`com.apple.security.cs.disable-library-validation` (see the comment there).

## Updating

```bash
brew install libimobiledevice   # pulls in libplist, libusbmuxd, libimobiledevice-glue, openssl@3
# For each of the 6 dylibs (see the paths under /opt/homebrew/opt/<formula>/lib/):
install_name_tool -id "@loader_path/<name>" <file>
install_name_tool -change "<old /opt/homebrew/... path>" "@loader_path/<dep-name>" <file>
# CRITICAL — install_name_tool leaves a stale, invalid signature behind (it
# does NOT re-sign for you, despite `codesign -dv` still showing "adhoc").
# Skipping this makes the kernel SIGKILL the process the moment it's
# dlopen()'d, with no dlerror() message and no crash report to explain why:
codesign --force --sign - <file>
codesign --verify --strict <file>   # must say "valid on disk" before shipping
```
Then copy the results into `ipaverse/ipaverse/Vendor/LibIMobileDevice/` with a
`.bin` suffix, replacing the old version, and update the filenames referenced
in `Services/ClassicDeviceInstaller.swift` if the version-suffixed names
changed (e.g. `libimobiledevice-1.0.6.dylib` → `-1.0.7.dylib`).
