#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipaverse-anisette-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -D DEBUG -parse-as-library \
  -module-cache-path "$test_dir/module-cache" \
  ipaverse/ipaverse/Services/Auth/AnisetteConfiguration.swift \
  ipaverse/ipaverse/Services/Auth/AnisetteIdentityStore.swift \
  ipaverse/ipaverse/Services/Auth/AnisetteV3Client.swift \
  ipaverse/ipaverse/Services/Auth/AnisetteProvider.swift \
  ipaverse/ipaverse/Services/Auth/AuthenticationHTTPTransport.swift \
  ipaverse/ipaverse/Services/Auth/MZFinanceAuthentication.swift \
  ipaverse/ipaverse/Services/Auth/GSAClient.swift \
  ipaverse/ipaverse/Services/Auth/SRPClient.swift \
  ipaverse/ipaverse/Services/Auth/BigIntJS.swift \
  ipaverse/ipaverse/Services/Auth/CryptoHelpers.swift \
  ipaverse/ipaverse/Services/NetworkLogger.swift \
  ipaverse/ipaverse/Services/AppStoreDownloadProduct.swift \
  ipaverse/ipaverse/Services/AppStorePurchase.swift \
  Tests/PurchaseTests.swift \
  Tests/DownloadProductTests.swift Tests/MZFinanceTests.swift Tests/AnisetteTests.swift -o "$test_dir/anisette-tests"
"$test_dir/anisette-tests"
