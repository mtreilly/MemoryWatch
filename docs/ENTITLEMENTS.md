# System Entitlements Guide

## Overview

MemoryWatch requires specific system entitlements and permissions to function properly on macOS. This guide explains each requirement, why it's needed, and how to configure your system.

## Required Entitlements

### 1. Process Monitoring (com.apple.security.get-task-allow)

**Purpose**: Access to process memory information and system metrics.

**Why Needed**:
- Read memory usage from running processes
- Access CPU and I/O statistics
- Monitor process state changes (creation/termination)

**Configuration**:
- Automatically granted to development builds during debugging
- Production builds should request via Info.plist:
```xml
<key>com.apple.security.get-task-allow</key>
<true/>
```

**Verification**:
```bash
codesign -d --entitlements - /Applications/MemoryWatch.app
# Should show: com.apple.security.get-task-allow = true
```

### 2. System Events Access (com.apple.security.automation)

**Purpose**: Send user notifications and interact with system.

**Why Needed**:
- Display memory alerts and warnings
- Control daemon behavior via AppleScript
- System notifications for critical conditions

**Configuration**:
```xml
<key>NSSystemAdministrationUsageDescription</key>
<string>MemoryWatch needs access to system information to monitor memory usage</string>
```

**Verification**:
```bash
# Test notification delivery
memwatch monitor --alerts
# Should receive system notifications
```

### 3. File System Access

#### Full Disk Access (com.apple.security.private-files-read-write)

**Purpose**: Scan system directories for orphaned resources.

**Why Needed**:
- Access `/var/vm` for swapfile detection
- Read `/proc` for detailed process information
- Scan `/tmp` and `/var/tmp` for temporary resources

**Scope**: System-wide file read access

**Configuration**:
**For Debug Builds**: Automatically granted during development
**For Production**: Requires macOS security exceptions:
```bash
# Grant full disk access via Privacy settings
# System Preferences > Security & Privacy > Full Disk Access > +MemoryWatch.app
```

**Verification**:
```bash
# Test swapfile detection
memwatch orphans --stale-swap
# Should list swap files in /var/vm
```

#### Temporary Directory Access

**Purpose**: Write diagnostic artifacts and export files.

**Why Needed**:
- Store heap dumps from Chrome/Node.js
- Write CSV/JSON exports from `memwatch export`
- Cache analysis results

