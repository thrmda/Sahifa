#!/usr/bin/env bash
#
# Saving back to a GitHub repository. This one WRITES, so it is opt-in:
#
#   SAHIFA_TEST_REPO=owner/name SAHIFA_TEST_TOKEN=… scripts/test-github-write.sh
#
# The token comes from the environment, NOT the app's Keychain: a test binary
# is newly built each run, so reading the stored credential makes macOS prompt
# for the keychain password every time. It works only in a uniquely named
# scratch document and deletes it afterwards. With either variable unset it
# reports SKIP and does nothing, so a plain test run can never write to
# anybody's repository.

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
  Sahifa/Models/DocumentModel.swift \
  Tests/GitHubWrite/main.swift \
  -o "$BUILD/github-write"

"$BUILD/github-write"
