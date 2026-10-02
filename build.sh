#!/bin/bash
# Builds MacClicker.app into ./dist and ad-hoc signs it.
#   ./build.sh            build only
#   ./build.sh --install  also copy to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacClicker"
BUNDLE_ID="com.amalmehta.MacClicker"
VERSION="1.0"
APP="dist/${APP_NAME}.app"

echo "→ compiling (release)"
swift build -c release

echo "→ assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/MacClicker" "$APP/Contents/MacOS/${APP_NAME}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Mac Clicker</string>
    <key>CFBundleDisplayName</key><string>Mac Clicker</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <!-- Voice: transcription runs on-device; only the text is sent. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>Mac Clicker listens only while you hold the voice shortcut, so you can ask about what you are looking at.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Speech is transcribed on this Mac. Only the resulting text is sent with your request.</string>
    <key>NSHumanReadableCopyright</key><string>Built with Claude Code</string>
</dict>
</plist>
PLIST

# A stable identity keeps the keychain ACL and the Accessibility grant valid across
# rebuilds. Falls back to ad-hoc, which changes every build and re-prompts for both.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Mac Clicker Dev"; then
    SIGN_ID="Mac Clicker Dev"
fi

SIGNED_STABLY=0
if [[ -n "$SIGN_ID" ]]; then
    echo "→ signing as \"$SIGN_ID\""
    # Errors stay visible, and a failure falls back to ad-hoc instead of aborting
    # the build. The usual failure is codesign lacking standing permission to use
    # the private key — answer that dialog with "Always Allow", not "Allow".
    if codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" 2>&1; then
        SIGNED_STABLY=1
    else
        echo "   ! couldn't use \"$SIGN_ID\" — falling back to ad-hoc."
        echo "     If a keychain dialog appeared, choose \"Always Allow\" next time."
        echo "     Or authorise codesign permanently:"
        echo "       security set-key-partition-list -S apple-tool:,apple:,codesign: -s \\"
        echo "         -l \"Mac Clicker Dev\" ~/Library/Keychains/login.keychain-db"
        codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
    fi
else
    echo "→ signing (ad-hoc — see README about repeated permission prompts)"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

if [[ "${1:-}" == "--install" ]]; then
    echo "→ installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "   launched — look for the ⌖ icon in your menu bar"
else
    echo "   built: $APP    (run './build.sh --install' to install and launch)"
fi

if [[ "$SIGNED_STABLY" -eq 0 ]]; then
cat <<'NOTE'

Note: this build is ad-hoc signed, so its signature changes every rebuild. macOS will
re-ask for the keychain password and may drop the Accessibility grant each time.
Fix both permanently by creating a self-signed certificate named "Mac Clicker Dev"
(Keychain Access → Certificate Assistant → Create a Certificate…, type: Code Signing).
This script picks it up automatically once it exists.
NOTE
fi
