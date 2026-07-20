#!/usr/bin/env bash
#
# Regression tests for DocumentModel's handling of files that change on disk
# while they're open — the autosave-overwrite case, where getting it wrong
# silently destroys whatever another program wrote.
#
# DocumentModel depends only on Foundation and Combine, so the tests compile it
# directly and drive it in-process: no app bundle, no Xcode, no UI, ~2 seconds.
# (Anything touching Markdown/ rendering needs the swift-markdown package and
# the CLI-harness setup described in the project notes instead.)
#
# Usage: scripts/test-document-conflicts.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Models/DocumentModel.swift \
  Tests/DocumentConflicts/main.swift \
  -o "$BUILD/document-conflicts"

"$BUILD/document-conflicts"
