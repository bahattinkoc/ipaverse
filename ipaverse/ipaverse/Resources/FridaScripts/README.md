# Frida Toolkit scripts — generated resources

`ssl-pinning-bypass.js` has no bridge dependency. All resources in this directory
are generated from committed sources under `tools/frida/src`. See the
[build guide](../../../../tools/frida/README.md).

`jailbreak-detection-bypass.js`, `biometric-bypass.js`,
`class-method-tracer.js`, `userdefaults-dump.js`, `keychain-dump.js`,
`sandbox-files.js`, `network-request-logger.js`, and `ui-hierarchy-dump.js`
are **compiled output**, not source you should edit directly — they're
`frida-compile`'d IIFE bundles that inline the full `frida-objc-bridge`
package (~49-51KB each, mostly duplicated bridge code).

Recurring gotcha across these: `ObjC.Object` has **no `.isNull()` method**
(that's `NativePointer`'s API) — an Obj-C `nil` return from a bridged method
call (e.g. `dict.objectForKey_(missingKey)`, `enumerator.nextObject()` past
the last entry) converts to plain JS `null`, not to a "null-wrapping"
`ObjC.Object`. Check with `if (!obj)` / `while ((x = ...) !== null)`, never
`.isNull()`, on anything that came back from a normal bridge method call.

**The three Data Dump scripts (`userdefaults-dump.js`, `keychain-dump.js`,
`sandbox-files.js`) send structured `dump-entry` messages, not free text**
— `{"type":"dump-entry","category":"...","fields":[{"k":"...","v":"..."}]}`
(one `k`/`v` pair for userdefaults-dump, several per Keychain item/sandbox
file). `DataDumpView`/`FridaToolkitVM.DumpEntry` render this as an actual
key/value layout instead of a wall of "[script-name] key = value" log
lines, and `exportDumpText()`/`exportDumpJSON()` save the full parsed
content to a file (not just what's scrolled into view) — the same
NSSavePanel pattern `SecurityScanVM` already uses for its report exports.
This was a mechanical restructuring of already-shipped, already-working
logic (same NSUserDefaults/`SecItemCopyMatching`/`NSFileManager` calls, just
wrapped in `send({...})` object literals instead of `send(string)`) —
re-verified end-to-end anyway, all three, against real local data (a test
process's own `UserDefaults`, this Mac's real system Keychain, real `.plist`
files under `$HOME`) via `ObjC.schedule`-free `attach`-to-already-running-
process mode, since `frida_device_spawn_sync` had stopped working reliably
in this environment that session (see `frida_device_spawn_sync`'s known
GUI-process caveat elsewhere in this file — this instance affected even a
plain CLI test target, and turned out to be dozens of stale
`~/.cache/frida/*/frida-helper` processes accumulated over the session;
clearing those, or just attaching to an already-running process instead of
spawning one, both sidestep it).

**`userdefaults-dump.js`'s entries render as a real `Table`** (resizable,
draggable columns, click-to-sort) in `DataDumpView`, since it's the one
Data Dump script where every entry is exactly one key=value pair —
detected structurally (`DumpEntry.fields.count == 1` for every entry), not
by script id, so any future single-field-per-entry Data Dump script gets
the same table automatically. keychain-dump/sandbox-files keep the grouped
list layout instead, since their entries carry several named fields each
(account/service/server/label, or path/size) that don't fit a two-column
table the same way.

