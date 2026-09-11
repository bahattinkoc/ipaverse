# Anisette sign-in options

Sign in normally; no method selection is needed. The default, **Automatic**, tries
AOSKit on this Mac and falls back to the configured Anisette V3 service when
local generation fails. The login/account-picker screen includes a brief service
disclosure without asking users to choose a technical method.

For overrides, open **Settings → Account → Advanced Sign-in Settings**.
**This Mac Only** prevents external Anisette service use, and **Server Only** uses
the configured V3 service directly. Previously saved modes and custom server
addresses are preserved; only an unset or unrecognized mode defaults to Automatic.

The default endpoint is `https://ani.sidestore.zip`, operated by SideStore.
You may enter your own HTTPS endpoint, including a port and path prefix.
HTTP is accepted only for loopback (`localhost`, `127.0.0.1`, or `::1`), for a
server running on this Mac. HTTP URLs elsewhere, embedded credentials, query
strings, and fragments are rejected. Saving options does not contact the server.
The app permits local networking through ATS for the loopback option; the
Anisette URL validator still requires HTTPS for every non-loopback server.
If a verification code is pending when options change, return to the login form
and begin again.

## Behavior and data handling

- Both the OTP and machine ID must be present and nonempty. A partially populated
  AOSKit dictionary no longer counts as available.
- The source is selected at the beginning of a login. GSA initialization,
  completion, 2FA, and the PET-to-App-Store exchange all use the same session.
  A failure after selection does not silently switch identities.
- Headers are obtained once per HTTP request. The GSA plist's `cpd` and HTTP
  client-info come from the same snapshot; retries obtain fresh OTPs.
- V3 provisioning creates a random local identifier and device UUID. The server
  URL, identifiers, client-info and `adi_pb` are stored together in a separate,
  device-only Keychain item under service `com.ipaverse.anisette.v3`. Items are
  keyed by the normalized server URL. OTPs are not saved.
- Concurrent provisioning requests for the same server share one task. Keychain
  read failures, corrupt records and remote HTTP failures preserve existing
  data. They do not silently create a replacement identity. Switching back to a
  previously configured server reuses its saved identity.
- Remote requests contain provisioning material and a generated device
  identifier, not Apple Account email, password, account tokens or 2FA codes.
  The remote provider's API does not accept account credentials. It uses an
  ephemeral URLSession with no cookie/credential storage, redirects or logging.
  Only the expected response headers are forwarded to Apple.
- Provisioning URLs discovered through Apple's lookup must use HTTPS and an
  `apple.com` host. HTTP requests have timeouts; a 45-second provisioning deadline
  closes a stalled WebSocket. Cancellation also closes it. Unexpected protocol
  messages and partial responses stop the exchange.

The client-info string uses the host Mac model/OS/build with AuthKit client
`com.apple.akd/1.0`. September 2026 reports show Apple's GSA edge returning an
HTML 503 for the previously used `com.apple.dt.Xcode` identifier. Saved V3
identities migrate only that client token, preserving the host tuple, device UUID,
local identifier and `adi_pb`; users do not need to delete Keychain data or
re-provision. It is a private protocol compatibility value, not an Apple-supported
API, and may need updating as Apple changes authentication.

A credential-free comparison from this workspace on September 11 returned
HTTP 503 with a 190-byte body for the old Xcode identifier and HTTP 404 with an
empty body for `akd`. Both probes used the same deliberately invalid `t` body,
with no account credentials or anisette data. This isolates the header-dependent
503 behavior; it does not verify successful Apple Account authentication.

GSA also uses a separate, short-lived `URLSession` for every HTTP exchange,
including 2FA and the existing single 5xx retry. iLoader v2.3.3 disabled idle
connection pooling after reports of GrandSlam HTTP 429; an ipaverse log likewise
showed a successful `init` followed by an HTML 429 on `complete`. The transport
preserves the caller's configuration, cookie storage and delegate while ending
each session after its response. SRP state and the pinned anisette identity are
independent of those sessions. App Store downloads keep their existing pooling.
This is a compatibility workaround, not evidence that every 429 has this cause.
Any remaining HTTP 429 is reported as a sign-in limit before body parsing, with
no automatic retry or change of anisette identity. The same handling prevents
rate-limited 2FA requests from being reported as a sent code or an invalid code.

The PET-to-App-Store exchange also uses `AuthenticationHTTPTransport`, so a new
login after logout cannot reuse the previous MZFinance connection. Logout already
clears Apple cookies; the anisette device identity remains stable. MZFinance
transport retries preserve the exact plist payload (including `attempt=1`),
refresh OTP/signature headers, and allow at most three transient responses
(204, 404 or 5xx), with 1/2-second cancellable backoff. There is no longer a
12-request rotation over guessed pods. Only validated HTTPS authentication
redirects to `buy.itunes.apple.com` or numeric `pNN-buy.itunes.apple.com` hosts
are followed, preserving POST/body and allowing at most three redirects.
HTTP 403/429 stop immediately. App Store failures after a successful GSA
handshake are reported separately from incorrect Apple Account credentials.
These changes address transport and retry defects; the supplied log alone does
not establish why Apple's edge rejected that specific PET exchange.

