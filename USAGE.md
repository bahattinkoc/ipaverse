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

Each result shows platform badges and minimum OS requirements before you download, and the app detail screen shows the full version history available for redownload.

<br>

## Downloaded library

Everything you've downloaded, imported, resigned, or dumped lives in one list.

- **Import** any `.ipa` you already have by dragging it onto the window.
- Per-app actions: show in Finder, **Edit & Resign**, install to a device, run a [Security Scan](#security-testing), [dump a decrypted copy](#security-testing) (requires **Evil Mode**), or delete.
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
- Pick a `.mobileprovision` profile and a matching certificate; ipaverse warns if none of your local certificates are authorized by the profile.
- **Move to New Identity** — reads the new bundle ID / App Group from the selected provisioning profile, finds every other config file referencing the old identifiers, and rewrites them for you. Requires **Evil Mode** (see [Security Testing](#security-testing)).
- If the binary is still FairPlay-encrypted, ipaverse warns that the signed result will likely fail to launch — you can override, but see [Security Testing](#security-testing) for how to get a decrypted copy first.
- Optional **Security Testing Mode** and **Inject Frida Gadget** toggles for authorized pentesting — both require **Evil Mode** to be switched on (see below).
- The signed IPA is automatically added to your [Downloaded library](#downloaded-library), tagged `Resigned`.

<br>

## Install to device

Push a re-signed IPA straight to a connected iPhone, iPad, or Apple TV — over USB or Wi-Fi.

- Pair the device once over cable, then enable **Connect via network** in Xcode → Devices to install wirelessly afterward.
- Each device in the list shows its connection type (USB/Wi-Fi), model, and iOS version; devices that don't meet the app's minimum iOS version are grayed out.
- If the app was downloaded under a different Apple ID than the one currently active, ipaverse warns before installing — a FairPlay-bound app will crash on launch under the wrong account — and requires you to explicitly confirm "Install Anyway".

<br>

## Security Testing

ipaverse includes a small toolkit aimed at security researchers doing **authorized** iOS app testing (bug bounty programs, contracted pentests, or testing your own apps) — not general sideloading. All of it lives in the Re-sign and Downloaded screens. None of it is bundled into ipaverse.app itself (it would otherwise roughly double the download size) — Frida's components are downloaded once, on first use, and cached locally.

> ⚠️ **Educational and authorized use only.** These tools exist to help you test apps you own or are explicitly authorized to test. Do not use them against any app, account, or system you don't have permission to test — doing so may violate Apple's terms of service and/or the law. ipaverse and its author take no responsibility for misuse.

### Evil Mode

The tools below that actually change or extract app behavior — **Security Testing Mode**, **Inject Frida Gadget**, **Dump Decrypted Copy**, and **Move to New Identity** in the Re-sign window — are disabled by default. Turn on **Evil Mode** to unlock them: click the flame icon in the main window's toolbar. While it's on, the flame shows filled/red and a small "· Evil Mode" label appears next to the app name in the main window's footer, so it's always obvious when these are active. Toggle it off again to re-lock everything. **Security Scan** doesn't change anything and is always available, on or off.

- **Security Testing Mode** *(Evil Mode)* — one toggle that disables ATS (`NSAllowsArbitraryLoads`) on the signed build so a MITM proxy (Burp, mitmproxy) can intercept its traffic. Every re-signed build is also always debuggable (`get-task-allow`). This does **not** bypass in-app certificate/public-key pinning — that's enforced in the app's own code, independent of ATS.
- **Inject Frida Gadget** *(Evil Mode)* — patches the app's main binary to load a bundled [Frida](https://frida.re) Gadget at launch, so you can attach with `frida -H <device-ip>:27042 -n Gadget` (or [objection](https://github.com/sensepost/objection)) and instrument it — including bypassing pinning — on a **non-jailbroken** device. No `frida-server`/root needed, since the agent runs in-process.
- **Security Scan** *(always available)* — a static scan of an IPA that surfaces severity-graded findings (critical/high/medium/low/info) with title, category, file location, and code snippet — hardcoded secrets and keys, ATS misconfiguration, insecure storage patterns, and similar issues. Found values are redacted by default (toggle "Reveal values" to see them) and the full report can be exported as Markdown or JSON.
- **Dump Decrypted Copy** *(Evil Mode)* — for a real App Store IPA (which is FairPlay-encrypted even when the app is free), this reads the already-decrypted binary out of a *running* instance of the app on a **jailbroken** source device you control, and patches that into a DRM-free copy you can then re-sign and test on a separate, non-jailbroken target device. This is the same technique tools like `frida-ios-dump` use: it captures memory the OS already decrypted to execute the app, rather than breaking FairPlay's cryptography. The target app needs to actually be open on the source device — if it lazily loads a framework you need dumped, trigger that code path first or the dump for that framework will fail.

None of this replaces getting proper authorization before testing an app you don't own.

<br>

## Settings

- **Account** — profile summary, App Store region/storefront picker, sign out.
- **Downloads** — where IPAs are saved, and whether they're kept as `.ipa` or `.zip`.
- **Search** — result limit (5/50/100/200), search-history toggle, and a "Clear Search History" action.
- **About** — app version and third-party credits/licenses.
