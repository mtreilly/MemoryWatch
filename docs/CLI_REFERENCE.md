# MemoryWatch CLI Reference

## Overview

MemoryWatch provides a command-line interface for monitoring process memory usage, detecting memory leaks, and managing system resources. The CLI can run in daemon mode for continuous monitoring or as a one-shot utility.

## Installation

```bash
# Build from source
cd MemoryWatchApp
swift build -c release

# The executable will be in .build/release/MemoryWatch
```

## Global Options

- `--help` - Display help information for a command
- `--version` - Show MemoryWatch version

## Commands

### `memwatch status`

Display current system memory status and top memory consumers.

**Usage:**
```bash
memwatch status [options]
```

**Options:**
- `-n, --count <N>` - Number of top processes to display (default: 10)
- `--json` - Output in JSON format
- `--sort <column>` - Sort by: memory, cpu, name (default: memory)

**Example:**
```bash
# Show top 15 processes by memory usage
memwatch status -n 15

# Export status as JSON
memwatch status --json > status.json

# Sort by CPU usage
memwatch status --sort cpu
```

**Output:**
Shows a table with columns:
- PID: Process identifier
- Memory: Resident memory usage in MB
- CPU: CPU usage percentage
- %Mem: Percentage of total system memory
- Name: Process name

### `memwatch monitor`

Start continuous monitoring with configurable intervals and alerts.

**Usage:**
```bash
memwatch monitor [options]
```

**Options:**
- `-i, --interval <seconds>` - Check interval (default: 10)
- `-d, --duration <seconds>` - Monitor duration (0 = indefinite)
- `--high-mem-threshold <MB>` - Alert if process exceeds MB (default: 1024)
- `--leak-detection` - Enable memory leak detection (default: on)
- `--output <file>` - Write events to log file

**Example:**
```bash
# Monitor for 1 hour with 5-second intervals
memwatch monitor -i 5 -d 3600

# Monitor with custom thresholds
memwatch monitor --high-mem-threshold 2048 --output monitoring.log

# Enable disk output and leak detection
memwatch monitor --leak-detection --output /var/log/memorywatch.log
```

### `memwatch leaks`

Analyze memory usage patterns and report suspected memory leaks.

**Usage:**
```bash
memwatch leaks [options]
```

**Options:**
- `-p, --pid <PID>` - Analyze specific process (default: all)
- `--min-growth <MB>` - Minimum growth to report (default: 50)
- `--time-window <hours>` - Analysis window (default: 24)
- `--confidence <percent>` - Confidence threshold (default: 70)

**Example:**
```bash
# Find all processes with suspected leaks over 24 hours
memwatch leaks

# Analyze specific process with tight thresholds
memwatch leaks -p 1234 --min-growth 10 --confidence 80

# Check growth over last week
memwatch leaks --time-window 168
```

**Output:**
Reports processes ranked by suspicion level:
- **Critical**: High confidence leaks requiring immediate attention
- **High**: Significant growth patterns consistent with leaks
- **Medium**: Moderate growth, possible leaks
- **Low**: Minimal growth, likely normal behavior

### `memwatch diagnostics <PID>`

Capture runtime-specific diagnostic artifacts for a process.

**Usage:**
```bash
memwatch diagnostics <PID> [options]
```

**Arguments:**
- `PID` - Process ID to diagnose

**Options:**
- `-o, --output <path>` - Save artifacts to directory
- `--all-runtimes` - Capture from all supported runtimes
- `--timeout <seconds>` - Artifact capture timeout (default: 30)

**Example:**
```bash
# Capture artifacts for Chrome process
memwatch diagnostics 1234

# Save to custom directory with longer timeout
memwatch diagnostics 5678 -o /tmp/diagnostics --timeout 60

# Capture from all available runtimes
memwatch diagnostics 1234 --all-runtimes
```

**Supported Runtimes:**
- Chromium (Chrome, Electron) - V8 heap dumps
- Node.js - Heap snapshots with leak pattern detection
- Xcode (native apps) - Malloc stack logs
- Python - Memory profiler outputs

### `memwatch orphans`

Detect and report orphaned resources consuming disk space.

**Usage:**
```bash
memwatch orphans [options]
```

**Options:**
- `--deleted-files` - Report deleted-but-open files
- `--stale-swap` - Report stale swapfiles
- `--zombie-procs` - Report zombie processes
- `--min-size <MB>` - Minimum size to report (default: 10)
- `--sort <type>` - Sort by: size, age, severity (default: size)

**Example:**
```bash
# Find all orphaned resources
memwatch orphans

# Focus on large deleted files
memwatch orphans --deleted-files --min-size 100

# Report zombie processes and aged swap
memwatch orphans --zombie-procs --stale-swap
```

**Output:**
Categorized report of:
- **Deleted Files**: Files removed but still held open by processes
- **Swapfiles**: Inactive swapfiles accumulating on disk
- **Zombies**: Processes in zombie state needing parent cleanup

### `memwatch daemon`

Run MemoryWatch as a background daemon.

**Usage:**
```bash
memwatch daemon [options]
```

**Options:**
- `--interval <seconds>` - Check interval (default: 10)
- `--log <file>` - Log file path
- `--pid-file <path>` - PID file for daemon tracking
- `--alerts` - Send system alerts for critical conditions

