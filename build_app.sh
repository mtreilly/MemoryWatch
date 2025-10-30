#!/usr/bin/env bash
# Build script for MemoryWatch CLI tool

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="MemoryWatch"
APP_DIR="${SCRIPT_DIR}/MemoryWatchApp"

echo "Building $APP_NAME CLI tool..."

cd "$APP_DIR"

# Build using Swift Package Manager
swift build -c release

echo "Build complete!"
echo "Binary location: $APP_DIR/.build/release/$APP_NAME"
echo ""
echo "To run:"
echo "  $APP_DIR/.build/release/$APP_NAME"
echo ""
echo "To install to /usr/local/bin:"
echo "  sudo cp $APP_DIR/.build/release/$APP_NAME /usr/local/bin/memwatch"
