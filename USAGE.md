# MemoryWatch - Complete Usage Guide

## Quick Start

```bash
# Install to system
sudo cp MemoryWatchApp/.build/release/MemoryWatch /usr/local/bin/memwatch

# Quick snapshot of current memory
memwatch snapshot

# Start continuous monitoring daemon
memwatch daemon

# Check for memory leaks
memwatch suspects

# View full report
memwatch report
```

## Command Reference

### Snapshot Mode (default)

Shows instant system overview:

```bash
memwatch snapshot
```

**Output:**
- System memory (total, used, free, pressure)
- Swap usage with alerts
- Top 15 memory-consuming processes (>50MB)

**Use when:**
- Quick system check
- Identifying current memory hogs
- Checking swap usage

---

### Disk I/O Activity

Identify top disk writers/readers and potential heavy I/O processes:

```bash
memwatch io
```

Shows per-process write/read rates (B/s, KB/s, MB/s) sampled over ~0.6s.

Use when:
- Investigating SSD churn or slowdowns
- Detecting processes persistently writing logs or caches

---

### Find Deleted-But-Open Files

Detect files that were deleted but are still held open by a process (space won’t free until closed):

```bash
memwatch dangling-files
```

Note: Uses `lsof`; may require admin permissions depending on your system.

---

### Daemon Mode

Continuous monitoring with leak detection:

```bash
memwatch daemon
```

**Features:**
- Monitors every 30 seconds
- Tracks all processes >50MB
- Detects 4 types of memory issues:
  - 🚨 **Rapid Growth**: >100MB in single scan
  - 🔴 **High Growth**: >100MB/hour sustained
  - 🟠 **Medium Growth**: >50MB/hour
  - 🟡 **Low Growth**: >10MB/hour
- Saves state every 10 scans (5 minutes)
- Generates hourly reports (every 120 scans)

**Output Example:**
```
[09:56:06] Scan #2
  Memory: 7.8/18.0GB  Swap: 578MB  Pressure: Warning
  Processes: 58  Suspects: 0  Alerts: 0
```

**Stop:** Press Ctrl+C for final report

**State File:** `~/MemoryWatch/memwatch_state.json`

---

### Report Mode

Display leak detection analysis:

```bash
memwatch report
memwatch report --json                # JSON output
memwatch report --json --min-level high --recent-alerts 20
```

**Shows:**
- Leak suspects with suspicion levels
- Recent memory alerts
- Growth rates and trends
- Monitoring statistics

**Requires:** Daemon must have run first

---

### Suspects Mode

List all potential memory leaks:

```bash
memwatch suspects
memwatch suspects --json              # JSON output
memwatch suspects --min-level medium --max 5
```

**Output Example:**
```
1. 🔴 node (PID 9301)
   Level:    High
   Growth:   500MB → 850MB (+350MB)
   Rate:     70.0 MB/hour
   Duration: 5h 12m
   Trend:    📈 Growing (+15MB/interval)
```

**Suspicion Levels:**
- 🟡 **Low**: Minor growth, worth watching
- 🟠 **Medium**: Moderate growth, investigate soon
- 🔴 **High**: Significant growth, likely leak
- 🚨 **Critical**: Rapid spike, immediate attention

---

## Real-World Usage Examples

### Scenario 1: Investigating System Slowdown

```bash
# 1. Check current state
memwatch snapshot

# 2. If swap is high, start monitoring
memwatch daemon

# 3. Let run for 1+ hours, then check
memwatch suspects

# 4. View full analysis
memwatch report
```

### Scenario 2: Debugging Application Memory Leak

```bash
# 1. Start daemon before running your app
memwatch daemon &

# 2. Run your application
./my_app

# 3. After some time, check for leaks
memwatch suspects

# 4. Stop daemon when done
fg  # Bring daemon to foreground
^C  # Ctrl+C to stop and see report
```

### Scenario 3: Long-term Monitoring

Add to crontab or launchd:

**crontab:**
```bash
# Start on reboot
@reboot /usr/local/bin/memwatch daemon >> ~/MemoryWatch/daemon.log 2>&1

# Daily report
0 9 * * * /usr/local/bin/memwatch report | mail -s "Memory Report" user@example.com
```

