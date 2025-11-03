# MemoryWatch

Advanced memory monitoring and leak detection for macOS, featuring intelligent orphan resource detection, runtime-specific diagnostics, and comprehensive data persistence.

![Status](https://img.shields.io/badge/status-active-brightgreen)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
![Swift](https://img.shields.io/badge/swift-5.9+-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

### Core Memory Monitoring
- **Real-time process tracking**: Memory, CPU, I/O metrics
- **Persistent snapshots**: SQLite storage with WAL optimization
- **System metrics**: Memory pressure, swap usage, cache efficiency
- **Process filtering**: By name, PID, or network port

### Leak Detection
- **Regression-based analysis**: Statistical growth pattern detection
- **High confidence**: Only alerts on probable leaks, not normal variation
- **Configurable thresholds**: Customize for your workload (default: 50MB/24h)
- **Historical trending**: 3-day retention with configurable windows

### Runtime Diagnostics
- **Chromium/Chrome/Electron**: V8 heap dump analysis
- **Node.js**: Heap snapshot collection with leak patterns
- **Xcode/Native**: Malloc stack logs via xcrun xctrace
- **Python**: Memory profiler integration
- **Extensible**: Add custom runtimes via ToolchainAdapter protocol

### Orphan Detection
- **Deleted-but-open files**: Find space-consuming deleted files still held by processes
- **Stale swapfiles**: Identify unused /var/vm accumulation
- **Zombie processes**: Report unreaped children
- **Suspended processes**: Find stuck applications
- **Automated remediation**: Specific cleanup commands

### Menu Bar App
- **Real-time metrics**: Memory, swap, process count
- **Historical sparklines**: Memory/swap trends
- **Quick actions**: Open logs, launch diagnostics
- **Accessibility**: Full keyboard navigation and VoiceOver support
- **Native SwiftUI**: Zero JavaScript, pure native performance

## Quick Start

### Installation

```bash
# Build from source
cd MemoryWatchApp
swift build -c release

# Install to /usr/local/bin
cp .build/release/MemoryWatch /usr/local/bin/
```

### First Commands

```bash
# View system memory status
memwatch status

# Start 1-minute monitoring session
memwatch monitor -d 60

# Analyze memory leaks from last 24 hours
memwatch leaks

# Detect orphaned resources
memwatch orphans
```

## Architecture

MemoryWatch combines high-performance system monitoring with intelligent diagnostics:

```
ProcessMonitor (10s) → SystemMetrics → SQLiteStore (WAL)
                           ↓
                    ProcessSnapshot
                           ↓
                    LeakHeuristics (regression)
                           ↓
                    MemoryAlert → ToolchainAdapter → Artifacts
                           ↓
                    OrphanDetector (deleted files, swap, zombies)
                           ↓
                    MenuBarApp (real-time UI)
```

**Core Components:**
- **ProcessMonitor**: Collects system snapshots every 10 seconds
- **SystemMetrics**: Gathers CPU, memory, I/O, swap statistics
- **SQLiteStore**: Persists data with WAL optimization for low latency
- **LeakHeuristics**: Regression-based growth pattern analysis
- **OrphanDetector**: Scans for orphaned resources
- **ToolchainIntegration**: Coordinates runtime-specific artifact capture
- **MenuBarApp**: SwiftUI real-time monitoring with accessibility

## Documentation

- **[CLI Reference](docs/CLI_REFERENCE.md)** - Full command documentation and examples
- **[SQLiteStore API](docs/SQLITE_API.md)** - Database persistence API with code examples
- **[Developer Guide](docs/DEVELOPER_GUIDE.md)** - Extending MemoryWatch with custom adapters
- **[Entitlements Guide](docs/ENTITLEMENTS.md)** - System permissions and security configuration
- **[Master Plan](docs/MASTER_PLAN.md)** - Implementation roadmap and architecture decisions

## Usage Examples

### Monitor System Memory

```bash
# Show current status
memwatch status

# Top 20 processes by memory
memwatch status -n 20 --json > status.json

# Sort by CPU usage
memwatch status --sort cpu
```

### Detect Memory Leaks

```bash
# Analyze last 24 hours
memwatch leaks

# Analyze specific process
memwatch leaks -p 1234 --confidence 80

# Check last 7 days with tight thresholds
memwatch leaks --time-window 168 --min-growth 10
```

### Capture Diagnostics

```bash
# Capture artifacts for Chrome process
memwatch diagnostics 1234

# Capture from all available runtimes
memwatch diagnostics 1234 --all-runtimes

# Save to custom directory
memwatch diagnostics 1234 -o /tmp/diagnostics
```

### Find Orphaned Resources

```bash
# All orphaned resources
memwatch orphans

# Large deleted files only
memwatch orphans --deleted-files --min-size 100

# Identify stale swap
memwatch orphans --stale-swap
```

### Background Monitoring

```bash
# Start daemon with alerts
memwatch daemon --log /var/log/memorywatch.log --alerts

# Monitor with custom interval
memwatch monitor -i 5 --leak-detection

# Export data
memwatch export --format csv -o weekly_metrics.csv \
  --start 2025-10-27 --end 2025-11-03
```

## Configuration

### Command-Line Options

Most commands support:
- `--json` - JSON output for scripting
- `--interval <N>` - Check interval in seconds
- `--threshold <MB>` - Memory threshold
- `--output <file>` - Write to file

See [CLI Reference](docs/CLI_REFERENCE.md) for complete options.

### Environment Variables

```bash
# Data directory
export MEMORYWATCH_HOME=/var/log/memorywatch

# Log level
export MEMORYWATCH_LOG_LEVEL=debug

# Custom database
export MEMORYWATCH_DB=/path/to/custom.sqlite
```

## Data Storage

MemoryWatch stores all data in `~/MemoryWatch/`:

| File/Directory | Purpose |
|--------|---------|
| `data/memorywatch.sqlite` | Main database with snapshots and alerts |
| `data/memorywatch.sqlite-wal` | Write-Ahead Log for fast writes |
| `data/artifacts/` | Captured diagnostic artifacts (heap dumps, profiles) |
| Logs | Event logs and monitoring records |

## System Requirements

- **OS**: macOS 12.0 or later
- **Architecture**: arm64 or x86_64
- **Permissions**:
  - Full Disk Access (for orphan detection)
  - Process monitoring (automatic)
  - Notifications (optional, for alerts)
- **Disk Space**: ~100MB for 3 days of data

## Performance

- **Memory Overhead**: ~20-30MB resident
- **CPU Usage**: <1% at 10-second intervals
- **Disk I/O**: ~2-5MB/hour
- **Database Size**: ~50MB per 24 hours

### Tuning for Resource-Constrained Systems

```bash
# Increase check interval
memwatch config --set update_cadence=30

# Reduce data retention
memwatch config --set retention_window_hours=24

# Disable expensive detection
memwatch monitor --no-leak-detection
```

## Troubleshooting

**Permission Denied Errors**:
- Grant Full Disk Access: System Preferences > Security & Privacy > Full Disk Access
- Or use `sudo memwatch orphans`

**High CPU Usage**:
- Increase monitoring interval: `memwatch monitor --interval 30`
- Disable leak detection: `--no-leak-detection`

**Database Errors**:
- Check health: `memwatch status`
- Reset: `rm ~/MemoryWatch/data/memorywatch.sqlite`

See [Troubleshooting Guide](docs/TROUBLESHOOTING.md) for more issues.

## Integration Examples

### Time Series Database

```bash
memwatch export --format json | jq '.snapshots[]' | \
  curl -X POST http://influxdb:8086/write -d @-
```

### Slack Alerts

```bash
memwatch monitor --output /tmp/memwatch.log &
tail -f /tmp/memwatch.log | grep "CRITICAL" | \
  while read line; do
    curl -X POST $SLACK_WEBHOOK -d "{\"text\":\"$line\"}"
  done
```

### Custom Analysis

```swift
// Access raw data via SQLiteStore
let store = try SQLiteStore(url: databaseURL)
let snapshots = store.getRecentSnapshots(hoursBack: 24)
let alerts = store.getAlerts(hoursBack: 24)
```

## Extensibility

MemoryWatch is designed for extension:

- **Custom Adapters**: Implement `ToolchainAdapter` for new runtimes
- **Custom Detectors**: Extend leak detection with your heuristics
- **Database Access**: Query raw data via `SQLiteStore` API
- **CLI Extensions**: Add custom commands via command registry

See [Developer Guide](docs/DEVELOPER_GUIDE.md) for details.

## Why Swift?

We chose Swift for system monitoring because:

1. **Native Performance** - Direct macOS system API access with zero overhead
2. **Lightweight** - Single binary (~3MB), no runtime dependencies
3. **Type Safety** - Compile-time guarantees for system-level code
4. **Fast Startup** - Instant execution, no interpreter overhead
5. **Accessibility** - VoiceOver/keyboard support in menu bar UI
6. **No Bloat** - Pure native code, zero JavaScript dependencies

## Contributing

Contributions welcome! Areas of interest:

- Additional runtime adapters (Go, Rust, Java, PHP)
- Advanced leak detection heuristics
- Performance optimizations
- Documentation improvements
- Localization support

## License

MIT License - See LICENSE file

## Roadmap

### Completed ✅
- Phase 1: Core monitoring with SQLite persistence
- Phase 2: Hardening & telemetry (maintenance, retention, health monitoring)
- Phase 3: Toolchain integrations (Chrome, Node, Xcode, Python adapters)
- Phase 4: Orphan detection (deleted files, stale swap, zombies)
- Phase 5: Documentation & developer experience

### Future 🔮
- Phase 6: Production deployment (code signing, notarization, distribution)
- REST API for remote monitoring
- WebUI dashboard
- Kubernetes integration
- Time series database backend plugins

## Support

- **Issues**: Report bugs on GitHub
- **Discussions**: Ask questions in GitHub Discussions
- **Docs**: See `/docs` directory for comprehensive guides

---

**Status**: Active Development
**Last Updated**: November 2025
**Maintainer**: MemoryWatch Team
