# MemoryWatch

A comprehensive macOS memory monitoring system designed to detect memory leaks, track swap usage, and prevent SSD wear from excessive swap usage.

## Features

### 🔍 Memory Leak Detection
- Automatic detection of processes with rapid memory growth (>100MB)
- Tracks process memory over time to identify leaks
- Captures detailed samples using macOS `sample` and `leaks` tools

### 💾 Swap Monitoring
- Real-time swap usage tracking
- SSD wear estimation from swap writes
- Alerts when swap usage exceeds thresholds

### 📊 Analysis & Reporting
- Generate daily/weekly memory usage reports
- Identify top memory consumers
- Track memory growth trends
- Historical data analysis

### 🖥️ Native macOS GUI (SwiftUI)
- Real-time memory monitoring
- System overview with memory pressure indicators
- Process list with search and sorting
- Menu bar integration for quick access
- Zero JavaScript - pure native performance

## Components

### 1. Memory Watcher Script (`memory_watcher.sh`)

Background daemon that monitors system memory continuously.

**Features:**
- Logs top N memory-consuming processes
- Tracks swap usage and pressure
- Auto-samples processes exceeding thresholds
- Detects potential memory leaks
- Minimal overhead (runs every 30s by default)

**Usage:**
```bash
# Run with defaults
./memory_watcher.sh

# Custom configuration
INTERVAL_SEC=60 TOP_N=15 RSS_ALERT_MB=2048 ./memory_watcher.sh

# Run in background
nohup ./memory_watcher.sh > /dev/null 2>&1 &
```

**Configuration:**
- `INTERVAL_SEC` - Seconds between snapshots (default: 30)
- `TOP_N` - Number of top processes to log (default: 10)
- `RSS_ALERT_MB` - Sample process if RSS >= this (default: 1024)
- `SWAP_ALERT_MB` - Alert if swap used >= this (default: 512)
- `LEAK_GROWTH_MB` - Flag potential leak if growth >= this (default: 100)
- `LEAK_CHECK_INTERVALS` - Check for leaks every N intervals (default: 10)

### 2. Analysis Tool (`analyze.py`)

Generate comprehensive reports from collected data.

**Usage:**
```bash
# Generate report for last 24 hours
./analyze.py

# Custom time range (hours)
./analyze.py 48

# Generate weekly report
./analyze.py 168
```

**Output:**
- Top memory growth processes
- Swap usage statistics
- SSD wear estimates
- Potential memory leak alerts

### 3. SwiftUI GUI App (`MemoryWatchApp`)

Native macOS application for real-time monitoring.

**Features:**
- **Overview Tab**: System memory, swap usage, top processes
- **Processes Tab**: Searchable table of all running processes
- **Alerts Tab**: Memory leak warnings and high usage alerts
- **Menu Bar**: Quick access to key metrics

**Building:**
```bash
# Build the app
./build_app.sh

# Or manually with Xcode
cd MemoryWatchApp
xcodebuild -scheme MemoryWatchApp -configuration Release build

# Install to Applications
cp -r MemoryWatchApp/build/Build/Products/Release/MemoryWatch.app /Applications/
```

**Requirements:**
- macOS 13.0+ (Ventura or later)
- Xcode 14.0+
- Swift 5.7+

## Data Files

All data is stored in `~/MemoryWatch/`:

| File | Description |
|------|-------------|
| `memory_log.csv` | Top N processes per interval with memory stats |
| `swap_history.csv` | Swap usage over time with pressure data |
| `memory_leaks.log` | Potential memory leak detections |
| `events.log` | High-level events and sampling triggers |
| `samples/` | Detailed process samples from `sample` tool |
| `report_*.txt` | Generated analysis reports |

## Quick Start

1. **Clone and setup:**
   ```bash
   cd ~/MemoryWatch
   chmod +x memory_watcher.sh analyze.py build_app.sh
   ```

2. **Start monitoring:**
   ```bash
   # Terminal mode
   ./memory_watcher.sh

   # Or background mode
   nohup ./memory_watcher.sh > /dev/null 2>&1 &
   ```

3. **Build GUI app:**
   ```bash
   ./build_app.sh
   open MemoryWatchApp/build/Build/Products/Release/MemoryWatch.app
   ```

