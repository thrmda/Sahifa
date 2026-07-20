#!/usr/bin/env bash
#
# Regression tests for the editor's Markdown formatting actions: inline
# delimiters, headings, list/quote markers, what happens to the selection
# afterwards, and undo atomicity.
#
# These drive a real BidiTextView in an offscreen NSWindow — NSTextView takes
# its undo manager from the window, so undo can't be exercised without one.
# The editor needs swift-markdown, which isn't buildable standalone, so this
# links the package objects from a prior Debug build. Run a normal build first:
#
#   xcodebuild -project Sahifa.xcodeproj -scheme Sahifa \
#     -configuration Debug -derivedDataPath build/DerivedData build
#
# Usage: scripts/test-formatting.sh

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
  Sahifa/Editor/BidiTextView.swift \
  Sahifa/Editor/FontLibrary.swift \
  Sahifa/Editor/MarkdownStyler.swift \
  Sahifa/Editor/FormattingCommands.swift \
  Sahifa/Models/Source.swift \
  Sahifa/Models/DirectoryWatcher.swift \
  Sahifa/Models/DocumentModel.swift \
  Sahifa/Models/WindowState.swift \
  Sahifa/Models/AppModel.swift \
  Tests/Formatting/main.swift \
  "$PRODUCTS/Markdown.o" \
  "$PRODUCTS/cmark-gfm.o" \
  "$PRODUCTS/cmark-gfm-extensions.o" \
  "$PRODUCTS/CAtomic.o" \
  -I "$PRODUCTS" \
  -Xcc -I"$CHECKOUTS/swift-cmark/src/include" \
  -Xcc -I"$CHECKOUTS/swift-cmark/extensions/include" \
  -Xcc -I"$CHECKOUTS/swift-markdown/Sources/CAtomic/include" \
  -o "$BUILD/formatting"

"$BUILD/formatting"
