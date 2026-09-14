#!/usr/bin/env bash
#
# Regression tests for CSV/TSV support: the delimited-text parser (quoting,
# line endings, ragged rows, unclosed quotes), delimiter detection, and the
# table renderer's direction and escaping rules.
#
# Pure Foundation plus BidiDirection — no swift-markdown, no app bundle, no
# Xcode, a couple of seconds.
#
# Usage: scripts/test-tabular.sh

set -euo pipefail

cd "$(dirname "$0")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Models/Source.swift \
  Sahifa/Editor/BidiDirection.swift \
  Sahifa/Export/HTMLEscaping.swift \
  Sahifa/Tabular/DelimitedText.swift \
  Sahifa/Tabular/TableHTMLRenderer.swift \
  Sahifa/Tabular/MarkdownTable.swift \
  Sahifa/Tabular/TablePreview.swift \
  Tests/Tabular/main.swift \
  -o "$BUILD/tabular"

"$BUILD/tabular"
