# frida-core devkit (macOS host) — header vendored, library downloaded

- **Source**: https://github.com/frida/frida/releases/tag/17.17.0
- **Asset**: `frida-core-devkit-17.17.0-macos-arm64.tar.xz` — static library + C header (`include/frida-core.h`) for embedding Frida's host client in a native app.
- **License**: wxWindows Library Licence, Version 3.1 (LGPLv2 + linking exception) — see [`LICENSE`](LICENSE). Same license as [`Vendor/frida`](../frida/README.md) (the target-side Gadget).

## What's actually here

Only `include/frida-core.h` is committed — it costs nothing at build or link
time unless a declaration is actually called, and `Services/FridaDumper.swift`
uses it purely for type/enum declarations (`GError`, `guint`, `gsize`,
`FridaDeviceType`, ...). `HEADER_SEARCH_PATHS` in `project.pbxproj` points at
`include/` for this reason.

The actual `libfrida-core.a` (~220MB static) is **not** committed. Bundling
it — even after dead-stripping — added ~70-100MB to `ipaverse.app`, which
would hit every user, not just the ones using the Dump feature. Instead:

1. It's converted once into a single self-contained dynamic library:
   ```
   clang -dynamiclib -all_load lib/libfrida-core.a \
     -lbsm -ldl -lresolv -lm \
     -framework Foundation -framework CoreFoundation -framework AppKit \
     -install_name "@rpath/libfrida-core.dylib" \
     -o libfrida-core.dylib
   ```
2. That `.dylib` (~99MB) is uploaded as a GitHub Release asset on this repo (tag `frida-deps-17.17.0`).
3. At runtime, `Services/FridaRuntime.swift` downloads it on first use of "Dump Decrypted Copy" and caches it at `~/Library/Application Support/ipaverse/Frida/libfrida-core.dylib`.
4. `Services/FridaDumper.swift` `dlopen()`s that cached file and resolves every `frida_*`/`g_*` symbol it needs via `dlsym` — none of them are called directly by name, so nothing here is ever statically linked into `ipaverse.app`.

## What it's for

Backs `Services/FridaDumper.swift`'s "Dump Decrypted Copy" feature: attaches
to a **running** instance of the target app on a **jailbroken** iOS device
over USB, injects a small JS agent that reads the already-decrypted `__TEXT`
bytes for its main image out of live memory, then patches those bytes into
the on-disk IPA and flips its `LC_ENCRYPTION_INFO(_64).cryptid` to 0. This is
the same technique `frida-ios-dump` uses — it captures memory the OS already
decrypted for execution rather than breaking FairPlay's cryptography. See the
main [README](../../../README.md) for how this fits into ipaverse's security
testing feature set and its authorized-use framing.

## Updating

1. Download the new `frida-core-devkit-<version>-macos-arm64.tar.xz`, extract it, and replace `include/frida-core.h` here.
2. Rebuild `libfrida-core.dylib` from the new `lib/libfrida-core.a` using the `clang -dynamiclib` command above (keep the `.a` locally for this — don't commit it).
3. Upload the new dylib alongside a matching `Vendor/frida` Gadget build on a new `frida-deps-<version>` release.
4. Bump `FridaRuntime.version` to match.
