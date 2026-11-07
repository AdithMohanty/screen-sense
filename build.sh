#!/bin/bash
# Usage: ./build.sh            build build/ScreenSense.app
#        ./build.sh install    build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ScreenSense.app
MIN_MACOS=12.0

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -Osize -parse-as-library -target "$arch-apple-macos$MIN_MACOS" \
    Sources/*.swift -o "build/ScreenSense-$arch"
done
lipo -create build/ScreenSense-arm64 build/ScreenSense-x86_64 -output "$APP/Contents/MacOS/ScreenSense"
strip -x "$APP/Contents/MacOS/ScreenSense"
rm build/ScreenSense-arm64 build/ScreenSense-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "install" ]]; then
  osascript -e 'quit app "ScreenSense"' 2>/dev/null || true
  rm -rf /Applications/ScreenSense.app
  cp -R "$APP" /Applications/
  open /Applications/ScreenSense.app
  echo "Installed to /Applications"
fi
