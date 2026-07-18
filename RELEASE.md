# Releasing Sahifa

How to cut a distributable build. The `scripts/release.sh` helper does the
mechanical work; this page explains the one-time setup and the choices.

Current version: **1.0.0** (build 1). Bump it in Xcode → target *Sahifa* →
*General* → Identity, or edit `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
in `Sahifa.xcodeproj/project.pbxproj` (both the Debug and Release configs).

The project already has **hardened runtime enabled** and a minimal sandbox
(`Sahifa.entitlements`: user-selected files + app-scope bookmarks) — both
required for notarization.

## What kind of build do you need?

| Goal | What you need |
| --- | --- |
| Run it yourself on this Mac | Nothing — `scripts/release.sh` with no env vars gives an ad-hoc build. |
| Share with others without Gatekeeper warnings | Apple Developer Program membership, a **Developer ID Application** certificate, and notarization. |

Ad-hoc builds run fine locally but other Macs will show *“Sahifa can't be
opened because Apple cannot check it for malicious software.”* Only a
Developer-ID-signed **and notarized** build clears that.

## One-time setup (for a distributable build)

1. **Join the Apple Developer Program** and, in Xcode → Settings → Accounts,
   create a **Developer ID Application** certificate (or download an existing
   one). Confirm it's installed:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **Create an app-specific password** for notarization at
   <https://account.apple.com> → Sign-In and Security → App-Specific Passwords.

3. **Save a notarytool credential profile** (so you never pass secrets on the
   command line again):

   ```bash
   xcrun notarytool store-credentials Sahifa-Notary \
     --apple-id "you@example.com" \
     --team-id  "YOURTEAMID" \
     --password "app-specific-password"
   ```

## Cut the release

```bash
export DEV_ID="Developer ID Application: Your Name (YOURTEAMID)"
export TEAM_ID="YOURTEAMID"
export NOTARY_PROFILE="Sahifa-Notary"

scripts/release.sh
```

The script will:

1. Build a **universal** (Apple Silicon + Intel) Release `.app`, signed with
   your Developer ID and hardened runtime.
2. Notarize the app and **staple** the ticket to it.
3. Package a compressed **DMG** (with an `/Applications` drop link), sign it,
   notarize and staple it too.

Output lands in `dist/Sahifa-<version>.dmg`.

Run it with **no** env vars for a quick local ad-hoc build (skips signing and
notarization).

## Verify before you ship

```bash
# Gatekeeper accepts the DMG:
spctl -a -vvv -t install dist/Sahifa-1.0.0.dmg

# The stapled ticket is present:
xcrun stapler validate dist/Sahifa-1.0.0.dmg

# The app inside is Developer-ID signed with the runtime flag:
codesign -dvvv "$(hdiutil attach -nobrowse dist/Sahifa-1.0.0.dmg | \
  grep Volumes | awk '{print $3}')/Sahifa.app"
```

A clean check: copy the DMG to another Mac (or a fresh user account) and open
it — it should launch with no Gatekeeper prompt.

## Notes

- The bundle identifier is `me.alangari.Sahifa`. Change it (and the signing
  certificate) if you're shipping under a different account.
- Sahifa makes **no network calls**, so there's nothing to allow-list; the only
  entitlements are file access and app-scope bookmarks.
- For the Mac App Store instead of direct distribution you'd switch to an
  *Apple Distribution* certificate and an App Store provisioning profile and
  submit through App Store Connect — not covered here.
