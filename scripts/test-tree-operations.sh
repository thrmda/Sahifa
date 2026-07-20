#!/usr/bin/env bash
#
# Regression tests for the sidebar's source/tree model: DocumentID algebra
# (what "inside this folder" means, and how ids move when a folder is
# renamed) plus the real rename and move-to-trash operations.
#
# The whole model layer compiles without the app bundle, so these drive
# AppModel directly against a temp folder — no Xcode, no UI, ~3 seconds.
#
# Usage: scripts/test-tree-operations.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Models/DirectoryWatcher.swift \
  Sahifa/Models/DocumentModel.swift \
  Sahifa/Models/WindowState.swift \
  Sahifa/Models/AppModel.swift \
  Tests/TreeOperations/main.swift \
  -o "$BUILD/tree-operations"

"$BUILD/tree-operations"
