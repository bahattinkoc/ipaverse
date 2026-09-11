# Security Policy

ipaverse handles sensitive data — Apple ID credentials, authentication
tokens, certificates, and provisioning profiles. We take security reports
seriously and appreciate responsible disclosure.

## Supported Versions

Only the latest released version of ipaverse is supported with security
fixes.

| Version | Supported |
| ------- | --------- |
| Latest  | ✅ |
| Older   | ❌ |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub
issues.**

Instead, email **bahattink3458@gmail.com** with:

* A description of the vulnerability and its potential impact
* Steps to reproduce (proof-of-concept code or screenshots help)
* The version of ipaverse and macOS you tested on

You should receive an acknowledgment within a few days. We'll keep you
updated as the issue is investigated and resolved, and we'll credit you in
the fix (unless you prefer to stay anonymous).

## Scope

In scope:

* Credential handling and Keychain storage
* Apple GrandSlam / SRP-6a authentication flow implementation
* Anisette header generation
* Any code path that could leak an Apple ID, password, certificate, or IPA
  to a third party

Out of scope:

* Vulnerabilities requiring physical access to an already-unlocked, already
  compromised Mac
* Issues in the vendored [Unicorn Engine](ipaverse/Vendor/unicorn) dependency
  itself — please report those upstream, though you're welcome to also let us
  know if it affects ipaverse specifically
* Social engineering attacks against users

## Design principles relevant to security reports

As documented in the [README](README.md#security--privacy), sensitive IPA
processing is local and ipaverse has no project-operated authentication relay
or telemetry backend. It communicates directly with Apple for authentication
and App Store operations. Raw passwords are not sent directly during the
GrandSlam SRP-6a exchange, and account/session credentials are stored in
macOS Keychain.

Anisette generation defaults to Automatic: it tries AOSKit locally, then uses
the configured Anisette V3 service if local generation fails. The login screen
discloses this service use. Advanced Sign-in Settings lets users disable external
generation (This Mac Only), choose a custom server, or require Server Only.
Existing explicit preferences are preserved. This service receives a generated device identifier and personalization
data (`adi_pb`); provisioning also exchanges `spim`, `cpim`, `ptm`, and `tk`
with Apple's provisioning endpoints. It receives no Apple Account email,
password, account/session cookies, or verification codes. The configured server
is a trust boundary; its persistent device identity is stored in Keychain, and
its requests use an isolated URLSession without cookies, credential storage,
redirects, or body logging. See [the implementation notes](docs/anisette.md).

User-initiated update checks, on-demand Frida downloads, and optional tool
installation may contact GitHub, Homebrew, pip, or a tool vendor. Those paths
must never include Apple credentials, certificates, provisioning profiles, or
IPA contents. Reports showing a violation of these boundaries are treated as
high priority.
