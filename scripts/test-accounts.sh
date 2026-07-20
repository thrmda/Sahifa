#!/usr/bin/env bash
#
# Checks credential handling: the Keychain round trip (including that storing
# again replaces rather than fails, which is what reconnecting does), and that
# a credential GitHub refuses is caught at connect time rather than appearing
# to work and failing later.
#
# Uses a throwaway Keychain account name and removes it again, so a real
# credential is never touched. Needs the network for the refusal check.
#
# Usage: scripts/test-accounts.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Models/Keychain.swift \
  Sahifa/Models/DocumentStore.swift \
  Sahifa/Models/GitHubStore.swift \
  Sahifa/Models/GitHubAccount.swift \
  Tests/Accounts/main.swift \
  -o "$BUILD/accounts"

"$BUILD/accounts"