**`userdefaults-dump.js` can also write a value back to the device** —
`{"type":"write-userdefault","key":"...","value":"...","valueType":"string"|"number","requestId":"..."}`
in, `{"type":"value-updated","requestId":"...","key":"...","value":"...","success":true}`
(or `success:false`+`error`) out, via a re-armed `recv('write-userdefault',
...)` listener (same pattern as everything else in this file that holds a
request open). Each entry now also reports `editable` (true only for a
plain `NSString`/`NSNumber` value — checked via `isKindOfClass_`, which
correctly matches the private concrete subclasses NSUserDefaults values
actually are, e.g. `__NSCFString`/`__NSCFNumber`, since those are real
subclasses of the public `NSString`/`NSNumber` classes) and `valueType`
("string" or "number") so the write path knows whether to construct an
`NSString` or an `NSNumber` — deliberately **not** attempting to write back
an `NSArray`/`NSDictionary`/`NSData`/etc. as a string, since that would
silently change the value's real type. `FridaToolkitVM.updateUserDefault`
does the request/reply dance and optimistically updates the local
`DumpEntry` on success; `DataDumpView`'s Value column shows a live-editable
`TextField` for editable entries — **gated behind Evil Mode** (`@AppStorage
("evilModeEnabled")`), since writing to the device changes the target app's
actual running state, the same class of action as Security Testing Mode/
Frida Gadget injection/Move to New Identity/Dump Decrypted Copy elsewhere in
ipaverse. Verified end-to-end before shipping: wrote both a number
(`loginCount` → `99`) and a string (`username` → `"changed-value"`) through
the real message shape, then read each back directly from the same live
`NSUserDefaults` instance to confirm not just that the value changed but
that it kept its **original Objective-C class** (`__NSCFNumber`/
`__NSCFString` respectively) — not silently downgraded to a string either
way. (Separately, worth remembering if the exact bool/int distinction ever
matters: NSUserDefaults's convenience getters — `boolForKey:`,
`integerForKey:`, `doubleForKey:` — tolerate *any* NSNumber variant
regardless of which constructor created it, and even tolerate a plain
NSString value in some cases per Apple's own documented plist-compatibility
behavior, so under-specifying "was this originally a bool vs. an int" was
judged low-risk enough not to attempt distinguishing.)

**`sandbox-files.js` can also read a file's real bytes back to the Mac**,
on request — `{"type":"read-file","path":"...","requestId":"..."}` in,
`{"type":"file-content","requestId":"...","base64":"...","size":...}` (or
`{"error":"..."}`) out, via a re-armed `recv('read-file', ...)` listener
(same pattern as the network logger's `set-intercept`/UI Hierarchy's
`highlight-view`). `FridaToolkitVM.downloadSandboxFile(path:completion:)`
sends the request and resolves the completion when the reply arrives;
`DataDumpView`'s per-row Download button (shown only for entries with a
`path` field, i.e. sandbox-files rows) then shows an `NSSavePanel` and
writes the decoded bytes. Capped at 25MB per file — large enough for the
kind of cache/database files this script already targets, small enough to
not hang the bridge trying to base64-encode and transfer something huge.
Verified end-to-end before shipping: a real local file (including
non-ASCII/UTF-8 content — Turkish characters, an em dash) round-tripped
byte-for-byte through the exact request/response shape above, via the same
attach-mode harness used for the Data Dump restructuring. Requires the
script to still be attached — reading a file is a live, on-demand request
to the running script, not something captured up front during the dump;
`downloadSandboxFile` fails fast with a clear message if it isn't running,
and any request still in flight when Stop is hit is failed explicitly
rather than left hanging forever.

