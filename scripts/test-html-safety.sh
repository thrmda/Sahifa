#!/usr/bin/env bash
#
# Regression tests for what a document's own HTML may do in the preview and
# in an exported page: Markdown passes raw HTML through, so a file can carry
# a script, an onerror handler, a javascript: link or a meta refresh. The
# page's Content Security Policy must stop the script, the renderer must drop
# script URLs, and the preview must allow no navigation but its own shell.
#
# Renders real pages with swift-markdown and loads the preview shell in an
# offscreen WKWebView. Links the package objects from a prior Debug build:
#
#   xcodebuild -project Sahifa.xcodeproj -scheme Sahifa \
#     -configuration Debug -derivedDataPath build/DerivedData build
#
# Usage: scripts/test-html-safety.sh

set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCTS="build/DerivedData/Build/Products/Debug"
CHECKOUTS="build/DerivedData/SourcePackages/checkouts"

if [[ ! -f "$PRODUCTS/Markdown.o" ]]; then
  echo "Missing $PRODUCTS/Markdown.o — build the app once first (see header)." >&2
  exit 1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

swiftc -O \
  Sahifa/Theme.swift \
  Sahifa/Editor/BidiDirection.swift \
  Sahifa/Export/HTMLEscaping.swift \
  Sahifa/Export/MarkdownHTMLRenderer.swift \
  Tests/HTMLSafety/main.swift \
  "$PRODUCTS/Markdown.o" \
  "$PRODUCTS/cmark-gfm.o" \
  "$PRODUCTS/cmark-gfm-extensions.o" \
  "$PRODUCTS/CAtomic.o" \
  -I "$PRODUCTS" \
  -Xcc -I"$CHECKOUTS/swift-cmark/src/include" \
  -Xcc -I"$CHECKOUTS/swift-cmark/extensions/include" \
  -Xcc -I"$CHECKOUTS/swift-markdown/Sources/CAtomic/include" \
  -o "$BUILD/html-safety"

"$BUILD/html-safety"