4. **Generate reports:**
   ```bash
   ./analyze.py
   ```

## LaunchAgent Setup (Auto-start on boot)

Create `~/Library/LaunchAgents/com.memorywatch.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.memorywatch.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/MemoryWatch/memory_watcher.sh</string>
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

Load the agent:
```bash
launchctl load ~/Library/LaunchAgents/com.memorywatch.daemon.plist
```

## Understanding the Output

### Memory Leak Detection
A process is flagged as a potential leak when:
- It grows by >100MB between checks (configurable)
- Growth is consistent over multiple intervals

Example alert:
```
[2025-10-30 08:30:00] POTENTIAL LEAK: Chrome (PID 1234) grew 250MB: 1800MB -> 2050MB
```

### Swap Usage Alerts
High swap usage (>1GB) triggers warnings because:
- Causes system slowdown
- Increases SSD wear
- May indicate insufficient RAM

### SSD Wear Estimation
The analyzer estimates SSD writes from swap usage:
- Each swap operation writes to SSD
- Excessive swap can reduce SSD lifespan
- Monitor `estimated_ssd_writes_mb` in reports

## Performance Impact

| Component | CPU Usage | Memory Usage | Disk I/O |
|-----------|-----------|--------------|----------|
| `memory_watcher.sh` | <1% | ~5MB | Minimal (30s interval) |
| `analyze.py` | <5% (when running) | ~20MB | Read-only |
| SwiftUI App | <2% | ~30MB | None |

The monitoring system is designed to have minimal overhead while providing comprehensive insights.

## Troubleshooting

### Sample collection fails
```
[2025-10-30 08:30:00] sample failed for pid=12345
```

**Solution:**
1. Check if `sample` tool exists: `which sample`
2. Process may have terminated before sampling
3. Increase `INTERVAL_SEC` to catch longer-lived processes

### High CPU usage from watcher
- Increase `INTERVAL_SEC` (e.g., 60s instead of 30s)
- Reduce `TOP_N` (fewer processes to track)
- Disable leak checking: `LEAK_CHECK_INTERVALS=0`

### GUI app won't build
- Ensure Xcode is installed: `xcode-select --install`
- Open project in Xcode first to resolve any signing issues
- Check macOS version (requires 13.0+)

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  MemoryWatch System                 │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌──────────────┐      ┌──────────────┐            │
│  │   Bash       │      │   Python     │            │
│  │   Watcher    │─────▶│   Analyzer   │            │
│  │  (daemon)    │      │  (reports)   │            │
│  └──────────────┘      └──────────────┘            │
│         │                                           │
│         ▼                                           │
│  ┌──────────────────────────────────┐              │
│  │      Data Files (CSV/Logs)       │              │
│  │  • memory_log.csv                │              │
│  │  • swap_history.csv              │              │
│  │  • memory_leaks.log              │              │
│  └──────────────────────────────────┘              │
│         │                                           │
│         ▼                                           │
│  ┌──────────────┐                                  │
│  │   SwiftUI    │                                  │
│  │   GUI App    │  ◀─── Direct system APIs         │
│  │  (realtime)  │                                  │
│  └──────────────┘                                  │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Why SwiftUI over Golang Fyne?

We chose SwiftUI for the GUI because:

1. **Native Performance** - Direct access to macOS system APIs with zero overhead
2. **Lightweight** - Compiled binary, no runtime dependencies
3. **Efficient Rendering** - Metal-accelerated graphics
4. **System Integration** - Menu bar, notifications, native look & feel
5. **Low Battery Impact** - Optimized for Apple Silicon
6. **No Bloat** - Zero JavaScript, pure native code

Fyne would add Go runtime overhead and doesn't integrate as deeply with macOS.

## Contributing

Contributions welcome! Areas for improvement:
- Add notification center integration
- Export reports to CSV/JSON
- Add charts for historical trends
- Process-specific memory profiling
- Network usage correlation

## License

MIT License - Feel free to use and modify for your needs.

## Credits

Built with native macOS technologies:
- SwiftUI for GUI
- `vm_statistics` for memory metrics
- `task_info` for process details
- `sample` and `leaks` for profiling
