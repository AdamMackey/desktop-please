#!/bin/bash
# Makes a notarized, stapled zip of Desktop Please for GitHub Releases, in dist/.
#
# One-time setup:
#   1. A "Developer ID Application" certificate: Xcode → Settings → Accounts →
#      Manage Certificates → + → Developer ID Application.
#   2. Notary credentials saved in the keychain. Make an app-specific password
#      at account.apple.com, then run this and paste it at the prompt:
#        xcrun notarytool store-credentials notary --apple-id YOU@EXAMPLE.COM --team-id YOURTEAMID
set -euo pipefail
cd "$(dirname "$0")"

NAME="Desktop Please"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="Developer ID Application"
VERSION=$(sed -n 's/^VERSION="\(.*\)".*/\1/p' build.sh)

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "No '$IDENTITY' certificate in the keychain. See the setup notes at the top of release.sh." >&2
  exit 1
fi

./build.sh bundle
# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "build/$NAME.app"

mkdir -p dist
ZIP="dist/${NAME// /-}-$VERSION.zip"
ditto -c -k --keepParent "build/$NAME.app" "$ZIP"
# Keep Apple's whole answer, then look for "Accepted". Piping straight into
# grep -q reported an accepted submission as failed: grep quits at its first
# match, and under pipefail the broken pipe left behind counts as an error.
RESULT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr) || true
if ! grep -q "status: Accepted" <<<"$RESULT"; then
  echo "Notarization failed. For details: xcrun notarytool log <submission id> --keychain-profile $PROFILE" >&2
  exit 1
fi
# Staple the ticket to the app so Gatekeeper can check it offline, then zip again.
xcrun stapler staple "build/$NAME.app"
rm "$ZIP"
ditto -c -k --keepParent "build/$NAME.app" "$ZIP"
rm -rf build
echo "Ready to attach to a GitHub release: $ZIP"
