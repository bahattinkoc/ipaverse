# Frida script sources

Edit `src/*.js`, then run from the repository root:

```sh
npm ci --prefix tools/frida --ignore-scripts --no-audit --no-fund
npm run build --prefix tools/frida
npm run check --prefix tools/frida
```

Commit the source, lockfile, and generated files under
`ipaverse/ipaverse/Resources/FridaScripts` together. Node 22 is used in CI.
`check` parses every generated script, verifies bridge checksums and the tracer
placeholder, and checks byte-for-byte reproducibility. It does not execute a
script, load Frida, launch a process, attach to a target, or access a device.

The original editable sources were missing from 2.4. The 2.5 sources were
recovered from the final application initializer in each shipped IIFE using
Acorn, then formatted with Prettier. Bootstrap symbol names are retained to
avoid an unverified rewrite. During extraction, the complete normalized AST
of all nine rebuilt scripts was compared with git `01600e3` and was identical.
The subsequent network capture changes intentionally change that script.

`vendor/*.js` contains the exact bridge/bootstrap fragments from those 2.4
bundles, rather than downloading a guessed bridge version. Their SHA-256 and
the original script SHA-256 are recorded in `manifest.json`. The original npm
bridge version is unknown. These fragments retain the existing third-party
code; see the project's [third-party license overview](../../README.md#license).
Acorn and Prettier are development-only dependencies pinned in the lockfile.

Changing a vendor fragment is a separate runtime upgrade: identify its upstream
version/license, update the manifest, and validate bridge behavior manually on
an authorized target. Formatting and syntax checks cannot establish runtime
compatibility. Live Frida, UIKit, intercept Forward/Drop/Stop, large-body
pass-through, and device disconnect checks remain manual.
