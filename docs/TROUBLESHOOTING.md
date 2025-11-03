# MemoryWatch Troubleshooting Guide

## Common Issues and Solutions

### Permission and Access Issues

#### "Permission denied accessing /var/vm"

**Symptoms:**
```
❌ Error: Permission denied when accessing /var/vm
memwatch orphans --stale-swap fails
```

**Root Cause**: Full Disk Access not granted to MemoryWatch executable

**Solution 1: Grant Full Disk Access (GUI)**
1. Open System Preferences
2. Navigate to Security & Privacy → Full Disk Access
3. Click the lock icon to unlock
4. Click "+" and add your MemoryWatch executable
   - If CLI: `/usr/local/bin/MemoryWatch`
   - If App: `/Applications/MemoryWatch.app`
5. Lock the preferences

**Solution 2: Use sudo**
```bash
sudo memwatch orphans --stale-swap
```

**Solution 3: Grant via Terminal (macOS 11+)**
```bash
# For CLI tool
spctl --add --label "MemoryWatch" /usr/local/bin/MemoryWatch

# For app bundle
spctl --add --label "MemoryWatch" /Applications/MemoryWatch.app
```

**Verification:**
```bash
ls -la /var/vm/
# Should list swapfiles without permission error
```

---

#### "Cannot capture diagnostic artifacts"

**Symptoms:**
```
❌ Failed to capture artifacts: Operation not permitted
memwatch diagnostics 1234 fails
```

**Root Cause**: Missing process debugging entitlements

**Solution 1: Run with sudo**
```bash
sudo memwatch diagnostics 1234 --all-runtimes
```

**Solution 2: Verify entitlements**
```bash
# Check if entitlements are signed correctly
codesign -d --entitlements - /usr/local/bin/MemoryWatch | grep "device-management"

# If missing, re-sign
codesign --options runtime \
  --entitlements /path/to/entitlements.plist \
  --sign - /usr/local/bin/MemoryWatch
```

---

### Database Issues

#### "Database locked" errors

**Symptoms:**
```
❌ Error: database is locked
Database operation times out
```

**Root Cause**: Multiple processes writing simultaneously or corrupted WAL

**Solution 1: Wait for locks to clear**
```bash
# Stop monitoring
memwatch monitor &
kill %1

# Wait 5 seconds for locks to release
sleep 5

# Retry
memwatch status
```

**Solution 2: Check for stuck processes**
```bash
# List processes holding database locks
lsof | grep memorywatch.sqlite

# Kill process if needed
kill -9 <PID>
```

**Solution 3: Perform maintenance**
```bash
# Force WAL checkpoint and optimization
memwatch status  # Triggers maintenance if needed

# Or manually maintain
swift build -c release
.build/release/MemoryWatch --maintenance-now
```

**Solution 4: Reset database (last resort)**
```bash
# WARNING: This clears all history!
rm ~/MemoryWatch/data/memorywatch.sqlite*

# Restart monitoring (recreates empty database)
memwatch status
```

---

#### "Database is corrupted"

**Symptoms:**
```
database disk image is malformed
Error: database corruption detected
```

**Root Cause**: Improper shutdown, hardware issue, or write failure

**Solution 1: Try integrity check**
```bash
# Open database
sqlite3 ~/MemoryWatch/data/memorywatch.sqlite

# Check integrity
PRAGMA integrity_check;

# Check for WAL issues
PRAGMA wal_info;

# Exit
.quit
```

**Solution 2: Recover if possible**
```bash
sqlite3 ~/MemoryWatch/data/memorywatch.sqlite \
  ".mode list" \
  "PRAGMA integrity_check;" > integrity_report.txt

cat integrity_report.txt
```

**Solution 3: Backup and reset**
```bash
# Backup corrupted database
cp ~/MemoryWatch/data/memorywatch.sqlite ~/MemoryWatch/data/memorywatch.sqlite.corrupt

# Remove corrupted files
rm ~/MemoryWatch/data/memorywatch.sqlite*

# Restart (creates fresh database)
memwatch status
```