**LaunchAgent** (`~/Library/LaunchAgents/com.memorywatch.plist`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.memorywatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/memwatch</string>
        <string>daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/YOUR_USERNAME/MemoryWatch/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOUR_USERNAME/MemoryWatch/daemon.err</string>
</dict>
</plist>
```

Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.memorywatch.plist
```

---

## Understanding the Output

### Memory Pressure Indicators

- 🟢 **Normal** (>50% free): System healthy
- 🟡 **Warning** (25-50% free): Monitor closely
- 🔴 **Critical** (<25% free): Take action

### Swap Alerts

- **<512MB**: Normal operating range
- **512MB-1GB**: ⚠️  Warning - monitor
- **>1GB**: 🚨 Critical - add RAM or find leak

### Process Trends

- **📈 Growing**: Memory increasing consistently
- **📉 Shrinking**: Memory decreasing (good!)
- **➡️ Stable**: No significant change

---

## Leak Detection Algorithm

MemoryWatch uses multiple heuristics to detect leaks:

### 1. Rapid Growth Detection
- Threshold: >100MB in 30 seconds
- Level: 🚨 Critical
- Action: Immediate alert

### 2. Steady Growth Rate
- High: >100MB/hour → 🔴
- Medium: >50MB/hour → 🟠
- Low: >10MB/hour → 🟡

### 3. Trend Analysis
- Analyzes last 10 snapshots
- Calculates average growth per interval
- Identifies consistent growth patterns

### 4. Historical Tracking
- Keeps up to 1000 snapshots per process
- Analyzes from first observation
- Cleans up stale data (>1 hour inactive)

---

## Data Management

### State File

**Location:** `~/MemoryWatch/memwatch_state.json`

**Contents:**
- All process snapshots
- Timestamps and memory readings
- Used to resume monitoring

**Size:** Grows over time, auto-limited to 1000 snapshots/process

### Maintenance

```bash
# Clear all monitoring data (fresh start)
rm ~/MemoryWatch/memwatch_state.json

# View raw state (JSON)
cat ~/MemoryWatch/memwatch_state.json | python3 -m json.tool | less

# Check state file size
ls -lh ~/MemoryWatch/memwatch_state.json
```

---

## Performance

| Mode | CPU | Memory | Disk I/O |
|------|-----|--------|----------|
| Snapshot | <0.1% | 3MB | None |
| Daemon | <1% | 5-10MB | Minimal (every 5min) |

**Process overhead:**
- Scans ~60-100 processes
- Filters to ~50-70 processes >50MB
- Stores ~200-500 snapshots typical

---

## Troubleshooting

### "No monitoring data found"

**Problem:** Running report or suspects without daemon data

**Solution:**
```bash
# Start daemon first
memwatch daemon
# Let run for at least 5 minutes (10 scans)
# Then check reports
```

### "Processes: 0" in daemon

**Problem:** Permission issue (shouldn't happen with proc_pidinfo)

**Solution:**
- Rebuild: `./build_app.sh`
- Check macOS version (needs 10.13+)

### State file growing too large

**Problem:** Running daemon for weeks/months

**Solution:**
```bash
# Archive and reset
mv ~/MemoryWatch/memwatch_state.json ~/MemoryWatch/memwatch_state_$(date +%Y%m%d).json.bak
# Daemon will start fresh
```

### False positive leak detection

**Problem:** Normal app behavior flagged as leak

**Tuning:**
- Edit thresholds in `ProcessMonitor.swift`:
  - `rapidGrowthThresholdMB`
  - `steadyGrowthThresholdMBPerHour`
- Rebuild and reinstall

---

## Advanced Usage

### Custom Monitoring Intervals

Use CLI option:
```bash
memwatch daemon --interval 60
```

### Lower Memory Threshold

Use CLI options:
```bash
memwatch snapshot --min-mem-mb 20
memwatch daemon --min-mem-mb 20
```

### Integration with Prometheus

Export metrics:
```bash
# Add to crontab
*/5 * * * * /usr/local/bin/memwatch report | /usr/local/bin/parse_to_prometheus.sh
```

---

## Comparison with Activity Monitor

| Feature | MemoryWatch | Activity Monitor |
|---------|-------------|------------------|
| Leak Detection | ✅ Automatic | ❌ Manual |
| Historical Trends | ✅ Yes | ❌ No |
| CLI/Scriptable | ✅ Yes | ❌ GUI only |
| Alerting | ✅ Built-in | ❌ None |
| Lightweight | ✅ 199KB binary | ❌ Full app |
| Real-time | ✅ 30s intervals | ✅ Live |
| Process Details | ✅ Basic | ✅ Comprehensive |

**Use MemoryWatch for:** Long-term monitoring, automation, leak detection
**Use Activity Monitor for:** Real-time investigation, detailed process info

---

## Next Steps

1. **Install globally:**
   ```bash
   sudo cp MemoryWatchApp/.build/release/MemoryWatch /usr/local/bin/memwatch
   ```

2. **Start monitoring:**
   ```bash
  nohup memwatch daemon > ~/MemoryWatch/daemon.log 2>&1 &
   ```

3. **Check daily:**
   ```bash
  memwatch suspects
   ```

4. **Set up auto-start:** Use LaunchAgent (see above)

---

## Support & Contribution

- **Issues:** Check daemon.log for errors
- **Source:** All code in `MemoryWatchApp/Sources/`
- **Customization:** Edit Swift files and rebuild

**Key Files:**
- `CLIArgumentParser.swift` - Subcommands and entry point
- `Handlers.swift` - CLI implementations (snapshot, daemon, io, etc.)
- `ProcessMonitor.swift` - Leak detection logic
- `SystemMetrics.swift` - Memory/process collection
