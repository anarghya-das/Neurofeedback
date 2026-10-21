#!/bin/sh
# Builds "MW75 Bench" for macOS (Apple silicon and Intel, macOS 14+) and
# packages it as a DMG in <repo>/dist/.
#
# The app is signed ad hoc: there is no Developer ID certificate to notarize
# with, so each Mac has to allow it once (see the read-me written into the DMG).
#
# Why the framework repair: pub stores packages without symlinks, so the
# lsl.framework that lsl_bindings ships arrives with Versions/Current and the
# top-level links as real copies. macOS then finds the bundle "ambiguous",
# strict signature checks fail, and Gatekeeper reports the app as damaged.
set -e
cd "$(dirname "$0")/.."

flutter build macos --release

APP="build/macos/Build/Products/Release/MW75 Bench.app"
FW="$APP/Contents/Frameworks/lsl.framework"
ENTITLEMENTS="$(mktemp)"
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null

rm -rf "$FW/Versions/Current" "$FW/lsl" "$FW/Resources"
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/lsl "$FW/lsl"
ln -s Versions/Current/Resources "$FW/Resources"
codesign --force --sign - "$FW"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
rm "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"

VERSION="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' pubspec.yaml)"
DIST="dist"
STAGE="$(mktemp -d)"
mkdir -p "$DIST"
ditto "$APP" "$STAGE/MW75 Bench.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read me first.txt" <<'EOF'
MW75 Bench: start/stop, signal quality and test tools for the Neurable MW75 Neuro.

Requirements
- macOS 14 or later (Apple silicon or Intel).
- The MW75 Neuro paired in System Settings > Bluetooth.
- Raw EEG activated on the headset once in Neurable Research Kit. Quit Research Kit before using this app.

Installing
1. Drag "MW75 Bench" into Applications.
2. The first time, macOS says it cannot verify the developer (the app is not notarized).
   Open it once, then go to System Settings > Privacy & Security and click "Open Anyway".
   On macOS 14 you can instead Control-click the app and choose Open.
3. Allow Bluetooth access when asked.

Using it
- Headset card: choose the MW75 and click Start streaming. The link takes 10-15 s to settle.
- EEG is published to Lab Streaming Layer as "MW75 Neuro Neurable Stream"; oddball tones as "MW75 Oddball Markers".
- Test runs (auditory oddball, eyes-closed alpha) are saved to Documents/MW75 Tests: run.json with the settings
  and results, and eeg.csv with the raw EEG.
- Auditory oddball sound level: with a sound level meter, calibrate each output once (Calibrate... beside Sound
  level) to set levels in dB SPL. Keep the Mac volume where it was calibrated; the app warns if it moves.
  Calibrations are saved to Documents/MW75 Tests/sound calibration.json.
- Your focus: calibrate once (about 4-6 minutes of alternating rest and silent counting), then the score is shown
  as a number, a bar and a flame or rocket, and published to LSL as "MW75 Focus". The calibration is saved to
  Documents/MW75 Tests/focus model.json. Calibrations from version 1.0 cannot be read: calibrate again.
EOF
DMG="$DIST/MW75 Bench $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "MW75 Bench" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
echo "Built $(cd "$DIST" && pwd)/MW75 Bench $VERSION.dmg"