---

### Performance Issues

#### "High CPU usage from MemoryWatch"

**Symptoms:**
```
MemoryWatch process consuming 10-50% CPU
System slow when monitoring enabled
```

**Root Cause**: Leak detection or orphan scanning running too frequently

**Solution 1: Increase monitoring interval**
```bash
# Default is 10 seconds, increase to 30
memwatch config --set update_cadence_seconds=30

# Or via CLI
memwatch monitor --interval 30
```

**Solution 2: Disable expensive features**
```bash
# Disable leak detection
memwatch monitor --no-leak-detection

# Disable orphan checking
memwatch monitor --no-orphan-check

# Disable artifact capture
memwatch monitor --no-diagnostics
```

**Solution 3: Limit process tracking**
```bash
# Monitor only top N processes
memwatch monitor --max-tracked 50
```

**Solution 4: Check what's consuming CPU**
```bash
# Profile the tool
sample MemoryWatch 30 > memwatch.sample

# View the sample
open memwatch.sample
```

---

#### "Memory usage growing unbounded"

**Symptoms:**
```
MemoryWatch process grows to 500MB+
Never stops growing
```

**Root Cause**: Memory leak in monitoring loop or database connection not closing

**Solution 1: Restart monitoring**
```bash
# Kill current instance
pkill -f "memwatch monitor"

# Restart
memwatch monitor
```

**Solution 2: Check database health**
```bash
memwatch status
# Note: WAL size and page count
# Large WAL (>500MB) indicates maintenance needed
```

**Solution 3: Run maintenance**
```bash
# Manually trigger maintenance
memwatch config --set maintenance_interval_minutes=5

# Wait for next maintenance cycle, or restart daemon
```

**Solution 4: Reduce retention**
```bash
# Keep only 24 hours of data
memwatch config --set retention_window_hours=24

# Older snapshots will be automatically pruned
```

---

### CLI and Build Issues

#### "memwatch: command not found"

**Symptoms:**
```
bash: memwatch: command not found
```

**Root Cause**: Executable not in PATH

**Solution 1: Build and install**
```bash
cd MemoryWatchApp
swift build -c release

# Copy to /usr/local/bin
sudo cp .build/release/MemoryWatch /usr/local/bin/memwatch

# Verify
which memwatch
memwatch --version
```

**Solution 2: Use full path**
```bash
~/.build/release/MemoryWatch status
```

**Solution 3: Add to PATH**
```bash
# Add to ~/.bash_profile or ~/.zshrc
export PATH="$HOME/MemoryWatch/MemoryWatchApp/.build/release:$PATH"

# Reload shell
source ~/.zshrc
```

---

#### "Swift compilation fails"

**Symptoms:**
```
error: no targets specified
error: module not found
error: type mismatch
```

**Root Cause**: Missing dependencies, wrong Swift version, or corrupted build cache

**Solution 1: Clean and rebuild**
```bash
cd MemoryWatchApp
rm -rf .build

swift build -c release 2>&1 | head -50
# Read the error carefully
```

**Solution 2: Check Swift version**
```bash
swift --version
# Must be 5.9 or later

# Update if needed
xcode-select --install
```

**Solution 3: Check dependencies**
```bash
# Verify all system frameworks available
swift --version
```

**Solution 4: Check macOS version**
```bash
sw_vers
# Must be macOS 12.0 or later
```

---

### Monitoring Issues

#### "No processes detected"

**Symptoms:**
```
memwatch status returns empty list
monitoring shows 0 processes
```

**Root Cause**: Process monitor not running or permission issue

**Solution 1: Check monitor status**
```bash
# Start fresh monitoring
memwatch monitor -d 10

# Should show processes within 10 seconds
```

**Solution 2: Verify with system tools**
```bash
# Compare with ps output
ps aux | wc -l

# If ps shows processes but memwatch doesn't, it's a permissions issue
```

