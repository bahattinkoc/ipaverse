# Contributing to ipaverse

Thanks for your interest in improving ipaverse! This document covers how to
get set up, the kind of contributions that are welcome, and the process for
submitting changes.

## Before you start

ipaverse only works with **DRM-free IPAs**. Contributions that add FairPlay
decryption, DRM bypass, or App Store policy circumvention will not be
accepted. See [Security & Privacy](README.md#security--privacy) in the README
for the project's boundaries.

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
