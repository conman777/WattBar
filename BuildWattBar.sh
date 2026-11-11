#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/WattBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
SOURCES=("$ROOT"/Sources/WattBar/*.swift)
GPU_SOURCE="$ROOT/Tools/IOReportPower.c"
GPU_OBJECT="$ROOT/Tools/bin/IOReportPower.o"
CPU_TEMPERATURE_SOURCE="$ROOT/Tools/CPUTemperature.c"
CPU_TEMPERATURE_OBJECT="$ROOT/Tools/bin/CPUTemperature.o"
SENSORS_HEADER="$ROOT/Tools/WattBarSensors.h"
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

clang \
  -O2 \
  -target arm64-apple-macos13.0 \
  -c "$CPU_TEMPERATURE_SOURCE" \
  -o "$CPU_TEMPERATURE_OBJECT"

xcrun swiftc \
  -swift-version 5 \
  -module-cache-path "$ROOT/Tools/bin/ModuleCache" \
  -import-objc-header "$SENSORS_HEADER" \
  -O \
  -target arm64-apple-macos13.0 \
  "${SOURCES[@]}" \
  "$GPU_OBJECT" \
  "$CPU_TEMPERATURE_OBJECT" \
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
