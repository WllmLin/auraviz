#!/bin/bash
set -e
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
TC=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
SRC="$PROJECT_DIR/AuraViz"
PLUGIN=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
LIBS=""
for lib in $PLUGIN/*.dylib; do LIBS="$LIBS -load-plugin-library $lib"; done
echo "▸ Compiling AuraViz (arm64, macOS 14)…"
mkdir -p "$PROJECT_DIR/build/AuraViz.app/Contents/MacOS"
mkdir -p "$PROJECT_DIR/build/AuraViz.app/Contents/Resources"
$TC/swiftc -sdk $SDK -target arm64-apple-macosx14.0 $LIBS \
  -o "$PROJECT_DIR/build/AuraViz.app/Contents/MacOS/AuraViz" \
  "$SRC/AuraVizApp.swift" "$SRC/ContentView.swift" "$SRC/AudioEngineManager.swift" "$SRC/Theme.swift" \
  "$SRC/Visualizers/CircularVisualizerView.swift" "$SRC/Visualizers/WaveVisualizerView.swift" "$SRC/Visualizers/Y2KBarVisualizerView.swift"
cat > "$PROJECT_DIR/build/AuraViz.app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>AuraViz</string>
    <key>CFBundleExecutable</key><string>AuraViz</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.auraviz.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>AuraViz</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSMicrophoneUsageDescription</key><string>AuraViz needs microphone access to visualize live audio.</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Package the same complete icon set used by Xcode into the standalone app.
ICON_WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
mkdir -p "$ICON_WORK_DIR/AppIcon.iconset"
cp "$SRC/Assets.xcassets/AppIcon.appiconset"/icon_*.png "$ICON_WORK_DIR/AppIcon.iconset/"
iconutil -c icns "$ICON_WORK_DIR/AppIcon.iconset" -o "$PROJECT_DIR/build/AuraViz.app/Contents/Resources/AppIcon.icns"

echo "APPLAura" > "$PROJECT_DIR/build/AuraViz.app/Contents/PkgInfo"
codesign --force --deep --sign - "$PROJECT_DIR/build/AuraViz.app" 2>&1 | head
echo "✅ build/AuraViz.app — $(du -h "$PROJECT_DIR/build/AuraViz.app" | tail -1)"
echo "   Open with: open \"$PROJECT_DIR/build/AuraViz.app\""
