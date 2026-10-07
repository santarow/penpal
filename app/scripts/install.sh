#!/bin/sh
# Build the dev app from this checkout and install it in /Applications: "Penpal Dev.app" (#209).
# The app reads lenses, agents and bin/kite from the checkout it was built from.
# Usage: app/scripts/install.sh
set -e
cd "$(dirname "$0")"
./build-app.sh

FLAVOR="${FLAVOR:-penpal}"
NAME="Penpal Dev"; ID=dev.santarow.penpal
DEST="/Applications/$NAME.app"
# Only ever replace our own app, never something else that happens to have the name.
if [ -d "$DEST" ] && [ "$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$ID" ]; then
    echo "$DEST exists and isn't ours ($ID). Not touching it." >&2
    exit 1
fi
osascript -e "tell application id \"$ID\" to quit" 2>/dev/null || true
sleep 1
[ -d "$DEST" ] && mv "$DEST" "$HOME/.Trash/$NAME $(date +%Y%m%d-%H%M%S).app"  # the old copy goes to the Trash
cp -R "../build/$NAME.app" "$DEST"
echo "Installed $DEST (reads from $(cd ../.. && pwd))"
open "$DEST"
