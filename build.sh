#!/bin/sh
# Builds build/Hogwatch.app without an Xcode project.
#   ./build.sh           build
#   ./build.sh install   build, copy to ~/Applications and start
#   ./build.sh test      run the logic self-check
set -eu
cd "$(dirname "$0")"
mkdir -p build
SWIFTC="swiftc -O -swift-version 5 -target arm64-apple-macos15"

if [ "${1:-}" = test ]; then
    $SWIFTC Sources/Logic.swift Tests/main.swift -o build/selfcheck
    exec build/selfcheck
fi

APP=build/Hogwatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
$SWIFTC -parse-as-library Sources/*.swift -lIOReport -o "$APP/Contents/MacOS/hogwatch"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = install ]; then
    pkill -x hogwatch || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Hogwatch.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Hogwatch.app
    echo "installed ~/Applications/Hogwatch.app"
fi
