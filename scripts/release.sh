#!/usr/bin/env bash
#
# Build (and optionally sign + notarize) a distributable Sahifa.app and DMG.
#
# Usage:
#   scripts/release.sh
#
# Configuration is via environment variables — all optional. With none set you
# get an ad-hoc-signed universal build (runs on your Mac, but Gatekeeper will
# warn on other machines). Set the signing/notarization vars for a build you
# can hand to anyone.
#
#   DEV_ID          Developer ID Application identity, e.g.
#                   "Developer ID Application: Jane Doe (TEAMID1234)"
#   TEAM_ID         Your 10-char Apple Developer Team ID (e.g. TEAMID1234)
#   NOTARY_PROFILE  Name of a saved notarytool keychain profile (preferred):
#                       xcrun notarytool store-credentials NOTARY_PROFILE \
#                         --apple-id you@example.com --team-id TEAMID1234 \
#                         --password <app-specific-password>
#                   If unset, falls back to APPLE_ID + APP_PASSWORD + TEAM_ID.
#   APPLE_ID        Apple ID email (only if not using NOTARY_PROFILE)
#   APP_PASSWORD    App-specific password (only if not using NOTARY_PROFILE)
#
# See RELEASE.md for the full walkthrough.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PROJECT="Sahifa.xcodeproj"
SCHEME="Sahifa"
APP_NAME="Sahifa"
BUILD_DIR="$ROOT/build/release"
DERIVED="$BUILD_DIR/DerivedData"
DIST="$ROOT/dist"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"

VERSION="$(/usr/bin/awk -F' = ' '/MARKETING_VERSION/ {gsub(/;/,"",$2); print $2; exit}' "$PROJECT/project.pbxproj")"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

echo "▸ Sahifa $VERSION — release build"
rm -rf "$BUILD_DIR" "$DIST"
mkdir -p "$DIST"

# ── Build (universal: Apple Silicon + Intel) ──────────────────────────────────
BUILD_ARGS=(
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release
  -derivedDataPath "$DERIVED"
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
)
if [[ -n "${DEV_ID:-}" ]]; then
  echo "▸ Signing with: $DEV_ID"
  BUILD_ARGS+=( CODE_SIGN_IDENTITY="$DEV_ID" CODE_SIGN_STYLE=Manual )
  [[ -n "${TEAM_ID:-}" ]] && BUILD_ARGS+=( DEVELOPMENT_TEAM="$TEAM_ID" )
else
  echo "▸ No DEV_ID set → ad-hoc signature (local use only)."
fi

xcodebuild "${BUILD_ARGS[@]}" clean build

echo "▸ Built: $APP"
echo "  arches: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
codesign -dv "$APP" 2>&1 | grep -E "Authority|flags|TeamIdentifier" || true

# ── Notarize the app (only with real signing credentials) ────────────────────
notary_args() {
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "--keychain-profile $NOTARY_PROFILE"
  elif [[ -n "${APPLE_ID:-}" && -n "${APP_PASSWORD:-}" && -n "${TEAM_ID:-}" ]]; then
    echo "--apple-id $APPLE_ID --password $APP_PASSWORD --team-id $TEAM_ID"
  fi
}
NOTARY_ARGS="$(notary_args)"

if [[ -n "${DEV_ID:-}" && -n "$NOTARY_ARGS" ]]; then
  echo "▸ Notarizing app…"
  ZIP="$BUILD_DIR/$APP_NAME.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  # shellcheck disable=SC2086
  xcrun notarytool submit "$ZIP" $NOTARY_ARGS --wait
  xcrun stapler staple "$APP"
  echo "▸ Stapled the app."
else
  echo "▸ Skipping notarization (needs DEV_ID + notary credentials)."
fi

# ── Package a DMG ────────────────────────────────────────────────────────────
echo "▸ Building DMG…"
STAGE="$BUILD_DIR/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${DEV_ID:-}" ]]; then
  codesign --force --sign "$DEV_ID" --timestamp "$DMG"
  if [[ -n "$NOTARY_ARGS" ]]; then
    echo "▸ Notarizing DMG…"
    # shellcheck disable=SC2086
    xcrun notarytool submit "$DMG" $NOTARY_ARGS --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo ""
echo "✓ Done: $DMG"
if [[ -n "${DEV_ID:-}" && -n "$NOTARY_ARGS" ]]; then
  echo "  Signed + notarized + stapled — ready to distribute."
  echo "  Verify: spctl -a -vvv -t install \"$DMG\""
else
  echo "  NOTE: not notarized — Gatekeeper will warn on other Macs."
fi
