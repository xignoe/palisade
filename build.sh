#!/bin/bash
# Builds build/Palisade.app: compile, bundle, then sign ad hoc with the
# hardened runtime and the App Sandbox entitlements.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Palisade.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -framework AppKit -framework WebKit \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/Palisade"

cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - --options runtime \
    --entitlements Resources/Palisade.entitlements "$APP"

echo "Built $APP"
