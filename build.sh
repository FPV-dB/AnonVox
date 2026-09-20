#!/bin/bash
# Builds AnonVox into a runnable .app bundle.
#
# This project has no .xcodeproj — Xcode's files-container compiles each .swift
# file as its own module, so the Run button can't link them. Build here instead.
#
#   ./build.sh          build, sign, launch
#   ./build.sh --no-run build and sign only
#   ./build.sh --icon   regenerate AppIcon.icns first (needs make-icon.swift)

set -euo pipefail
cd "$(dirname "$0")"

APP="build/AnonVox.app"
SOURCES=(VoiceScramblerApp.swift ContentView.swift VoiceScramblerEngine.swift VoiceDSP.swift AudioDevices.swift)

if [[ "${1:-}" == "--icon" ]]; then
    xcrun swift make-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    shift
fi

pkill -f "AnonVox.app/Contents/MacOS/AnonVox" 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Info.plist "$APP/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# -swift-version 5: this code is not written for Swift 6 language mode, which
# is what the Xcode files-container would otherwise use.
xcrun swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -O \
    -o "$APP/Contents/MacOS/AnonVox" \
    "${SOURCES[@]}"

# Ad-hoc signing is enough for a local build, and the bundle must be signed for
# the microphone permission prompt to appear at all.
codesign --force --deep --sign - --identifier com.anonvox.VoiceScrambler "$APP"
touch "$APP"

echo "built $APP"
[[ "${1:-}" == "--no-run" ]] || open "$APP"
