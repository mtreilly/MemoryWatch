# MemoryWatch Release & Deployment Guide

Welcome to the launch checklist for MemoryWatch. This document explains how to build, bundle, sign, and distribute the menu bar app and CLI. It doubles as a teaching guide: you will learn why each step matters on macOS, how SwiftPM fits into the picture, and what to tweak when preparing for a production release.

---

## 1. Swift Build Fundamentals

### 1.1 Package Layout
The project is driven by Swift Package Manager (SwiftPM). `MemoryWatchApp/Package.swift` defines three products:
- `MemoryWatchCLI`: the command-line interface and daemon runtime
- `MemoryWatchMenuBar`: the menu bar app executable
- `MemoryWatchCore`: a library shared by both executables

SwiftPM builds each target into `.build/<configuration>/`. By default, `swift build` produces debug binaries; `swift build --configuration release` emits optimized binaries suitable for distribution.

### 1.2 Selecting a Product to Build
Use the `--product` flag to pick a specific executable:
```bash
swift build --configuration release --product MemoryWatchMenuBar
```
This keeps build times shorter when you only need the menu bar app. Omitting `--product` builds every executable in the manifest.

---

## 2. Creating a macOS App Bundle

### 2.1 Why Bundle?
macOS treats GUI apps as bundles (`.app`) with a specific directory structure:
```
MemoryWatch.app/
└── Contents/
    ├── Info.plist           # metadata, bundle identifier, version
    ├── MacOS/               # executable binary lives here
    └── Resources/           # icons, nibs, helper files
```
A plain binary cannot be launched from Finder or participate in login items. By wrapping the SwiftPM binary in a bundle, we gain menu-bar presence, LaunchAgent toggles, and permission prompts with the right display name.

### 2.2 Manual Bundling Script
After building the release binary, wrap it like this:
```bash
cd /Users/micheal/MemoryWatch/MemoryWatchApp
swift build --configuration release --product MemoryWatchMenuBar

APP_NAME=MemoryWatch
PRODUCT=MemoryWatchMenuBar
BUILD_DIR="$(pwd)/.build/release"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cat >"$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MemoryWatch</string>
  <key>CFBundleDisplayName</key><string>MemoryWatch</string>
  <key>CFBundleIdentifier</key><string>com.memorywatch.app</string>
  <key>CFBundleExecutable</key><string>${PRODUCT}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$BUILD_DIR/${PRODUCT}" "$APP_BUNDLE/Contents/MacOS/${PRODUCT}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${PRODUCT}"
```
`LSUIElement` keeps the app out of the Dock and ensures it lives in the menu bar only.

### 2.3 Installing for Local Testing
With the bundle prepared:
```bash
sudo rm -rf /Applications/MemoryWatch.app
sudo cp -R "$APP_BUNDLE" /Applications/MemoryWatch.app
sudo codesign --force --deep --sign - /Applications/MemoryWatch.app
```
The ad-hoc signature (`-`) prevents Gatekeeper nags and allows LaunchAgent registration. Launch via Finder or `open /Applications/MemoryWatch.app`.

---

## 3. Using Xcode (Optional)
Prefer a GUI workflow? Run `open MemoryWatchApp/Package.swift`. Xcode will treat the package as a project. Choose the `MemoryWatchMenuBar` scheme, set “Any Mac (Apple Silicon, Intel)” as the destination, and press ⌘B. Xcode places the resulting `.app` inside `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/`. Copy that bundle to `/Applications/MemoryWatch.app` and codesign as above.

---

## 4. Launch Agent Integration & Login Items

### 4.1 Why Launch Agents?
The menu bar app ships with a toggle to launch the daemon at login. On macOS, this is implemented via LaunchAgents—property-list files stored under `~/Library/LaunchAgents`. Our controller now writes a plist, bootstraps it with `launchctl`, and uses `SMAppService` (macOS 13+) for the modern login-item API. Bundled builds must have the executable path wired correctly (the new CLI-path fallback handles this).

