# Vendored Unicorn Engine (static, arm64-only)

`lib/libunicorn.a` is a self-built static archive of [Unicorn
Engine](https://github.com/unicorn-engine/unicorn) 2.1.4, used by
`Services/Auth/SAP/SAPUnicornEngine.swift` to emulate Apple's real x86-64
FairPlay/CommerceKit binaries during App Store login (see the SAP signing
subsystem in `Services/Auth/SAP/`).

## Why vendored instead of `brew install unicorn`

Homebrew's `unicorn` bottle is dynamically linked, arm64-only for this
machine's Homebrew prefix, and built against a much newer macOS SDK than
ipaverse targets (its `LC_BUILD_VERSION` reports minos 26.0, vs. ipaverse's
`MACOSX_DEPLOYMENT_TARGET = 14.6`) — fine for local development, but not
something we can ship inside ipaverse.app for other people to download via
Homebrew Cask, since it requires Homebrew's unicorn to be separately
installed on the end user's Mac at the right path.

This vendored copy is:
- **Static** (`libunicorn.a`) — no runtime dylib dependency, no embedding,
  no code-signing-on-copy step, nothing that can go missing at the user's
  runtime.
- **arm64-only** — ipaverse is Apple Silicon only; see the project's own
  scope decision, no Intel Mac support.
- **x86 emulation only** (`-DUNICORN_ARCH=x86`) — Unicorn supports many
  guest architectures (ARM, MIPS, SPARC, ...); ipaverse only ever emulates
  x86-64, so the rest were excluded, cutting the archive from Unicorn's
  full multi-arch build down to ~1.5 MB.
- Built with `-DCMAKE_OSX_DEPLOYMENT_TARGET=14.6` to match ipaverse exactly.

## How it was built

```sh
brew install cmake pkg-config   # build-time only, not a runtime dependency
git clone --depth 1 --branch 2.1.4 https://github.com/unicorn-engine/unicorn.git src
cd src

# Two small local patches, needed only against very new SDKs (this build
# used the macOS 26 "Tahoe" SDK as the compile-time SDKROOT even though the
# deployment target is 14.6) — neither changes Unicorn's actual behavior:
#   1. qemu/include/qemu/int128.h: the CONFIG_INT128 fallback path
#      typedefs `Int128` to `__int128_t`, which collides with Clang's own
#      builtin __int128 on this SDK. Guarded with `!defined(__SIZEOF_INT128__)`.
#   2. qemu/util/osdep.c: added `#include <sys/mman.h>` (was previously
#      pulled in transitively; stopped being on this SDK).

cmake -S . -B build \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6 \
  -DBUILD_SHARED_LIBS=OFF \
  -DUNICORN_ARCH=x86 \
  -DUNICORN_BUILD_TESTS=OFF \
  -DUNICORN_FUZZ=OFF \
  -DUNICORN_LOGGING=OFF \
  -DCMAKE_C_FLAGS="-include sys/mman.h -DCONFIG_POSIX_MEMALIGN=1" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j 8

cp build/libunicorn.a   <this-directory>/lib/libunicorn.a
cp -R include/unicorn   <this-directory>/include/unicorn
```

To rebuild (e.g. for a newer Unicorn release), repeat the steps above and
replace `lib/libunicorn.a` — the headers in `include/unicorn/` should be
replaced from the same checkout too, in case the API surface changed.

## License

Unicorn Engine is **GPL-2.0** (see `LICENSE` in this directory — copied
verbatim from upstream). ipaverse itself is MIT-licensed and fully open
source (see the repository root `LICENSE`); the combined distributed
binary is subject to GPL-2.0's terms for this component. See the project
root `README.md` for the corresponding notice.
