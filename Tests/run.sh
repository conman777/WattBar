#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/Tools/bin/tests"
mkdir -p "$BUILD"
SOURCES=()
for source in "$ROOT"/Sources/WattBar/*.swift; do
    [[ "$(basename "$source")" == main.swift ]] || SOURCES+=("$source")
done
clang -O2 -target arm64-apple-macos13.0 -c "$ROOT/Tools/IOReportPower.c" -o "$BUILD/IOReportPower.o"
clang -O2 -target arm64-apple-macos13.0 -c "$ROOT/Tools/CPUTemperature.c" -o "$BUILD/CPUTemperature.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -module-cache-path "$ROOT/Tools/bin/ModuleCache" -import-objc-header "$ROOT/Tools/WattBarSensors.h" \
    "${SOURCES[@]}" "$ROOT/Tests/main.swift" "$BUILD/IOReportPower.o" "$BUILD/CPUTemperature.o" \
    -framework Cocoa -framework IOKit -framework ServiceManagement -lIOReport -o "$BUILD/WattBarTests"
"$BUILD/WattBarTests" "$@"

clang -O2 -target arm64-apple-macos13.0 "$ROOT/Tests/CPUTemperatureCacheTests.c" -framework IOKit -framework CoreFoundation -o "$BUILD/CPUTemperatureCacheTests"
"$BUILD/CPUTemperatureCacheTests"