`keychain-dump.js` only returns item *attributes* (account/service/label),
not the secret values — `kSecReturnData` reliably failed with
`errSecParam(-50)` against the exact query shape used here, verified via the
same local-macOS-spawn harness described below. Isolating it (see this
folder's git history / session notes) showed `kSecReturnAttributes` alone
succeeds and `kSecReturnData` alone fails, on both `genp` and `inet` classes,
regardless of whether the real exported `kSec*` symbol constants or string
literals were used for the class value — so it's not a key-identity issue,
just an unresolved platform/query-shape restriction. This was tested on
macOS, which has different Keychain semantics from iOS (code-signing/ACL
Keychain vs. iOS's always-on data-protection Keychain) — it may simply work
on a real iOS target where this was never actually exercised. If picking
this back up: test `kSecReturnData` on a real device before assuming it's
still broken there.

`network-request-logger.js` hooks both `-[NSURLSession dataTaskWithRequest:]`
and `-[NSURLSession dataTaskWithRequest:completionHandler:]` — the request
side is caught at the moment the request object is created (before TLS,
before any custom pinning logic runs, so it captures traffic regardless of
whether pinning is bypassed); the response side, for the completion-handler
overload only, is caught by **wrapping the completion-handler block itself**
via `frida-objc-bridge`'s `ObjC.Block`: `new ObjC.Block(args[3])` wraps the
real block, `.implementation` (read) gives a callable that invokes the real
one, and assigning a new function to `.implementation` overwrites the
block's own invoke pointer in place — so when the OS eventually calls this
exact block object to deliver the response, it calls *our* function first.
The other overload has no such block to wrap, so its response is only ever
visible via the `setState:` fallback described below (status/error only, no
edit). Everything's toggled live from `FridaToolkitVM.interceptEnabled`/
`interceptFilter` (posted together as
`{"type":"set-intercept","enabled":...,"filter":"..."}`, no need to restart
the script).

**Scope filter, Burp-style.** `interceptFilter` is a plain case-insensitive
substring match against the request URL — empty means "match everything"
(the original, pre-filter behavior). The hold/pass-through decision
(`shouldHold(url)` = `interceptEnabled && (filter empty || url contains
filter)`) is made **once, at request time**, and stored per-id
(`heldIds[id]`) — the response phase reuses that same stored decision rather
than re-checking `interceptEnabled`/`interceptFilter` fresh when the
response actually arrives. This matters: a request that didn't match the
filter (or arrived while Intercept was off) never has its response held
either, even if the user changes the filter or flips Intercept on again
before that response comes back — same as Burp, where scope is decided by
the request, not re-evaluated per direction. Verified end-to-end (real
`httpbin.org` calls, local-spawn harness): a non-matching filter passes both
phases straight through with the real status/body untouched; a matching one
holds both, independently editable, exactly as without a filter.

- **Pass-through (Intercept off, or a non-matching filter)**: request logged
  (`request-log`) and let through immediately; response (completion-handler
  overload) logged (`response-log`) and passed to the real callback
  immediately. Zero added latency either way.
- **Held (Intercept on and the filter matches, or the filter is blank)**:
  request sends `request-pending` and blocks on
  `recv('resume-req-' + id, ...).wait()` until `resolvePendingRequest` posts
  `resume-req-<id>` — Forward (edited method/URL/headers/body rewritten onto
  a mutable copy via `args[2] = mutable`) or Drop (redirected to a dead host
  — see limitation below). Independently, the response (completion-handler
  overload) sends `response-pending` and blocks on
  `recv('resume-resp-' + id, ...).wait()` until `resolvePendingResponse`
  posts `resume-resp-<id>` — Forward (edited status/headers/body,
  reconstructed as a real `NSHTTPURLResponse` + `NSData` and handed to the
  *real* completion handler) or Drop (the real handler is called with
  `NSError(domain: NSURLErrorDomain, code: -999)` — a real "cancelled" error
  the app's own error-handling path will see, not a silent no-op either).

All of the above — request pause/edit/resume, the mutated request reaching
the real destination, response pause/edit/resume via block-wrapping, the
*app's own callback* receiving the edited status/body (not just a cosmetic
log), and response-drop delivering a real NSError — were verified
end-to-end against real `httpbin.org` calls in the local-spawn harness, not
just the offline ObjC-bridge checks used for the other scripts here (a
Foundation binary's own `print()` of what its completion handler received
was checked against what was actually sent — e.g. edited status 201 arriving
in place of the real 418). Accepted limitations, by design rather than
oversight:

- **Drop isn't a true no-op** for either phase. `Interceptor.attach`'s
  `onEnter` can rewrite the request's arguments but can't skip the call
  outright (`Interceptor.replace` could, but was judged too risky to get
  right this session — a broken replacement can crash the app under test),
  so request-Drop redirects to `https://0.0.0.0.ipaverse-dropped.invalid/`
  and response-Drop calls the real handler with a cancelled-request NSError
  — both fail harmlessly rather than truly never having happened.
- **A request/response left held when Stop is hit is safe for ipaverse,
  not necessarily for the target app.** Verified `frida_script_unload_sync`
  + `frida_session_detach_sync` both return in ~15ms even with a phase stuck
  in `recv().wait()` — so hitting Stop never hangs ipaverse itself — but the
  specific native thread blocked inside the target app has no verified
  graceful unblock in that case. Forward or Drop before hitting Stop where
  possible.
- **Response holding only works for the completion-handler overload.** The
  plain `dataTaskWithRequest:` overload (no completion handler — the caller
  gets the response via `URLSessionDataDelegate` methods instead) has no
  block to wrap; its response only ever shows up via the `setState:`
  fallback (status/error, read-only, whether or not Intercept is on).

Only the two `dataTaskWithRequest:` selectors are hooked — code using
`URLSession.shared.data(for:)` (async/await) or a delegate-based session
built differently would need additional selectors if this turns out to miss
traffic on a real app.

`ui-hierarchy-dump.js` recursively walks every window's `subviews()` off
`UIApplication.sharedApplication().windows()`, sending back one structured
`ui-window` message per window (a nested JSON tree — class, frame,
`isHidden`, accessibility identifier/label, and type-specific detail: a
label/button's text, a WKWebView's URL, and — the sharpest one — a text
field's **real** value even when it's a secure field showing dots on
screen, since `UITextField.text` holds the plaintext regardless of
`isSecureTextEntry`; that flag only controls rendering). This replaced an
earlier v1 that just printed the private `recursiveDescription()` API's raw
text — confirmed working against a real device this session, which is what
prompted rebuilding it as a real structured/collapsible tree instead of
just reformatting that same text dump.

The walking/decoding *mechanics* were verified empirically before shipping,
against a real running process — just not a UIKit one, since this Mac has
none. AppKit's `NSView` is close enough of a proxy for validating the parts
that are actually novel here (same ObjC runtime, same `frida-objc-bridge`,
same struct-return marshaling): a local test target created an `NSWindow`
with a nested `NSTextField`, an `NSSecureTextField` holding a known string,
a hidden `NSView`, and accessibility identifiers/labels set on them; Frida
was attached to the already-running process (**not spawned** — spawning a
GUI/AppKit process via `frida_device_spawn_sync` reliably killed it before
the script could even load, "the connection is closed" — almost certainly
the WindowServer-connection-while-suspended problem that's a known category
of issue for debugger-attached GUI apps on macOS; attaching to an
already-launched instance instead worked cleanly) and a walker script
confirmed: (1) `view.frame()` — a struct-returning method — comes back from
the bridge as a **plain nested array** `[[x,y],[w,h]]`, not `{origin:
{x,y}, size: {w,h}}` as named-property access would suggest and as a first
attempt assumed; that attempt's `frame.origin.x`-style access silently
returned `undefined` instead of throwing, which is exactly the kind of bug
this session's "verify before trusting" discipline exists to catch. Fixed
by indexing `f[0][0]`/`f[0][1]`/`f[1][0]`/`f[1][1]`. (2) `subviews()` walks
correctly and finds every descendant, arbitrarily nested. (3)
`accessibilityIdentifier()`/`accessibilityLabel()` read correctly. (4) —
the actual payoff — reading `NSSecureTextField.stringValue()` (the AppKit
equivalent of `UITextField.text`) returned the real string set on it, not
the masked/dot representation, confirming the "read a secure field's real
value through the bridge" technique works exactly as expected. The
UIKit-only class/selector names used in the shipped script
(`UITextField`/`UILabel`/`UIButton`/`WKWebView`, `isSecureTextEntry`,
`currentTitle`) are standard, well-documented Apple API — high confidence,
but not independently confirmed on-device the way the mechanics above were.

**Live highlight, added the same day the user first confirmed a real device
dump worked** ("how do we make this better?"). Every node gets a `viewId`
the script keeps a live reference to (`viewRegistry`) for the life of the
run, so a `highlight-view` message can flash that exact view's real
`backgroundColor` red on the device for ~1.2s, then restore it — a re-armed
listener, same pattern as the network logger's `set-intercept`. Deliberately
avoids `CALayer`/`CGColor` (setting `layer.borderColor` would mean
marshaling a `CGColorRef` — a Core Foundation type, not a real
`NSObject`/`isa`-bearing instance the bridge handles the same way as
everything else here — an unvalidated mechanism not worth adding just for a
nicer-looking border) in favor of a plain object property get/set, exactly
like dozens of other calls already proven this session. `viewRegistry`
holding a live pointer across messages is a real, openly-documented risk
(in the script's own top comment): if the screen has changed since the
dump, the view may be deallocated, and messaging a dangling pointer can
crash the target app — no way to fully rule this out from the host side, so
treat Highlight as safe shortly after a fresh dump, not indefinitely.

**A screenshot-preview mode (a captured PNG of the window with a box drawn
over the tapped element) was built, shipped, and then removed** after the
user reported it didn't actually work on a real device, asked to drop it,
and keep just the highlight. Worth remembering *why* it looked solid before
that report: three real mechanisms it depended on — constructing a
`CGRect` to *pass into* `UIGraphicsImageRenderer`'s `initWithBounds:`
(struct-as-*argument*, the opposite direction from every earlier
struct-as-*return* validation — confirmed via
`view.setFrame_([[100,200],[50,60]])` then reading `.frame()` back and
matching), scheduling the render on `ObjC.mainQueue` (a first attempt
calling AppKit's `cacheDisplayInRect:toBitmapImageRep:` directly hung until
Frida's own script-load watchdog killed it — `ObjC.schedule(ObjC.mainQueue,
...)` fixed it instantly, real PNG bytes confirmed by decoding the base64
output's magic-byte signature), and passing a *freshly-constructed*
`ObjC.Block` as a method argument (confirmed via
`-[NSOperationQueue addOperationWithBlock:]`, since reading
frida-objc-bridge's own `toNativeBlock` source suggested it might not
auto-unwrap a `Block` instance's `.handle`, but Frida's generic
pointer-argument coercion accepts anything with a `.handle` property
regardless) — were each independently verified against a real running
*AppKit* process (this Mac has no UIKit) before being combined into the
real UIKit script. All three checked out. **The AppKit proxy strategy that
worked for every other UIKit-only mechanism this session apparently wasn't
a reliable enough stand-in for whatever went wrong on a real device here**
— exactly which piece failed (rendering itself, the base64 transfer size,
the SwiftUI-side crop/overlay math) was never diagnosed, since the fix was
just to remove the feature rather than debug it blind. If picking screenshot
preview back up: get a real device in the loop for at least the first
attempt rather than trusting the AppKit-proxy-then-ship pattern again — it
clearly has a gap for at least the render-and-transfer path.

## Why

As of Frida 17.0.0, `ObjC`/`Java`/`Swift` are no longer bare globals in a
script — https://frida.re/docs/bridges/ confirms bridges are only bundled
automatically for the REPL and `frida-trace`, for backward compatibility.
Every other script has to `import ObjC from 'frida-objc-bridge'`.

But `FridaScriptRunner.swift` creates scripts via the raw
`frida_session_create_script_sync` C API with a plain source string, which —
verified empirically against this project's own vendored `libfrida-core.dylib`
(spawn a local macOS process, attach, try `import`) — parses as a **classic**
script, not an ES module: `import` fails with `SyntaxError: expecting '('`,
and `frida_session_compile_script_sync` (the other candidate API) rejects the
same `import` with the identical error. There's no ScriptOptions flag for
module mode. So the only working path found was doing the ESM→classic bundling
`frida-compile` does, once, ahead of time, and shipping the *result*.

Also fixed in the same investigation: `Module.findExportByName` doesn't exist
in this Frida version either — it's `Module.findGlobalExportByName(name)` for
searching all modules, or `Process.getModuleByName(name).findExportByName(...)`
for a specific one. `ssl-pinning-bypass.js` and the bundled scripts already
use the new names.

## Regenerating a bundled script

From the repository root:

```sh
npm ci --prefix tools/frida --ignore-scripts --no-audit --no-fund
npm run build --prefix tools/frida
npm run check --prefix tools/frida
```

Edit `tools/frida/src/*.js`. The frozen 2.4 bridge/bootstrap fragments have
checksums in `tools/frida/manifest.json`; the original bridge package version
is unknown. See the [source recovery and build notes](../../../../tools/frida/README.md).

The runtime observations above describe earlier versions. The 2.5 build checks
do not launch a process or validate live Frida behavior. The network logger now
omits bodies larger than 32 KiB from IPC, retains the original NSData for forwarding,
and accepts a `continue` action that resumes a held phase without rewriting it.
The host retains up to 500 exchanges, preserves already-held exchanges, and
resumes excess or oversized captures unchanged. Validate these changes manually
on an authorized target before release, including Forward/Drop/Stop and disconnect.