A subsequent log showed a valid 302 to p46 followed by an HTML 301 without a
`Location` header. Redirect responses with an absent/blank destination now share
the same three-response transient budget. They retry the current URL (including
`guid`, `Pod` and `PRH`) and POST body with fresh headers; they do not restart GSA
or invent another host. A supplied but invalid redirect destination still fails
immediately. Exhaustion explicitly reports the missing destination. This bounds
recovery attempts without assuming Apple's next response will succeed.

## Verification

Run `bash scripts/test-anisette.sh`. It compiles the actual provider, protocol
client, GSA client and logger into a temporary test executable. HTTP/WebSocket
fixtures and an in-memory store replace external services and Keychain access.
The suite covers source selection, partial OTPs, persistent identity reuse,
concurrent provisioning, protocol ordering, URL construction/validation,
timeouts/cancellation, remote header allowlisting, and GSA/2FA header continuity.
Fixtures also reproduce `init` HTTP 200 followed by `complete` HTTP 429 and check
that all GSA/2FA paths reject 429 without retrying.

Run `python3 Tests/GSAKeepAliveServer.py` for the suite plus a real loopback
HTTP/1.1 transport regression. A control `URLSession` must reuse the server's
keep-alive connection; consecutive GSA exchanges must use distinct connections
while preserving cookies, configuration and request bodies. This needs permission
to listen on a local port. It does not contact Apple or access real credentials.
The loopback test also clears its ephemeral cookie jar between repeated sign-ins,
checking that connections are new and response cookies are accepted again.
MZFinance fixtures cover unchanged payloads, bounded retries, pod redirects,
invalid redirect rejection, 403/429 handling and cancellation.

Before releasing, manually verify on a Mac where AOSKit succeeds and on the
affected macOS 27 beta:

1. Automatic (fresh preferences): local generation first, then remote fallback
   when unavailable, without a method-selection prompt. This Mac Only: successful local generation, or an actionable error without
   contacting the remote service.
2. Automatic/Server Only: first provisioning, sign-in, trusted-device/SMS 2FA, and
   completion of the App Store token exchange.
3. Restart the app and use a saved account; confirm the saved V3 identity is reused.
4. Try an unavailable server, a custom HTTPS port/path, and a local test server;
   confirm the UI recovers and retains the saved identity.
5. Change account or server while a code is pending; confirm the old code/context
   cannot be applied to the new account or configuration.

Automated fixtures do not establish that Apple's live authentication service
will accept a particular account or OS/client combination. No real account
authentication or public-server provisioning is performed by the test script.

## Investigation references

- [ipatool PR #533](https://github.com/majd/ipatool/pull/533): bounded retries for
  transient MZFinance responses preserve the payload and protocol attempt.

- [ipaverse issue #10](https://github.com/bahattinkoc/ipaverse/issues/10): the
  affected user reports macOS 27 beta and links the compatibility project.
- [AltServer macOS 27 technical notes](https://github.com/kimziro/altserver-macos27-anisette-fix/blob/main/TECHNICAL_DETAILS.md):
  the same AOSKit method returns an empty dictionary and error `-45070` on the
  reported beta build. The ipaverse provider implements V3 directly; it does not
  load that project's binary patch or swizzle AOSKit.
- [SideStore RemoteAnisette](https://github.com/SideStore/RemoteAnisette) and
  [anisette-v3-server](https://github.com/Dadoum/anisette-v3-server): protocol references.
- [Custom WebSocket URL fix](https://github.com/kimziro/altserver-macos27-anisette-fix/pull/6):
  scheme, port and path must survive URL conversion.
- [AltStore client identity investigation](https://github.com/altstoreio/AltStore/issues/1772):
  reports stale/incoherent client-info causing a 2FA loop even with valid OTPs.
- [isideload GSA 503 fix](https://github.com/nab138/isideload/pull/11), shipped in
  [iLoader v2.3.2](https://github.com/nab138/iloader/releases/tag/v2.3.2), and
  [AltStore PR #1790](https://github.com/altstoreio/AltStore/pull/1790): the newer
  Xcode identifier rejection and the `akd` compatibility change.
- [isideload connection pooling fix](https://github.com/nab138/isideload/commit/f6a4d5dba717d72fc2af63eaba26b27ba44116be),
  shipped in [iLoader v2.3.3](https://github.com/nab138/iloader/releases/tag/v2.3.3):
  disable idle connection reuse to alleviate GrandSlam HTTP 429 responses.
- [AltStore PR #1770](https://github.com/altstoreio/AltStore/pull/1770): source
  consistency and an alternative local Linux VM approach; the VM is not part of
  this implementation.
- [Apple's NSAllowsLocalNetworking documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking):
  the ATS setting used for an explicitly configured loopback server.
