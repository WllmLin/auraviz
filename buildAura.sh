#!/bin/bash
set -e
DEVELOPER_DIR=/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer
export DEVELOPER_DIR
echo "Building with $DEVELOPER_DIR"
/Applications/Xcode_27.0.0_27A5237l_fb.app/Contents/Developer/usr/bin/xcodebuild -project AuraViz.xcodeproj -scheme AuraViz -configuration Debug build 2>&1 | tail -100
