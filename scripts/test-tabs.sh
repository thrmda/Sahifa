#!/usr/bin/env bash
#
# Regression tests for in-window document tabs (WindowState.openTabs): open,
# switch, close-to-neighbour, and rename/delete remapping.
#
# The model layer compiles without the app bundle, so this drives WindowState
# directly against a temp folder — no Xcode, no UI, ~3 seconds.
#
# Usage: scripts/test-tabs.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Models/DirectoryWatcher.swift \
  Sahifa/Models/DocumentStore.swift \
  Sahifa/Models/Keychain.swift \
  Sahifa/Models/GitHubStore.swift \
  Sahifa/Models/GitHubAccount.swift \
  Sahifa/Models/DocumentModel.swift \
  Sahifa/Models/WindowState.swift \
  Sahifa/Models/AppModel.swift \
  Tests/Tabs/main.swift \
  -o "$BUILD/tabs"

"$BUILD/tabs"