**Example:**
```bash
# Start daemon with default settings
memwatch daemon

# Start with logging and alerts
memwatch daemon --log /var/log/memorywatch.log --alerts

# Custom interval with PID tracking
memwatch daemon --interval 5 --pid-file /var/run/memorywatch.pid
```

### `memwatch export`

Export collected metrics to various formats.

**Usage:**
```bash
memwatch export [options]
```

**Options:**
- `--format <type>` - Format: json, csv, html (default: json)
- `-o, --output <file>` - Output file path
- `--start <date>` - Start date (ISO 8601)
- `--end <date>` - End date (ISO 8601)
- `--include <fields>` - Comma-separated fields to include

**Example:**
```bash
# Export last 7 days as CSV
memorywatch export --format csv -o weekly_report.csv \
  --start 2025-10-27 --end 2025-11-03

# HTML report with specific fields
memwatch export --format html -o report.html \
  --include pid,name,memory,cpu_percent,timestamp

# JSON snapshot with latest data
memwatch export --format json -o snapshot.json
```

### `memwatch config`

Manage MemoryWatch configuration.

**Usage:**
```bash
memwatch config [options]
```

**Options:**
- `--list` - Show current configuration
- `--set <key=value>` - Set configuration value
- `--reset` - Reset to defaults
- `--file <path>` - Use custom config file

**Example:**
```bash
# Show current configuration
memwatch config --list

# Set memory threshold
memwatch config --set high_memory_threshold_mb=2048

# Change update cadence
memwatch config --set update_cadence_seconds=15

# Reset to defaults
memwatch config --reset
```

## Daemon Mode Operation

### Starting the Daemon

```bash
# Start as background service
memwatch daemon &

# Or with systemd (if configured)
systemctl start memorywatch
```

### Stopping the Daemon

```bash
# Kill by process name
killall MemoryWatch

# Or using PID file
kill $(cat /var/run/memorywatch.pid)
```

### Viewing Daemon Logs

```bash
# Real-time log monitoring
tail -f /var/log/memorywatch.log

# Recent entries
log stream --predicate 'eventMessage contains "MemoryWatch"'
```

## Exit Codes

- `0` - Success
- `1` - General error
- `2` - Invalid arguments
- `3` - Configuration error
- `4` - Database error
- `5` - System error (no permission, etc.)

## Examples

### Daily Leak Analysis

```bash
# Run analysis and save report
memwatch leaks --time-window 24 \
  --confidence 75 > leak_report.txt

# Check for critical leaks
memwatch leaks --confidence 90 | grep -i critical
```

### Continuous Monitoring with Export

```bash
# Start monitoring
memwatch monitor -i 10 --output monitoring.log &

# After monitoring period, export data
sleep 3600
memwatch export --format csv -o hourly_metrics.csv
```

### Orphan Resource Cleanup

```bash
# Find large deleted files
memwatch orphans --deleted-files --min-size 500

# Identify stale swap
memwatch orphans --stale-swap

# Kill zombie processes
memwatch status | grep Z  # Identify zombies
kill -9 <zombie_pid>      # Clean up
```

## Environment Variables

- `MEMORYWATCH_HOME` - Directory for config and data (default: `~/MemoryWatch`)
- `MEMORYWATCH_LOG_LEVEL` - Log level: debug, info, warn, error (default: info)
- `MEMORYWATCH_DB` - Path to SQLite database

## Troubleshooting

### Permission Denied Errors

Some operations require elevated privileges:

```bash
# Run with sudo for system-wide monitoring
sudo memwatch monitor

# Or grant capabilities
sudo chmod u+s /path/to/MemoryWatch
```

### High CPU Usage

If MemoryWatch itself uses high CPU:

```bash
# Increase check interval
memwatch monitor --interval 30

# Check configuration
memwatch config --list | grep interval
```

### Database Errors

If the database becomes corrupted:

```bash
# Check database integrity
memwatch status

# Reset database (clears history)
rm ~/MemoryWatch/data/memorywatch.sqlite
memwatch daemon  # Recreates on startup
```

## Integration with Other Tools

### Export to Time Series Database

```bash
# Export JSON and process with jq
memwatch export --format json | \
  jq '.snapshots[] | {timestamp, memory: .metrics.usedMemoryGB}' | \
  # Send to InfluxDB, Prometheus, etc.
```

### Alert Integration

```bash
# Custom alert handler
memwatch monitor --output /tmp/memwatch.log
tail -f /tmp/memwatch.log | \
  grep "CRITICAL" | \
  while read line; do
    # Send to PagerDuty, Slack, etc.
    curl -X POST https://hooks.slack.com/... -d "$line"
  done
```

## Performance Tuning

### Memory-Constrained Systems

```bash
# Increase intervals, reduce retention
memwatch config --set update_cadence_seconds=30
memwatch config --set retention_window_hours=24
```

### High-Performance Monitoring

```bash
# Decrease intervals for finer granularity
memwatch monitor --interval 1 --high-mem-threshold 512
```

## See Also

- [System Entitlements Guide](ENTITLEMENTS.md)
- [SQLiteStore API Reference](SQLITE_API.md)
- [Developer Integration Guide](DEVELOPER_GUIDE.md)
