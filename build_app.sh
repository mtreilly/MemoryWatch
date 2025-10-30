#!/usr/bin/env bash
# Build script for MemoryWatch SwiftUI app

set -euo pipefail

APP_NAME="MemoryWatch"
APP_DIR="MemoryWatchApp"
BUILD_DIR="build"

echo "Building $APP_NAME..."

cd "$APP_DIR"

# Build using xcodebuild
xcodebuild -scheme MemoryWatchApp \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build

echo "Build complete!"
echo "App location: $APP_DIR/$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
echo ""
echo "To run the app:"
echo "  open $APP_DIR/$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
echo ""
echo "To install:"
echo "  cp -r $APP_DIR/$BUILD_DIR/Build/Products/Release/$APP_NAME.app /Applications/"
