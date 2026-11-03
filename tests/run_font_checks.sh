#!/bin/bash
# Compiles the focused font-pack checks against the app's FontCatalog and runs them.
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Same toolchain as build.sh, falling back to the default Xcode when absent.
SDK=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
TC=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
if [ ! -x "$TC/swiftc" ]; then
  SDK="$(xcrun --show-sdk-path)"
  TC="$(dirname "$(xcrun -f swiftc)")"
  PLUGIN=""
else
  PLUGIN=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
fi
LIBS=""
if [ -n "${PLUGIN:-}" ]; then
  for lib in "$PLUGIN"/*.dylib; do LIBS="$LIBS -load-plugin-library $lib"; done
fi
mkdir -p "$PROJECT_DIR/tests/build"
"$TC/swiftc" -sdk "$SDK" -target arm64-apple-macosx14.0 $LIBS \
  -o "$PROJECT_DIR/tests/build/font_checks" \
  "$PROJECT_DIR/AuraViz/FontCatalog.swift" \
  "$PROJECT_DIR/tests/FontChecks.swift"
"$PROJECT_DIR/tests/build/font_checks"