### 4.2 Verifying the Agent
Once the app is running:
```bash
launchctl print gui/$(id -u)/com.memorywatch.app.login
```
You should see the agent definition. To test toggling manually:
```bash
launchctl bootout gui/$(id -u)/com.memorywatch.app.login
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.memorywatch.app.login.plist
```
The UI now performs these steps automatically when you flip the “Launch at Login” switch.

---

## 5. CLI Installation

To ship the `memwatch` CLI alongside the app:
1. Build the CLI binary: `swift build --configuration release --product MemoryWatch`
2. Copy it to a standard location:
   ```bash
   sudo cp MemoryWatchApp/.build/release/MemoryWatch /usr/local/bin/memwatch
   sudo chmod +x /usr/local/bin/memwatch
   ```
3. The menu bar controller first searches `$PATH` for `memwatch`. If not found, it falls back to bundled copies placed inside the app (`Contents/Resources`, `Contents/MacOS`, or `Contents/SharedSupport`).

For distribution, consider shipping the CLI inside the bundle and offer an installer script that symlinks or copies it to `/usr/local/bin`.

---

## 6. Codesigning & Notarization Primer

### 6.1 Development vs Release Signing
- **Ad-hoc (`-`)**: fine for local testing; Gatekeeper treats it as unsigned but allows execution when you explicitly open the app.
- **Developer ID Application**: required for notarized builds distributed outside the Mac App Store. Sign with your Apple Developer certificate.

Example release signing:
```bash
codesign --force --deep --timestamp \
         --sign "Developer ID Application: Your Name (TEAMID)" \
         /Applications/MemoryWatch.app
```

### 6.2 Notarization Outline
1. Archive the app: `ditto -c -k --keepParent MemoryWatch.app MemoryWatch.zip`
2. Submit to Apple: `xcrun notarytool submit MemoryWatch.zip --keychain-profile <profile> --wait`
3. Staple the ticket: `xcrun stapler staple MemoryWatch.app`

For first-time setup, create a keychain profile with `xcrun notarytool store-credentials`.

---

## 7. macOS Compatibility Notes

- The package targets macOS 13+. If you need macOS 12 support, adjust `Package.swift` and audit API usage (`ServiceManagement`’s `SMAppService` layer requires 13, so guard it as we already do).
- Universal builds: SwiftPM will build for the current architecture. For universal binaries, use Xcode or invoke `xcodebuild -scheme MemoryWatchMenuBar -configuration Release -destination 'generic/platform=macOS'`.
- Entitlements: see `docs/ENTITLEMENTS.md` for the full list. For production, create an entitlements plist and sign with it (`codesign --entitlements`).

---

## 8. Release Checklist

1. Run `scripts/release_build.sh` to build, bundle, install, and ad-hoc sign locally
2. (Optional manual path) `swift build --configuration release --product MemoryWatchMenuBar`
3. Bundle the app and copy CLI fallback into `Contents/Resources/memwatch`
4. Copy bundle to `/Applications/MemoryWatch.app`
5. Install CLI to `/usr/local/bin/memwatch`
6. Codesign (ad-hoc or Developer ID)
7. Run `swift test` to ensure unit tests pass
8. Test menu bar features: daemon start/stop, launch-at-login toggle, notifications
9. If distributing externally: notarize and staple

---

## 9. Troubleshooting

- **LaunchAgent fails to load**: check `~/Library/LaunchAgents/com.memorywatch.app.login.plist` and run `launchctl print gui/<uid>` for errors.
- **CLI not found**: verify `/usr/local/bin/memwatch` exists and is executable; otherwise ensure the app bundle contains `Contents/Resources/memwatch`.
- **Codesign errors**: inspect with `codesign -dv --verbose=4 MemoryWatch.app`. Missing entitlements or using the wrong certificate are common culprits.
- **Notarization rejection**: review the log via `xcrun notarytool log <request-id>`.

---

Armed with this guide, you can reproduce local builds confidently and understand each macOS requirement that MemoryWatch triggers. Happy releasing!
