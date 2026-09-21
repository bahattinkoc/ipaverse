# App Store download responses

## macOS package preparation

Native Mac App Store downloads can contain encrypted package bytes. Validating
those bytes as a plain XAR archive rejects a complete download. The Mac path now
retains `sinfs[].dpInfo` and decodes the exact GUID used for the download metadata
request into the hardware ID. Missing or conflicting decryption metadata is
rejected before downloading; explicit `software-platform=macos` takes precedence
over a universal app's `product-type=ios-app` classification.

After transfer, an isolated SAP runtime loads Apple's StoreAgent alongside the
existing CommerceKit/CoreFP assets. StoreAgent comes from the same Apple update
payload, is cached separately, and is checked against a pinned size and SHA-256
both when loaded and before emulation. Its extra synchronization shims are enabled
only for this runtime. Apple binaries are downloaded from Apple, not bundled.

The package is decrypted in full 32 KiB blocks plus a final partial block, with
cancellation checks between blocks. The session and files must close successfully,
then libxar validates the TOC and entry checksums without extracting or executing
the installer. Only then does the existing atomic save replace the destination.
Failures remove staging files and preserve the previous package. Mac packages do
not pass through the IPA patcher, and dpInfo/SINF values are redacted from logs.

This ports the relevant package preparation flow from
[IPAtool's macOS downloader](https://github.com/majd/ipatool/blob/main/pkg/appstore/appstore_download_macos.go),
[StoreAgent runtime](https://github.com/majd/ipatool/blob/main/internal/sap/machine/storeagent.go), and
[pinned asset profile](https://github.com/majd/ipatool/blob/main/internal/sap/assets/storeagent.go).
Its MIT notice is included in the app's ThirdPartyNotices resources.

`MacPackageTests` covers metadata/identity handling, image verification, short
reads and final blocks, cancellation, corrupt/truncated XARs, atomic publication,
and preservation on decryption, close, and validation failures. Fixtures use a
synthetic reversible transform for package bytes; they do not prove a live Apple
package can be decrypted. Live latest/historical RocketSim and SimKit downloads
remain a manual validation step. This change does not implement unrelated IPAtool
features or automatic fallback from a Mac selection to an iOS package.

## Saved formats

Settings keeps separate preferences for iOS/iPadOS/tvOS/visionOS (`.ipa`, `.zip`)
and macOS (`.pkg`, `.app`, `.zip`). Existing mobile preferences are preserved;
the new Mac preference defaults to `.pkg`, matching previous behavior. Both the
single-download save panel and batch downloads use these preferences. A queued
job's destination extension fixes its format, so changing Settings does not change
pending jobs or retries.

For macOS `.app` and `.zip`, the decrypted, verified package is expanded with
`pkgutil --expand-full` in a temporary workspace. No installer scripts run. The
exporter selects one outer application matching the requested bundle ID; nested
helpers stay inside their application. Ambiguous or missing apps are rejected.
Internal symbolic links and executable permissions are preserved; links outside
the bundle are rejected. A Mac `.zip` contains the extracted `.app`, not a renamed
installer. On the other platforms, `.ipa` and `.zip` are the same patched ZIP
archive with different extensions.

An extracted `.app` replaces the destination atomically, including an existing
nonempty app bundle. Library metadata uses the extracted app's version, actual
file sizes, and a deterministic bundle hash. Its context menu offers **Show
Package Contents**, which opens the Contents folder in Finder without launching
the application. IPA-specific editing and installation actions remain limited to
IPA-compatible downloads.

`MacPackageExportTests` uses synthetic installers to exercise all three Mac
outputs, preservation of executable permissions and links, installer-script
nonexecution, bundle selection, atomic replacement, cancellation, and migration
of older settings.

## Metadata requests

Downloading, version listing and version metadata share `AppStoreDownloadProduct`.
The primary request remains the account pod's `volumeStoreDownloadProduct`, with
`serialNumber: "0"` and `externalVersionId` when the user selects a version.

An HTTP 200 response with an explicitly empty `songList` and no Apple error is
not proof of a missing license or an expired login. This includes the reported
`purchaseSuccess`, `status: 0`, `authorized: false`, queue count 1 response.
In this case only, the client resolves `urlBag.redownloadProduct` from Apple's
`bag.xml` and makes one fallback request. Only the HTTPS
`downloaddispatch.itunes.apple.com/r/redownload` endpoint is accepted. The
fallback preserves the account headers, cookies, app ID and GUID, and translates
the selected version to `appExtVrsId` so it does not silently download the latest.

If that unpinned redownload returns HTTP 500 with a zero-byte body, latest-version
iOS/iPadOS requests resolve the current external version ID from Apple's public
MDM catalog for the account's country. One version-pinned redownload supplies `appExtVrsId`.
The catalog request uses `platform=enterprisestore` and verifies the requested app
ID and a positive numeric external version ID (from `offers[0].version.externalId`
or `buyParams`). Unknown account regions and missing catalog versions stop the
operation. Explicit historical versions, other platforms, primary HTTP errors,
nonempty 500 responses and other HTTP statuses never trigger this catalog retry.

The subsequent Turkcell report confirmed that even the correct catalog ID can
return an empty HTTP 500. For a pinned iOS/iPadOS redownload with this exact
response, one request to the same bag's `updateProduct` is now allowed. This also
applies to explicit historical versions, without changing their ID. The endpoint
must be exactly HTTPS `downloaddispatch.itunes.apple.com/up/updateProduct`, with no
port, user info, query, fragment or escaped path; only the current GUID is added.
Headers, session and plist body are preserved. The response must contain exactly
one item whose metadata matches the app ID, external version ID and bundle ID.
Missing or mismatched identity is rejected before downloading. Missing update
endpoints preserve the redownload error; update failures stop without another
fallback. Other platforms never use this update path.

Explicit Apple failures and other HTTP errors are surfaced without this fallback.
Only Apple's license-required code 9610 triggers the existing purchase flow;
paid purchases remain unsupported. A second empty response produces a descriptive
error. There is no retry loop, automatic re-login or substitution of selected versions.
Successful metadata is used directly for the file download, removing the previous
duplicate metadata request used as a license probe.

References:

- [ipatool issue 547](https://github.com/majd/ipatool/issues/547): matching empty-success response and reports of a redownload fallback.
- [ipatool issue 538](https://github.com/majd/ipatool/issues/538): original empty-response investigation.
- [ipatool PR 500](https://github.com/majd/ipatool/pull/500): serialNumber request compatibility.
- [ipatool fork commit 741049d](https://github.com/HaughtyEyes/ipatool/commit/741049d90d4c5c8b49aa67a6d022cbf7e901272c): pinned redownload empty-500 fallback to updateProduct and response identity validation.

Run `bash scripts/test-anisette.sh` for the download regression fixtures alongside
the authentication tests. The fixtures cover latest and historical versions,
metadata/SINF preservation, primary success, explicit failures, bounded empty
responses, empty-500 catalog retries, catalog parsing and rejected fallback
destinations. They use synthetic data and do not verify a live Apple account
download. A public TR catalog check on 2026-09-11 returned Turkcell 19.32.0 with
external ID 891009506; this ID is not hardcoded into the client. The reported live
pinned redownload still failed. The new update fallback has fixture coverage for
latest/historical selection, success, bounded HTTP and license failures, unsafe
endpoints and mismatched/ambiguous metadata. A live Turkcell update download has
not yet been verified.

## First-time free app acquisition

Version loading and downloads now share `AppStorePurchase.withLicense`: only
`9610` starts acquisition, then the original operation runs once more with its
selected version unchanged. `AppStorePurchase.acquire` uses the Configurator
`buyProduct` request from IPAtool (`STDQ`, price `0`, appExtVrsId `0`, account
pod/storefront/token/DSID). The app must have a positive ID and a known zero price.
Only error `2059` allows one `GAME` retry, and macOS never uses that retry.

Purchase success requires HTTP 200, `jingleDocType: purchaseSuccess`, an explicit
zero status, and no cancellation/denial. Empty or malformed replies and generic
HTTP 500 responses are no longer treated as success or existing ownership.
Explicit Apple failures take precedence over HTTP errors. `5002` permits one
follow-up license check because IPAtool interprets it as already owned; the
follow-up must actually succeed. Repeated `9610` produces a license-unavailable
error instead of another purchase. Auth errors still ask the user to sign in.

The reported Dijital Etiket response is an explicit `2022` billing rejection,
not a missing purchase call. The comparisons below did not establish a working
alternative for that rejection. These changes fix response handling and exercise
automatic acquisition; they do not demonstrate that this account's billing
rejection is resolved. A live first-time purchase still needs verification.

Research checked on 2026-09-11:

- [IPAtool purchase](https://github.com/majd/ipatool/blob/main/pkg/appstore/appstore_purchase.go): matching request and code-specific Arcade fallback.
- [ipsw purchase](https://github.com/blacktop/ipsw/blob/master/internal/download/appstore.go): requires explicit purchase confirmation and does not assume every HTTP 500 means ownership.
- [ipatool-py](https://github.com/NyaMisty/ipatool-py/blob/master/reqs/store.py): separate Configurator and iTunes purchase flows; the latter depends on an iTunes provider and `kbsync` data, not a standalone alternate URL.
- [Apple billing guidance](https://support.apple.com/tr-tr/118284): a previous-purchase billing problem can block new free app downloads.

`bash scripts/test-anisette.sh` also runs `PurchaseTests`: first-time acquisition
and resumed latest/historical metadata requests, owned apps, ambiguous `5002`,
the reported `2022`, auth errors, bounded retries, HTTP/malformed responses,
paid/unknown-price rejection, and cancellation. All accounts and responses are
synthetic; these fixtures make no live purchases.
