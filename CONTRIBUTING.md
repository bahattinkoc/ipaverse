# Contributing to ipaverse

Thanks for your interest in improving ipaverse! This document covers how to
get set up, the kind of contributions that are welcome, and the process for
submitting changes.

## Before you start

Re-signing requires a **DRM-free IPA**, while the authorized security-testing
toolkit can create a decrypted copy from a running app on a jailbroken source
device controlled by the user. Contributions in this area must preserve the
explicit authorization warnings, Evil Mode guardrails, and locally scoped
data handling. Features intended to obtain paid apps without a valid license,
steal credentials, evade Apple account authorization, or target third parties
without permission will not be accepted. See
[Security Testing](README.md#security-testing) and
[Security & Privacy](README.md#security--privacy) for the project's boundaries.

## Getting set up

Requirements:

* macOS 14.6+
* Xcode (latest stable release recommended)

```bash
git clone https://github.com/bahattinkoc/ipaverse.git
cd ipaverse
open ipaverse/ipaverse.xcodeproj
```

Build and run with `Cmd+R` from Xcode.

## Making changes

1. Fork the repository and create a branch from `main`:
   `git checkout -b feature/short-description`
2. Keep changes focused — a pull request should do one thing.
3. Match the existing SwiftUI code style already used in the project (naming,
   file organization, indentation).
4. If you change behavior around authentication, Keychain storage, or the
   vendored [Unicorn Engine](ipaverse/Vendor/unicorn) component, explain the
   reasoning clearly in your PR description — these are security-sensitive
   areas.
5. Test your changes by running the app locally (Debug scheme) before opening
   a PR. There is no CI test suite yet, so manual verification is the
   baseline.

For Anisette changes, run `bash scripts/test-anisette.sh` on macOS. This standalone
regression suite uses mocked Apple/V3 endpoints and an in-memory identity store;
it does not contact a real server or read/write your Keychain. Real account login
and 2FA still require manual validation as described in [docs/anisette.md](docs/anisette.md).

## Submitting a pull request

* Fill out the pull request template.
* Reference any related issue.
* Describe what you tested and how.
* Keep the PR description in English so it's accessible to all contributors.

A maintainer will review your PR, may ask for changes, and will merge once
it's ready.

## Reporting bugs / requesting features

Use the [issue templates](.github/ISSUE_TEMPLATE) — they help make sure we
get the information needed to act on a report quickly.

## Security issues

Do **not** open a public issue for security vulnerabilities. See
[SECURITY.md](SECURITY.md) instead.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you agree to uphold it.