**Default Location**: `~/MemoryWatch/data/` (user's home directory)

**Custom Location**:
```bash
export MEMORYWATCH_HOME=/var/log/memorywatch
memwatch daemon
# Data will be stored in /var/log/memorywatch/
```

### 4. Debugging & Diagnostic Tools (com.apple.security.device-management)

**Purpose**: Use system diagnostic tools like `xcrun xctrace` and heap dump triggers.

**Why Needed**:
- Trigger V8 heap dumps via SIGUSR2 signal
- Capture malloc stack logs with Xcode tools
- Access Node.js heap snapshot APIs

**Verification**:
```bash
# Test diagnostics capture
memwatch diagnostics 1234 --all-runtimes
# Should capture runtime-specific artifacts
```

## Entitlements in Code

### Swift Implementation

MemoryWatch's `Package.swift` includes proper entitlements configuration:

```swift
// For CLI builds (no special entitlements needed)
.executableTarget(
    name: "MemoryWatchCLI",
    dependencies: ["MemoryWatchCore"]
)

// For menu bar app (requires full set)
.target(
    name: "MenuBarApp",
    dependencies: ["MemoryWatchCore"],
    entitlements: ["path/to/MenuBarApp.entitlements"]
)
```

### Entitlements File Example

Create `MemoryWatchApp/Sources/MenuBarApp/MenuBarApp.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Process Monitoring -->
    <key>com.apple.security.get-task-allow</key>
    <true/>

    <!-- System Events -->
    <key>com.apple.security.automation</key>
    <true/>

    <!-- File System Read -->
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>

    <!-- Debugging -->
    <key>com.apple.security.device-management</key>
    <true/>

    <!-- Hardened Runtime -->
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
</dict>
</plist>
```

## macOS App Sandbox Configuration

### Sandbox Enablement

The menu bar application runs in a restricted sandbox for security:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
```

### Sandbox Exceptions

Required exceptions for process monitoring:

```xml
<!-- Allow process list enumeration -->
<key>com.apple.security.lists.read-write</key>
<true/>

<!-- Allow environment variable access -->
<key>com.apple.security.cs.allow-dyld-environment-variables</key>
<true/>

<!-- Allow loading external code (for diagnostic tools) -->
<key>com.apple.security.cs.allow-executable-code-modification</key>
<false/>
```

### Restricted Capabilities

MemoryWatch intentionally restricts:

- **Network**: No internet access (monitoring is local-only)
- **Camera/Microphone**: Not needed for memory monitoring
- **Contacts/Calendar**: No data access required

## Permission Dialogs

### First-Run Experience

When launching MemoryWatch for the first time, users may see permission dialogs:

1. **Full Disk Access Dialog**: Required for swapfile detection
   - User must manually grant in System Preferences
   - Location: Security & Privacy → Full Disk Access → +MemoryWatch.app

2. **Notification Permission**: For alert delivery
   - Automatic with standard macOS dialogs
   - User can deny; alerts will be silent

3. **Automation Permission**: For AppleScript communication
   - Only shown if using remote control features
   - Safe to deny for local CLI usage

### Programmatic Permission Checking

Check permission status at startup:

```swift
import Cocoa

class PermissionChecker {
    static func checkFullDiskAccess() -> Bool {
        // Try to read /var/vm - if fails, full disk access not granted
        let testPath = "/var/vm"
        return FileManager.default.fileExists(atPath: testPath)
    }

    static func checkNotificationPermission() -> Bool {
        var allowed: UNAuthorizationStatus = .notDetermined
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            allowed = settings.authorizationStatus
        }
        return allowed == .authorized
    }
}
```

## Troubleshooting Entitlements

### Issue: "Permission Denied" when running memwatch orphans

**Symptoms**:
```
❌ Error: Permission denied accessing /var/vm
```

**Solution**:
1. Check Full Disk Access is granted:
   ```bash
   # System Preferences > Security & Privacy > Full Disk Access
   # Add: /usr/local/bin/MemoryWatch or /path/to/memwatch executable
   ```
2. For system-wide monitoring, use sudo:
   ```bash
   sudo memwatch orphans
   ```

### Issue: Notifications not appearing

**Symptoms**:
```
⚠️  Alert generated but no notification displayed
```

**Solution**:
1. Check notification settings:
   ```bash
   defaults read com.apple.ncprefs.plist | grep MemoryWatch
   ```
2. Grant notification permission:
   - System Preferences > Notifications > MemoryWatch
   - Allow notifications toggle ON
3. Verify daemon logging:
   ```bash
   tail -f ~/MemoryWatch/data/memorywatch.log | grep "notification"
   ```

### Issue: "Sandbox Violation" errors

**Symptoms**:
```
Failed to capture diagnostics: Operation not permitted (Sandbox restriction)
```

**Solution**:
1. Verify entitlements are properly signed:
   ```bash
   codesign -d --entitlements - /Applications/MemoryWatch.app
   ```
2. Re-sign if needed:
   ```bash
   codesign --deep --force --verify --verbose --sign - /Applications/MemoryWatch.app
   ```
3. Check app bundle structure:
   ```bash
   ls -la /Applications/MemoryWatch.app/Contents/
   ```

### Issue: Cannot capture diagnostic artifacts

**Symptoms**:
```
❌ Failed to capture artifacts: Access denied
```

**Solution**:
1. Ensure debugging entitlement is present:
   ```bash
   codesign -d --entitlements - /Applications/MemoryWatch.app | grep "device-management"
   ```
2. Run with elevated privileges for system-wide access:
   ```bash
   sudo memwatch diagnostics 1234
   ```

## Building with Entitlements

### Development Build

```bash
cd MemoryWatchApp
swift build -c debug
# Automatically gets dev entitlements
```

### Release Build

```bash
swift build -c release

# Sign with custom entitlements
codesign --options runtime \
  --entitlements path/to/entitlements.plist \
  --sign "Developer ID Application" \
  .build/release/MemoryWatch
```

### Notarization

For App Store distribution, notarization is required:

```bash
# Create archive
ditto -c -k --sequesterRsrc .build/release/MemoryWatch MemoryWatch.zip

# Submit for notarization
xcrun altool --notarize-app \
  --file MemoryWatch.zip \
  --primary-bundle-id com.memorywatch.app \
  --username $APPLE_ID \
  --password $APPLE_PASSWORD

# Check status
xcrun altool --notarization-history 0 \
  --username $APPLE_ID \
  --password $APPLE_PASSWORD
```

## Security Best Practices

### Minimal Permissions

MemoryWatch follows the principle of least privilege:

- Requests only necessary entitlements
- No network access (local monitoring only)
- No persistent data collection
- Full Disk Access only for detecting orphaned resources

### Audit Logging

All entitlement usage is logged:

```bash
tail -f ~/MemoryWatch/data/memorywatch.log | grep "entitlements"
```

### User Control

Users can revoke entitlements anytime:
- Remove from Full Disk Access list
- Disable notifications
- Uninstall application

## See Also

- [macOS App Sandbox Overview](https://developer.apple.com/documentation/security/app_sandbox)
- [Entitlements Overview](https://developer.apple.com/documentation/bundleresources/entitlements)
- [Code Signing Your App](https://developer.apple.com/documentation/security/code_signing_your_app)
- [CLI Reference](CLI_REFERENCE.md)
- [Developer Integration Guide](DEVELOPER_GUIDE.md)
