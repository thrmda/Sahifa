#!/usr/bin/env bash
#
# Regression tests for the three-way ViewMode (Edit Only / Dual View / View
# Only) and its migration off the old boolean `showPreview` preference.
#
# The model layer compiles without the app bundle, so this drives WindowState
# directly — no Xcode, no UI, ~3 seconds.
#
# Usage: scripts/test-view-mode.sh

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
  Tests/ViewMode/main.swift \
  -o "$BUILD/view-mode"

"$BUILD/view-mode"
