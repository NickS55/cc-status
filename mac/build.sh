#!/bin/sh
# Builds CCS.app next to this script. Pass --install to copy it to /Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=CCS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CCS "$APP/Contents/MacOS/CCS"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
if [ "$1" = "--install" ]; then
  rm -rf /Applications/CCS.app
  cp -R "$APP" /Applications/
  echo "installed /Applications/CCS.app"
else
  echo "built $(pwd)/$APP"
fi
