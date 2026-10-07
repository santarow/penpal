#!/bin/sh
# An app for other people's Macs: a release build, signed with Developer
# ID, in a .dmg that Apple has notarized (checked for malware) and stapled, so it opens without a warning.
# Usage: FLAVOR=penpal app/scripts/release.sh   (needs your Developer ID certificate and a notary profile)
#        app/scripts/release.sh --test    (Apple Development, no notarizing: to try the steps now)
# One-time notary profile (you type your app-specific password; nothing else sees it):
#   xcrun notarytool store-credentials santarow-notary --apple-id <your Apple ID> --team-id <team ID>
set -e
cd "$(dirname "$0")/.."
TEST=""; [ "$1" = "--test" ] && TEST=1

if [ -z "$TEST" ] && ! security find-identity -p codesigning | grep -q "Developer ID Application"; then
    echo "No Developer ID Application certificate yet: Xcode → Settings → Accounts → Manage Certificates → +." >&2
    exit 1
fi
RELEASE=1 ./scripts/build-app.sh
FLAVOR="${FLAVOR:-penpal}"; APP="$(echo "$FLAVOR" | cut -c1 | tr a-z A-Z)$(echo "$FLAVOR" | cut -c2-)"
VERSION=$(defaults read "$PWD/build/$APP.app/Contents/Info" CFBundleShortVersionString)
DMG="build/$APP-$VERSION.dmg"

# The download: the app and a link to Applications, to drag it across.
rm -rf build/dmg "$DMG" && mkdir -p build/dmg
cp -R "build/$APP.app" build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname "$APP" -srcfolder build/dmg -format UDZO "$DMG"
rm -rf build/dmg
IDENTITY="$(codesign -dvv "build/$APP.app" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}')"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -n "$TEST" ]; then
    echo "Test build: $DMG (signed: $IDENTITY; not notarized)"
    exit 0
fi
xcrun notarytool submit "$DMG" --keychain-profile santarow-notary --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready to share: $DMG"
