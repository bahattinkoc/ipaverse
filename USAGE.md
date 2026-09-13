# Usage

Full walkthrough of ipaverse's features. For install instructions and the project overview, see the [README](README.md).

## Contents

- [Search & download](#search--download)
- [Downloaded library](#downloaded-library)
- [Multi-account & storefronts](#multi-account--storefronts)
- [Re-signing](#re-signing)
- [Install to device](#install-to-device)
- [Security Testing](#security-testing)
- [Settings](#settings)

<br>

## Search & download

Search the App Store directly from ipaverse — no Xcode, no Apple ID in Terminal.

- Filter by platform: iOS, iPadOS, macOS, tvOS, and visionOS.
- Paste a bundle ID (e.g. `com.example.app`) instead of a name and ipaverse automatically switches to an exact bundle-ID lookup.
- Your last 5 searches are kept for quick re-use; search history can be turned off (and cleared) in [Settings](#settings).
- The number of results per search is configurable in Settings (5 / 50 / 100 / 200).

> visionOS note: Apple's search API doesn't reliably index native visionOS-only apps by name — look those up by exact bundle ID instead.

Each result shows platform badges and minimum OS requirements before you download, and the app detail screen shows the version history available for redownload.

Choose a version and **Add to Queue**, or select several search results with
Command-click and choose **Queue Selected…**. Open **Downloaded → Queue** to see
progress, speed and ETA for up to two concurrent jobs. Downloads continue when
you close the detail window or queue panel.
The detail window also shows the live circular percentage indicator and
downloaded/total size. If the server does not supply a total, the downloaded
size still updates. After the transfer reaches 100%, **Preparing package**
indicates validation and patching; the job completes only when the file is ready.
Jobs wait for their original account and storefront. Interrupted jobs survive an
app restart and can be retried; retry starts a fresh transfer, not a byte-level resume.
Authentication tokens are not stored in the queue journal. A failed transfer or
package preparation preserves an existing destination file. macOS downloads use `.pkg`.

<br>

## Downloaded library

The **Downloaded** screen works without signing in. Its icon list keeps a separate entry for each version and copy. Open the filter menu to filter by source/platform or enable **Group Versions & Copies**.

- **Import** one or more `.ipa` files with Import or drag and drop. Search by name, bundle ID or version. Import and Queue are available above the list.
- Select two copies with Command-click and choose **Compare** below the list for Info.plist, entitlements, frameworks, file hashes/sizes and static-analysis findings. Export the comparison as JSON; configuration values are hidden and finding evidence is fingerprinted.
- **Locate File…** reconnects a moved file after matching its bundle/version or known SHA-256. A different copy should be imported separately.
- **Remove from Library** removes records and leaves files on disk.
- Per-app actions: show in Finder, **Edit & Resign**, install to a device, open [Reverse Engineer](#security-testing), [dump a decrypted copy](#security-testing) (both require **Evil Mode**), or remove its library record.
- Apps produced by ipaverse itself carry a **source tag** — `Resigned` (output of the re-signer) or `Decrypted` (output of the FairPlay dumper) — so you can tell a derivative copy apart from the original download at a glance.
- Imported IPAs aren't tied to an App Store listing, so they can't be redownloaded if deleted — keep your own copy.

<br>

## Multi-account & storefronts

Sign in with as many Apple IDs as you need and switch between them without re-entering credentials.

- Every signed-in account is saved; pick one from the account list for one-tap **quick login** with live sign-in progress.
- Two-factor authentication is handled inline — 6-digit codes auto-submit, with SMS or trusted-device prompts and an explicit resend.
- Signing out keeps the account in your list for one-tap re-login; removing it entirely is a separate, explicit action.
- Change your active App Store storefront/region from a searchable country list (with flags) in [Settings](#settings) — useful for apps only available in certain countries.

<br>

## Re-signing

Re-sign any DRM-free IPA with your own certificate and provisioning profile — in the main window or its own standalone **Resign window** (open it from a Downloaded app's context menu, the toolbar signature icon, the **File → Resign IPA…** menu item (⌘⇧R), or by dropping an `.ipa` straight onto it).

- **Properties** tab — add, edit, or delete Info.plist keys, including boolean toggles.
- **Files** tab — browse the IPA's file tree, replace individual files, or mark frameworks for removal.
- Pick a `.mobileprovision` profile and matching certificate. Before signing, review profile expiration, bundle ID and certificate checks; assign separate profiles to extensions when the main profile cannot cover them. Blocking checks must be resolved.
- Signing preserves the selected profile's `get-task-allow` and push environment, verifies the resulting code signature, and writes to a separate output file.
- **Move to New Identity** — reads the new bundle ID / App Group from the selected provisioning profile, finds every other config file referencing the old identifiers, and rewrites them for you. Requires **Evil Mode** (see [Security Testing](#security-testing)).
- If the binary is still FairPlay-encrypted, ipaverse warns that the signed result will likely fail to launch — you can override, but see [Security Testing](#security-testing) for how to get a decrypted copy first.
- Optional **Security Testing Mode** and **Inject Frida Gadget** toggles for authorized pentesting — both require **Evil Mode** to be switched on (see below).
- The signed IPA is automatically added to your [Downloaded library](#downloaded-library), tagged `Resigned`.

<br>

## Install to device

Push a compatible IPA straight to a connected iPhone or iPad — over USB or Wi-Fi.

- Pair the device once over cable, then enable **Connect via network** in Xcode → Devices to install wirelessly afterward.
- On devices where Apple's CoreDevice path is available, ipaverse uses `xcrun devicectl`. A bundled libimobiledevice backend provides a USB fallback, particularly for devices on iOS/iPadOS 16 and earlier.
- Each device shows its connection, model, and OS version. Readiness checks cover platform, minimum OS, embedded-profile expiry and UDID eligibility before installation. Passing these checks does not establish runtime compatibility.
- An account mismatch warning compares the IPA metadata with ipaverse's active account. ipaverse cannot read or verify the device's App Store account or FairPlay license; the device determines whether the app can launch.

<br>

## Security Testing

ipaverse includes a small toolkit aimed at security researchers doing **authorized** iOS app testing (bug bounty programs, contracted pentests, or testing your own apps) — not general sideloading. It is available from the Re-sign and Downloaded screens. The static scanner, class browser, UI, and scripts ship with ipaverse; the much larger Frida Gadget and core binaries are downloaded once on first use, verified against pinned sizes and SHA-256 digests, and cached locally.

> ⚠️ **Educational and authorized use only.** These tools exist to help you test apps you own or are explicitly authorized to test. Do not use them against any app, account, or system you don't have permission to test — doing so may violate Apple's terms of service and/or the law. ipaverse and its author take no responsibility for misuse.

### Evil Mode

The tools below that actually change, extract, or live-instrument app behavior — **Security Testing Mode**, **Inject Frida Gadget**, **Dump Decrypted Copy**, **Reverse Engineer**, and **Move to New Identity** in the Re-sign window — are disabled by default. Turn on **Evil Mode** to unlock them: click the flame icon in the main window's toolbar. While it's on, the flame shows filled/red and a small "· Evil Mode" label appears next to the app name in the main window's footer, so it's always obvious when these are active. Toggle it off again to re-lock everything.

- **Security Testing Mode** *(Evil Mode)* — one toggle that disables ATS (`NSAllowsArbitraryLoads`) on the signed build so a MITM proxy (Burp, mitmproxy) can intercept its traffic. Debug entitlement (`get-task-allow`) and push environment follow the selected provisioning profile. This does **not** bypass in-app certificate/public-key pinning — that's enforced in the app's own code, independent of ATS.
- **Inject Frida Gadget** *(Evil Mode)* — downloads and caches [Frida](https://frida.re) Gadget if needed, then patches the app's main binary to load it at launch. You can attach with `frida -H <device-ip>:27042 -n Gadget` (or [objection](https://github.com/sensepost/objection)) and instrument the app — including testing pinning bypasses — on a **non-jailbroken** device. No `frida-server`/root is needed because the agent runs in-process.
- **Reverse Engineer** *(Evil Mode)* — a static analysis pass (severity-graded findings, redacted-by-default secrets, manual string search, exportable Markdown/JSON report), an Objective-C class browser, and a live Frida toolkit: bypass scripts, a method tracer, an `NSURLSession` interceptor (pause/edit/forward or drop supported requests and responses), a live UI hierarchy inspector (flash an on-screen element on the device), and app-data tools. NSUserDefaults string/number values are editable in place; the Keychain view lists item metadata without secret values; matching sandbox database/plist files can be downloaded. Live tools attach to a running process through Frida on a connected device or a Gadget-injected app.
- **Dump Decrypted Copy** *(Evil Mode)* — for a real App Store IPA (which is FairPlay-encrypted even when the app is free), this reads the already-decrypted binary out of a *running* instance of the app on a **jailbroken** source device you control, and patches that into a DRM-free copy you can then re-sign and test on a separate, non-jailbroken target device. This is the same technique tools like `frida-ios-dump` use: it captures memory the OS already decrypted to execute the app, rather than breaking FairPlay's cryptography. The target app needs to actually be open on the source device — if it lazily loads a framework you need dumped, trigger that code path first or the dump for that framework will fail.

None of this replaces getting proper authorization before testing an app you don't own.

<br>

## Settings

- **Account** — profile summary, App Store region/storefront picker, sign out.
- **Downloads** — where IPAs are saved, and whether they're kept as `.ipa` or `.zip`.
- **Search** — result limit (5/50/100/200), search-history toggle, and a "Clear Search History" action.
- **Tools** — detect, install, or remove optional disassemblers, MITM proxies, Frida utilities, and device tools through Homebrew/pip; commercial tools open their vendor download page instead.
- **About** — app version, a manual GitHub update check, and a link to the source repository.
