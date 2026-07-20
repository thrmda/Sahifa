#!/usr/bin/env bash
#
# Failed-save and retry behaviour, driven by a fake store whose writes fail on
# demand — no real network needed. Covers: a retryable failure holds the edit
# and retries (manually and on its own), a non-retryable failure holds the edit
# without spinning, and recovery when the cause clears.
#
# Usage: scripts/test-save-retry.sh

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
  Tests/SaveRetry/main.swift \
  -o "$BUILD/save-retry"

"$BUILD/save-retry"
