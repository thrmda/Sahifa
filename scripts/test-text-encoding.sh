#!/usr/bin/env bash
#
# Regression tests for reading and writing documents in the encoding they were
# stored in: a UTF-8 byte-order mark survives a save, UTF-16 stays UTF-16, and
# a file that isn't valid Unicode — a Windows-1256 export, or one Sahifa isn't
# allowed to read — opens read-only instead of as an empty editor whose first
# autosave replaces the file.
#
# Same setup as test-document-conflicts.sh: the model layer compiled directly,
# no app bundle, no Xcode, ~2 seconds.
#
# Usage: scripts/test-text-encoding.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Models/DocumentStore.swift \
  Sahifa/Models/Keychain.swift \
  Sahifa/Models/GitHubStore.swift \
  Sahifa/Models/GitHubAccount.swift \
  Sahifa/Models/DocumentModel.swift \
  Tests/TextEncoding/main.swift \
  -o "$BUILD/text-encoding"

"$BUILD/text-encoding"
