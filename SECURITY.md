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

As documented in the [README](README.md#security--privacy): ipaverse runs
entirely locally, stores credentials in macOS Keychain, never transmits
passwords directly (SRP-6a challenge/response), and never uploads Apple ID
data, certificates, provisioning profiles, or IPA files to any third-party
server. Reports that show a violation of these guarantees are treated as
high priority.
