#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/WattBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
SOURCE="$ROOT/Sources/WattBar/main.swift"
GPU_SOURCE="$ROOT/Tools/IOReportPower.c"
GPU_OBJECT="$ROOT/Tools/bin/IOReportPower.o"
PLIST="$ROOT/Sources/WattBar/Info.plist"
# Ad-hoc signing keeps local builds reproducible without embedding a developer's
# personal signing identity. Set SIGN_IDENTITY explicitly for a trusted build.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

mkdir -p "$MACOS"
mkdir -p "$ROOT/Tools/bin"
cp "$PLIST" "$CONTENTS/Info.plist"

clang \
  -O2 \
  -target arm64-apple-macos13.0 \
  -c "$GPU_SOURCE" \
  -o "$GPU_OBJECT"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos13.0 \
  "$SOURCE" \
  "$GPU_OBJECT" \
  -framework Cocoa \
  -framework IOKit \
  -framework ServiceManagement \
  -L/usr/lib \
  -lIOReport \
  -o "$MACOS/WattBar"

rm -rf "$CONTENTS/_CodeSignature"
xattr -cr "$APP"
codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
