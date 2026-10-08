#!/bin/sh
# Build Kite and wrap it in Kite.app so macOS gives it a Dock icon.
# Usage: app/scripts/build-app.sh   (then: open app/build/Kite.app)
set -e
cd "$(dirname "$0")/.."

# RELEASE=1: a release build, with its own ID, so it never touches the dev app or its settings.
if [ -n "$RELEASE" ]; then FLAGS="-Xswiftc -DKITE_RELEASE"; else FLAGS=""; fi
FLAVOR="${FLAVOR:-penpal}"; ICON_BG=""
case "$FLAVOR" in
    penpal)
        # Penpal by SantaRow 1.0 (#266), its own numbering; 1.0.1 (#290); 1.0.2 (#298); 1.0.3 (#304); 1.0.4 (#309); 1.0.5;
        # 1.0.6, the last planned (#322)
        if [ -n "$RELEASE" ]; then VERSION="1.0.6"; NAME="Penpal"; SHOWN="Penpal"; ID="com.santarow.penpal"
        else VERSION="0.1"; NAME="Penpal Dev"; SHOWN="Penpal Dev"; ID="dev.santarow.penpal"; fi
        EXE="Penpal" ;;
    *) echo "FLAVOR must be workshop, teamforce or penpal" >&2; exit 1 ;;
esac
swift build -c release $FLAGS
BIN="$(swift build -c release $FLAGS --show-bin-path)/Kite"
LENSES="$(cd ../lenses && pwd)"
ROOT="$(cd .. && pwd)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"  # the release runs as "Workshop", so system prompts name it
# SwiftPM stamps the binary with SDK 14.0 (its deployment target), so macOS draws the app in its old,
# compatibility style: flat traffic lights unlike Messages' (#273). Stamp the SDK
# it was really built with.
SDK="$(xcrun --show-sdk-version 2>/dev/null)"
[ -n "$SDK" ] && vtool -set-build-version macos 14.0 "$SDK" -replace -output "$APP/Contents/MacOS/$EXE" "$APP/Contents/MacOS/$EXE"
# The icon: a factory drawn in code (scripts/icon.swift), at every size macOS asks for.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
# Penpal's own icon (#209): the nib writing on a memo, drawn at each size (simpler when small).
penpal_icon() {
    swiftc -O scripts/penpal-icon.swift -o build/penpal-icon 2>&1 | grep -v warning || true
    build/penpal-icon C build/icon-1024.png 1024 >/dev/null
    for s in 16 32 128 256 512; do
        build/penpal-icon C "$ICONSET/icon_${s}x${s}.png" $s >/dev/null
        build/penpal-icon C "$ICONSET/icon_${s}x${s}@2x.png" $((s*2)) >/dev/null
    done
}
[ "$FLAVOR" = penpal ] && penpal_icon
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Inside Penpal the engine is Penpal's own (#310, Jason: "any instance of kite, we should rename to penpal or santarow"):
# Resources/penpal with bin/penpal, and SantaRow keys in Info.plist. The other apps keep kite until #311.
ENGINE=penpal; KEYS=SantaRow
cp -R "$LENSES" "$APP/Contents/Resources/lenses"
if [ -n "$RELEASE" ]; then
    # Workshop runs on any Mac: bin/kite, agents, mcp, voice and data go inside the app, from what's
    # committed (git archive), so no local runs, archives or stray files come along.
    mkdir -p "$APP/Contents/Resources/$ENGINE"
    PARTS="bin agents lenses data"
    (cd .. && git archive HEAD $PARTS) | tar -x -C "$APP/Contents/Resources/$ENGINE" --exclude "agents/_archive"
    [ "$ENGINE" = penpal ] && mv "$APP/Contents/Resources/penpal/bin/kite" "$APP/Contents/Resources/penpal/bin/penpal"
    ROOTVAL="@bundle"; LENSESVAL=""
else
    ROOTVAL="$ROOT"; LENSESVAL="$LENSES"
fi

# What the app may ask macOS for, said the app's way (#266): Penpal asks only to open Terminal (Claude History's
# resume); its Highlight and paste switches have no text here. The other apps keep their agents' asks.
if [ "$FLAVOR" = penpal ]; then
    USAGE="  <key>NSAppleEventsUsageDescription</key><string>Claude History opens Terminal to resume or fork one of your sessions.</string>
  <key>NSHumanReadableCopyright</key><string>Penpal by SantaRow. © 2026 SantaRow.</string>"
fi

CLAIM=""
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$SHOWN</string>
  <key>SantaRowApp</key><string>$FLAVOR</string>
$CLAIM
  <key>CFBundleDisplayName</key><string>$SHOWN</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$(cd .. && git rev-list --count HEAD)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>${KEYS}LensesPath</key><string>$LENSESVAL</string>
  <key>${KEYS}RootPath</key><string>$ROOTVAL</string>
$USAGE
</dict>
</plist>
PLIST

# A stable signature lets the Accessibility grant survive rebuilds. Ad hoc ("-") works
# too, but macOS then asks again after every build.
# Not -v: a new Developer ID certificate can be listed as "not valid" yet sign fine (checked 2026-09-27).
pick() { security find-identity -p codesigning | awk -F'"' -v k="$1" 'index($0, k) {print $2; exit}'; }
# Release builds sign with Developer ID (for other people's Macs) when you have one; until then, and
# for dev builds, Apple Development.
if [ -n "$RELEASE" ]; then IDENTITY="${KITE_SIGN_IDENTITY:-$(pick "Developer ID Application")}"; fi
IDENTITY="${IDENTITY:-${KITE_SIGN_IDENTITY:-$(pick "Apple Development")}}"
if [ -n "$RELEASE" ]; then
    # Release: Apple's hardened runtime and a secure timestamp, both needed to notarize.
    ENT=Penpal.entitlements
    codesign --force --options runtime --timestamp --sign "${IDENTITY:--}" --entitlements "$ENT" "$APP"
else
    codesign --force --sign "${IDENTITY:--}" "$APP"
fi

echo "Built $APP (signed: ${IDENTITY:-ad hoc})"
