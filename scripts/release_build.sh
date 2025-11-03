#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MemoryWatch"
PRODUCT_NAME="MemoryWatchMenuBar"
CLI_PRODUCT="MemoryWatch"
APP_DIR="$ROOT_DIR/MemoryWatchApp"
BUILD_DIR="$APP_DIR/.build/release"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

echo "==> Building release artifacts"
(
  cd "$APP_DIR"
  swift build --configuration release --product "$PRODUCT_NAME"
  swift build --configuration release --product "$CLI_PRODUCT"
)

if [[ ! -f "$BUILD_DIR/$PRODUCT_NAME" ]]; then
  echo "error: expected $BUILD_DIR/$PRODUCT_NAME to exist" >&2
  exit 1
fi

if [[ ! -f "$BUILD_DIR/$CLI_PRODUCT" ]]; then
  echo "error: expected $BUILD_DIR/$CLI_PRODUCT to exist" >&2
  exit 1
fi

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat >"$INFO_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MemoryWatch</string>
  <key>CFBundleDisplayName</key><string>MemoryWatch</string>
  <key>CFBundleIdentifier</key><string>com.memorywatch.app</string>
  <key>CFBundleExecutable</key><string>MemoryWatchMenuBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

install -m 755 "$BUILD_DIR/$PRODUCT_NAME" "$MACOS_DIR/$PRODUCT_NAME"
install -m 755 "$BUILD_DIR/$CLI_PRODUCT" "$RESOURCES_DIR/memwatch"

echo "==> Updating /Applications/$APP_NAME.app (requires sudo)"
if [[ -d "/Applications/$APP_NAME.app" ]]; then
  sudo rm -rf "/Applications/$APP_NAME.app"
fi
sudo cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"

if command -v codesign >/dev/null 2>&1; then
  echo "==> Ad-hoc signing /Applications/$APP_NAME.app"
  sudo codesign --force --deep --sign - "/Applications/$APP_NAME.app"
fi

echo "==> Installing CLI to /usr/local/bin/memwatch (requires sudo)"
sudo install -m 755 "$BUILD_DIR/$CLI_PRODUCT" /usr/local/bin/memwatch

echo "==> Build & install complete"
echo "    Launch with: open /Applications/$APP_NAME.app"