**Solution 3: Grant permissions**
```bash
# Grant Full Disk Access
# System Preferences > Security & Privacy > Full Disk Access > +MemoryWatch

# Or run with sudo
sudo memwatch status
```

---

#### "Leak detection never triggers"

**Symptoms:**
```
memwatch leaks returns no results
No alerts despite obvious memory growth
```

**Root Cause**: Thresholds too high, time window too short, or confidence too strict

**Solution 1: Lower confidence threshold**
```bash
# Default is 70%, try 50%
memwatch leaks --confidence 50
```

**Solution 2: Lower growth threshold**
```bash
# Default is 50MB, try 10MB
memwatch leaks --min-growth 10
```

**Solution 3: Increase time window**
```bash
# Default is 24 hours, try 48
memwatch leaks --time-window 48
```

**Solution 4: Check if data exists**
```bash
# Verify snapshots are being collected
memwatch export --format json | jq '.snapshots | length'

# Should be > 0
```

---

### Data Export Issues

#### "Export produces empty results"

**Symptoms:**
```
memwatch export --format csv outputs empty file
No data in exported files
```

**Root Cause**: No data collected yet or date range filters out all data

**Solution 1: Wait for data collection**
```bash
# Start monitoring
memwatch monitor -d 60

# Then export (wait 60+ seconds)
sleep 70
memwatch export --format json
```

**Solution 2: Check date range**
```bash
# Don't filter by date
memwatch export --format json | jq '.snapshots | length'

# If this shows data, your date filter might be wrong
memwatch export --format json --start 2025-01-01 --end 2025-12-31
```

**Solution 3: Verify database has data**
```bash
sqlite3 ~/MemoryWatch/data/memorywatch.sqlite \
  "SELECT COUNT(*) FROM process_snapshots;"

# Should be > 0
```

---

#### "Export file is truncated or corrupted"

**Symptoms:**
```
JSON is invalid or incomplete
CSV is incomplete
```

**Root Cause**: Export interrupted or database write in progress

**Solution 1: Wait and retry**
```bash
# Stop monitoring first
pkill -f "memwatch monitor"

sleep 5

# Then export
memwatch export --format json -o snapshot.json
```

**Solution 2: Use smaller time window**
```bash
# Export less data at once
memwatch export --format json \
  --start 2025-11-01 \
  --end 2025-11-02 \
  -o single_day.json
```

---

### Daemon Issues

#### "Daemon won't start"

**Symptoms:**
```
memwatch daemon exits immediately
No daemon process running
```

**Root Cause**: Permissions, database locked, or missing data directory

**Solution 1: Check data directory**
```bash
mkdir -p ~/MemoryWatch/data

# Verify permissions
ls -ld ~/MemoryWatch/
```

**Solution 2: Run in foreground first**
```bash
# See actual error messages
memwatch daemon

# Press Ctrl+C after a few seconds
# If it works in foreground, daemon launch issue is separate
```

**Solution 3: Check logs**
```bash
tail -f ~/MemoryWatch/data/memorywatch.log

# Or if using launchctl
log stream --predicate 'eventMessage contains "MemoryWatch"'
```

**Solution 4: Clear database and restart**
```bash
rm ~/MemoryWatch/data/memorywatch.sqlite*

memwatch daemon
```

---

#### "Daemon is running but not collecting data"

**Symptoms:**
```
memwatch daemon process exists
But no snapshots are being recorded
```

**Root Cause**: Monitor loop not executing or process monitor failing

**Solution 1: Check if monitor is working**
```bash
# Manually test the monitor
memwatch monitor -d 30

# If this works, daemon loop has an issue
```

**Solution 2: Check daemon logs**
```bash
tail -50 ~/MemoryWatch/data/memorywatch.log | grep -i "error\|warning"
```

**Solution 3: Restart daemon**
```bash
# Kill daemon
pkill -f "memwatch daemon"

# Wait for it to exit
sleep 2

# Restart
memwatch daemon &
```

---

### Menu Bar App Issues

#### "Menu bar app won't launch"

**Symptoms:**
```
App doesn't open
No window appears
```

**Root Cause**: App not signed/notarized, or entitlements missing

**Solution 1: Try from command line**
```bash
open /Applications/MemoryWatch.app

# Check for error messages in Terminal
```

**Solution 2: Check code signature**
```bash
codesign -v /Applications/MemoryWatch.app

# If invalid, re-sign
codesign --deep --force --verify --verbose --sign - /Applications/MemoryWatch.app
```

**Solution 3: Check Console for crashes**
```bash
# Open Console app and search for MemoryWatch
# Look for crash reports
```

---

#### "Menu bar app shows no data"

**Symptoms:**
```
App opens but shows "No data"
Metrics not updating
```

**Root Cause**: Monitoring not running or database not connected

**Solution 1: Start monitoring separately**
```bash
# Start monitoring in background
memwatch monitor &

# Then open app
open /Applications/MemoryWatch.app
```

**Solution 2: Check database connection**
```bash
# Verify database exists
ls -la ~/MemoryWatch/data/memorywatch.sqlite

# If missing, the app can't read data
memwatch status  # This will create initial data
```

---

## Advanced Troubleshooting

### Capture Debug Information

When reporting issues, collect this information:

```bash
# System information
sw_vers
swift --version

# MemoryWatch version
memwatch --version

# Database status
memwatch status --json > status.json

# Health check
sqlite3 ~/MemoryWatch/data/memorywatch.sqlite "PRAGMA integrity_check;"

# Recent logs
tail -100 ~/MemoryWatch/data/memorywatch.log > logs.txt

# Process list
ps aux | grep -i memwatch

# File permissions
ls -la ~/MemoryWatch/
```

### Enable Debug Logging

```bash
# Increase log level
export MEMORYWATCH_LOG_LEVEL=debug

# Run command
memwatch monitor -d 30

# Logs will be more verbose
```

### Monitor Database Activity

```bash
# Open database in monitor mode
sqlite3 ~/MemoryWatch/data/memorywatch.sqlite

# Run in separate terminal while memwatch is active
.mode column
.headers on

SELECT COUNT(*) as snapshots FROM process_snapshots;
SELECT COUNT(*) as alerts FROM memory_alerts;
PRAGMA wal_info;
```

### Trace System Calls

```bash
# Monitor system calls (macOS)
dtruss -f memwatch status 2>&1 | head -100

# Look for errors (permission denied, not found, etc.)
```

## When to Reset Everything

**Only do this if nothing else works:**

```bash
# Stop all monitoring
pkill -f memwatch

# Backup current data (if you want to analyze it)
tar -czf ~/memorywatch_backup_$(date +%s).tar.gz ~/MemoryWatch/

# Remove all MemoryWatch data
rm -rf ~/MemoryWatch/

# Remove from bin
rm /usr/local/bin/memwatch*

# Remove from Applications
rm -rf /Applications/MemoryWatch.app

# Rebuild and reinstall
cd MemoryWatchApp
rm -rf .build
swift build -c release
cp .build/release/MemoryWatch /usr/local/bin/memwatch

# Restart
memwatch status
```

## Getting Help

If you're still stuck:

1. **Check Documentation**: [docs/](../docs/) directory
2. **Review Code**: Look at tests for usage examples
3. **Run with Debug**: `MEMORYWATCH_LOG_LEVEL=debug memwatch status`
4. **Report Issue**: Include the debug info from "Capture Debug Information" above

## See Also

- [CLI Reference](CLI_REFERENCE.md)
- [Entitlements Guide](ENTITLEMENTS.md)
- [SQLiteStore API](SQLITE_API.md)
- [Developer Guide](DEVELOPER_GUIDE.md)
