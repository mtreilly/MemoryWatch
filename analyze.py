#!/usr/bin/env python3
"""
Memory Watch Analyzer - Generate reports from memory logs
Analyzes memory_log.csv, swap_history.csv, and memory_leaks.log
"""

import csv
import json
import sqlite3
import sys
from collections import defaultdict
from contextlib import closing
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional

LOG_DIR = Path.home() / "MemoryWatch"
DATA_DIR = LOG_DIR / "data"
DB_FILE = DATA_DIR / "memorywatch.sqlite"
PREFERENCES_FILE = DATA_DIR / "notification_preferences.json"
CSV_FILE = LOG_DIR / "memory_log.csv"
SWAP_FILE = LOG_DIR / "swap_history.csv"
LEAKS_FILE = LOG_DIR / "memory_leaks.log"
EVENTS_FILE = LOG_DIR / "events.log"


def parse_timestamp(ts: str) -> datetime:
    """Parse timestamp from logs"""
    return datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")


def minutes_to_hhmm(minutes: int) -> str:
    minutes = minutes % (24 * 60)
    hours = minutes // 60
    mins = minutes % 60
    return f"{hours:02d}:{mins:02d}"


def analyze_memory_trends(hours: int = 24, conn: Optional[sqlite3.Connection] = None) -> List[Dict]:
    """Analyze memory usage trends over the last N hours"""
    if conn is not None:
        return _analyze_memory_trends_sqlite(conn, hours)
    if DB_FILE.exists():
        with closing(sqlite3.connect(DB_FILE)) as db:
            return _analyze_memory_trends_sqlite(db, hours)
    return _analyze_memory_trends_csv(hours)


def _analyze_memory_trends_sqlite(conn: sqlite3.Connection, hours: int) -> List[Dict]:
    cutoff_ts = (datetime.now() - timedelta(hours=hours)).timestamp()
    process_data = defaultdict(lambda: {"max_rss": 0, "samples": [], "cmd": ""})

    query = """
        SELECT ps.pid,
               ps.name,
               ps.memory_mb,
               s.timestamp
        FROM process_samples ps
        JOIN snapshots s ON ps.snapshot_id = s.id
        WHERE s.timestamp >= ?
        ORDER BY s.timestamp ASC
    """

    for pid, name, memory_mb, ts in conn.execute(query, (cutoff_ts,)):
        timestamp = datetime.fromtimestamp(ts)
        process_data[pid]["samples"].append((timestamp, memory_mb))
        process_data[pid]["max_rss"] = max(process_data[pid]["max_rss"], memory_mb)
        process_data[pid]["cmd"] = name

    results: List[Dict] = []
    for pid, data in process_data.items():
        if len(data["samples"]) < 2:
            continue

        samples = sorted(data["samples"], key=lambda x: x[0])
        first_rss = samples[0][1]
        last_rss = samples[-1][1]
        growth = last_rss - first_rss
        growth_pct = (growth / first_rss * 100) if first_rss > 0 else 0

        results.append({
            "pid": pid,
            "command": data["cmd"],
            "first_rss": first_rss,
            "last_rss": last_rss,
            "max_rss": data["max_rss"],
            "growth_mb": growth,
            "growth_pct": growth_pct,
            "samples": len(samples),
        })

    return sorted(results, key=lambda x: x["growth_mb"], reverse=True)


def _analyze_memory_trends_csv(hours: int) -> List[Dict]:
    if not CSV_FILE.exists():
        return []

    cutoff = datetime.now() - timedelta(hours=hours)
    process_data = defaultdict(lambda: {"max_rss": 0, "samples": [], "cmd": ""})

    with open(CSV_FILE) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                ts = parse_timestamp(row["timestamp"])
                if ts < cutoff:
                    continue

                pid = row["pid"]
                rss_mb = float(row["rss_mb"])
                cmd = row["command"]

                process_data[pid]["samples"].append((ts, rss_mb))
                process_data[pid]["max_rss"] = max(process_data[pid]["max_rss"], rss_mb)
                process_data[pid]["cmd"] = cmd
            except (ValueError, KeyError):
                continue

    results = []
    for pid, data in process_data.items():
        if len(data["samples"]) < 2:
            continue

        samples = sorted(data["samples"], key=lambda x: x[0])
        first_rss = samples[0][1]
        last_rss = samples[-1][1]
        growth = last_rss - first_rss
        growth_pct = (growth / first_rss * 100) if first_rss > 0 else 0

        results.append({
            "pid": pid,
            "command": data["cmd"],
            "first_rss": first_rss,
            "last_rss": last_rss,
            "max_rss": data["max_rss"],
            "growth_mb": growth,
            "growth_pct": growth_pct,
            "samples": len(samples),
        })

    return sorted(results, key=lambda x: x["growth_mb"], reverse=True)


def analyze_swap_usage(hours: int = 24, conn: Optional[sqlite3.Connection] = None) -> Dict:
    """Analyze swap usage patterns"""
    if conn is not None:
        return _analyze_swap_usage_sqlite(conn, hours)
    if DB_FILE.exists():
        with closing(sqlite3.connect(DB_FILE)) as db:
            return _analyze_swap_usage_sqlite(db, hours)
    return _analyze_swap_usage_csv(hours)


def _analyze_swap_usage_sqlite(conn: sqlite3.Connection, hours: int) -> Dict:
    cutoff_ts = (datetime.now() - timedelta(hours=hours)).timestamp()
    swap_data = []

    query = """
        SELECT timestamp,
               swap_used_mb,
               swap_total_mb,
               swap_free_percent
        FROM snapshots
        WHERE timestamp >= ?
        ORDER BY timestamp ASC
    """

    for ts, swap_used, swap_total, swap_free_pct in conn.execute(query, (cutoff_ts,)):
        swap_data.append({
            "timestamp": datetime.fromtimestamp(ts),
            "swap_mb": float(swap_used),
            "total_mb": float(swap_total),
            "free_pct": float(swap_free_pct),
        })

    if not swap_data:
        return {}

    avg_swap = sum(d["swap_mb"] for d in swap_data) / len(swap_data)
    max_swap = max(d["swap_mb"] for d in swap_data)
    min_free = min(d["free_pct"] for d in swap_data)
    total_swap_written = sum(d["swap_mb"] for d in swap_data)

    return {
        "avg_swap_mb": avg_swap,
        "max_swap_mb": max_swap,
        "min_free_pct": min_free,
        "samples": len(swap_data),
        "estimated_ssd_writes_mb": total_swap_written,
        "swap_data": swap_data,
    }


def _analyze_swap_usage_csv(hours: int) -> Dict:
    if not SWAP_FILE.exists():
        return {}

    cutoff = datetime.now() - timedelta(hours=hours)
    swap_data = []

    with open(SWAP_FILE) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                ts = parse_timestamp(row["timestamp"])
                if ts < cutoff:
                    continue

                swap_data.append({
                    "timestamp": ts,
                    "swap_mb": float(row["swap_used_mb"]),
                    "total_mb": float(row["swap_total_mb"]),
                    "free_pct": float(row["free_pct"]),
                })
            except (ValueError, KeyError):
                continue

    if not swap_data:
        return {}

    avg_swap = sum(d["swap_mb"] for d in swap_data) / len(swap_data)
    max_swap = max(d["swap_mb"] for d in swap_data)
    min_free = min(d["free_pct"] for d in swap_data)
    total_swap_written = sum(d["swap_mb"] for d in swap_data)

    return {
        "avg_swap_mb": avg_swap,
        "max_swap_mb": max_swap,
        "min_free_pct": min_free,
        "samples": len(swap_data),
        "estimated_ssd_writes_mb": total_swap_written,
        "swap_data": swap_data,
    }


def get_memory_leaks(conn: Optional[sqlite3.Connection] = None, hours: int = 168) -> List[str]:
    """Extract recent memory leak alerts"""
    if conn is not None:
        return _get_memory_leaks_sqlite(conn, hours)
    if DB_FILE.exists():
        with closing(sqlite3.connect(DB_FILE)) as db:
            return _get_memory_leaks_sqlite(db, hours)
    return _get_memory_leaks_legacy()


def _get_memory_leaks_sqlite(conn: sqlite3.Connection, hours: int) -> List[str]:
    cutoff_ts = (datetime.now() - timedelta(hours=hours)).timestamp()
    query = """
        SELECT timestamp, type, message, pid, process_name
        FROM alerts
        WHERE timestamp >= ?
          AND type IN ('MEMORY_LEAK', 'RAPID_GROWTH')
        ORDER BY timestamp DESC
        LIMIT 200
    """

    leaks = []
    for ts, alert_type, message, pid, name in conn.execute(query, (cutoff_ts,)):
        timestamp = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
        suffix = f" PID={pid}" if pid is not None else ""
        if name:
            suffix += f" process={name}"
        leaks.append(f"[{timestamp}] {alert_type}: {message}{suffix}")
    return leaks


def get_diagnostic_hints(conn: Optional[sqlite3.Connection] = None, hours: int = 48) -> List[str]:
    """Fetch diagnostic hint alerts"""
    if conn is not None:
        return _get_diagnostic_hints_sqlite(conn, hours)
    if DB_FILE.exists():
        with closing(sqlite3.connect(DB_FILE)) as db:
            return _get_diagnostic_hints_sqlite(db, hours)
    return []


def _get_diagnostic_hints_sqlite(conn: sqlite3.Connection, hours: int) -> List[str]:
    cutoff_ts = (datetime.now() - timedelta(hours=hours)).timestamp()
    query = """
        SELECT timestamp, message, pid, process_name, metadata
        FROM alerts
        WHERE timestamp >= ?
          AND type = 'DIAGNOSTIC_HINT'
        ORDER BY timestamp DESC
        LIMIT 50
    """

    hints = []
    try:
        rows = list(conn.execute(query, (cutoff_ts,)))
    except sqlite3.OperationalError:
        rows = [tuple(row[:4] + (None,)) for row in conn.execute(
            "SELECT timestamp, message, pid, process_name FROM alerts WHERE timestamp >= ? AND type = 'DIAGNOSTIC_HINT' ORDER BY timestamp DESC LIMIT 50",
            (cutoff_ts,)
        )]

    for ts, message, pid, name, metadata in rows:
        timestamp = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
        suffix = f" PID={pid}" if pid is not None else ""
        if name:
            suffix += f" process={name}"
        if metadata:
            try:
                meta = json.loads(metadata)
                artifact = meta.get("artifact_path")
                if artifact:
                    suffix += f" artifact={artifact}"
                exists = meta.get("artifact_exists")
                if exists == "false":
                    suffix += " (missing)"
            except json.JSONDecodeError:
                pass
        hints.append(f"[{timestamp}] {message}{suffix}")
    return hints


def get_system_alerts(conn: Optional[sqlite3.Connection] = None, hours: int = 72) -> List[str]:
    if conn is not None:
        return _get_system_alerts_sqlite(conn, hours)
    if DB_FILE.exists():
        with closing(sqlite3.connect(DB_FILE)) as db:
            return _get_system_alerts_sqlite(db, hours)
    return []


def _get_system_alerts_sqlite(conn: sqlite3.Connection, hours: int) -> List[str]:
    cutoff_ts = (datetime.now() - timedelta(hours=hours)).timestamp()
    query = """
        SELECT timestamp, type, message, metadata
        FROM alerts
        WHERE timestamp >= ?
          AND type IN ('SYSTEM_PRESSURE', 'HIGH_SWAP', 'DATASTORE_WARNING')
        ORDER BY timestamp DESC
        LIMIT 50
    """

    alerts = []
    for ts, alert_type, message, metadata in conn.execute(query, (cutoff_ts,)):
        timestamp = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
        detail_suffix = ""
        if metadata:
            try:
                meta = json.loads(metadata)
            except json.JSONDecodeError:
                meta = {}
            extras = []
            if alert_type == "HIGH_SWAP":
                if (used := meta.get("swap_used_mb")):
                    extras.append(f"swap={used}MB")
                if (total := meta.get("swap_total_mb")):
                    extras.append(f"total={total}MB")
            if (pressure := meta.get("pressure")):
                extras.append(f"pressure={pressure}")
            if extras:
                detail_suffix = " (" + ", ".join(extras) + ")"
        alerts.append(f"[{timestamp}] {alert_type}: {message}{detail_suffix}")
    return alerts


def load_notification_preferences() -> Optional[Dict]:
    if not PREFERENCES_FILE.exists():
        return None
    try:
        with open(PREFERENCES_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def get_diagnostic_artifacts(conn: Optional[sqlite3.Connection] = None, hours: int = 48) -> List[Dict]:
    """Collect recent diagnostic artifacts with existence metadata."""
    if conn is not None:
        return _get_diagnostic_artifacts_sqlite(conn, hours)
    if DB_FILE.exists():
        with closing(sqlite3.connect(DB_FILE)) as db:
            return _get_diagnostic_artifacts_sqlite(db, hours)
    return []


def _get_diagnostic_artifacts_sqlite(conn: sqlite3.Connection, hours: int) -> List[Dict]:
    cutoff_ts = (datetime.now() - timedelta(hours=hours)).timestamp()
    query = """
        SELECT message, metadata
        FROM alerts
        WHERE timestamp >= ?
          AND type = 'DIAGNOSTIC_HINT'
        ORDER BY timestamp DESC
        LIMIT 200
    """

    artifacts: List[Dict] = []
    seen: set = set()

    for message, metadata in conn.execute(query, (cutoff_ts,)):
        if not metadata:
            continue

        try:
            meta = json.loads(metadata)
        except json.JSONDecodeError:
            continue

        artifact_path = meta.get("artifact_path")
        if not artifact_path:
            continue

        expanded = Path(artifact_path).expanduser()
        exists = expanded.exists()
        title = meta.get("title") or message
        key = (expanded, exists)
        if key in seen:
            continue
        seen.add(key)
        artifacts.append({
            "title": title,
            "path": str(expanded),
            "exists": exists,
        })

    artifacts.sort(key=lambda item: item["title"])
    return artifacts


def _get_memory_leaks_legacy() -> List[str]:
    if not LEAKS_FILE.exists():
        return []

    leaks = []
    with open(LEAKS_FILE) as f:
        for line in f:
            if "POTENTIAL LEAK" in line:
                leaks.append(line.strip())

    return leaks


def generate_report(hours: int = 24) -> str:
    """Generate comprehensive memory analysis report"""
    report = []
    report.append("=" * 80)
    report.append(f"Memory Watch Analysis Report - Last {hours} hours")
    report.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    report.append("=" * 80)
    report.append("")

    conn = db_connection()
    try:
        # Memory trends
        report.append("## Top Memory Growth Processes")
        report.append("-" * 80)
        trends = analyze_memory_trends(hours, conn)
        if trends:
            for i, proc in enumerate(trends[:10], 1):
                report.append(
                    f"{i:2d}. PID {proc['pid']:>6} | {proc['command']:<30} | "
                    f"Growth: {proc['growth_mb']:>7.1f}MB ({proc['growth_pct']:>6.1f}%) | "
                    f"Max: {proc['max_rss']:>7.1f}MB | Samples: {proc['samples']}"
                )
        else:
            report.append("No data available")
        report.append("")

        # Swap analysis
        report.append("## Swap Usage Analysis")
        report.append("-" * 80)
        swap = analyze_swap_usage(hours, conn)
        if swap:
            report.append(f"Average Swap Used:        {swap['avg_swap_mb']:.1f} MB")
            report.append(f"Maximum Swap Used:        {swap['max_swap_mb']:.1f} MB")
            report.append(f"Minimum Free:             {swap['min_free_pct']:.1f}%")
            report.append(f"Est. SSD Writes:          {swap['estimated_ssd_writes_mb']:.1f} MB")
            report.append(f"Samples:                  {swap['samples']}")

            # Warn if swap usage is high
            if swap['max_swap_mb'] > 1024:
                report.append("")
                report.append("⚠️  WARNING: High swap usage detected (>1GB)")
                report.append("   This can cause SSD wear and system slowdown")
        else:
            report.append("No data available")
        report.append("")

        # Memory leaks
        report.append("## Potential Memory Leaks")
        report.append("-" * 80)
        leaks = get_memory_leaks(conn)
        if leaks:
            report.append(f"Found {len(leaks)} potential leak(s):")
            for leak in leaks[-20:]:  # Last 20 leaks
                report.append(f"  {leak}")
        else:
            report.append("✓ No memory leaks detected")
        report.append("")

        # Diagnostic hints
        report.append("## Diagnostic Suggestions")
        report.append("-" * 80)
        hints = get_diagnostic_hints(conn)
        if hints:
            for hint in hints[:15]:
                report.append(f"  {hint}")
        else:
            report.append("No runtime-specific diagnostic hints recorded")
        report.append("")

        prefs = load_notification_preferences()
        report.append("## Notification Preferences")
        report.append("-" * 80)
        if prefs:
            quiet = prefs.get("quietHours")
            if quiet:
                start = quiet.get("startMinutes", 0)
                end = quiet.get("endMinutes", 0)
                tz = quiet.get("timezoneIdentifier", "local")
                report.append(f"  Quiet hours: {minutes_to_hhmm(start)}–{minutes_to_hhmm(end)} {tz}")
            else:
                report.append("  Quiet hours: disabled")
            policy = "deliver" if prefs.get("allowInterruptionsDuringQuietHours") else "hold"
            report.append(f"  Quiet-hour policy: {policy}")
            report.append(f"  Leak alerts: {'enabled' if prefs.get('leakNotificationsEnabled', True) else 'disabled'}")
            report.append(f"  Pressure alerts: {'enabled' if prefs.get('pressureNotificationsEnabled', True) else 'disabled'}")
        else:
            report.append("  No preference file found (defaults in effect)")
        report.append("")

        system_alerts = get_system_alerts(conn)
        report.append("## System Alerts")
        report.append("-" * 80)
        if system_alerts:
            for alert in system_alerts[:20]:
                report.append(f"  {alert}")
        else:
            report.append("No high-pressure or swap alerts recorded")
        report.append("")

        artifacts = get_diagnostic_artifacts(conn)
        report.append("## Diagnostic Artifacts")
        report.append("-" * 80)
        if artifacts:
            for artifact in artifacts[:20]:
                status = "✅" if artifact["exists"] else "⚠️ missing"
                report.append(f"  {status} {artifact['title']}: {artifact['path']}")
        else:
            report.append("No artifacts persisted yet.")
        report.append("")

        report.append("=" * 80)
    finally:
        if conn is not None:
            conn.close()

    return "\n".join(report)


def db_connection() -> Optional[sqlite3.Connection]:
    if DB_FILE.exists():
        conn = sqlite3.connect(DB_FILE)
        conn.row_factory = sqlite3.Row
        return conn
    return None


def main():
    """Main entry point"""
    hours = 24
    if len(sys.argv) > 1:
        try:
            hours = int(sys.argv[1])
        except ValueError:
            print(f"Invalid hours: {sys.argv[1]}", file=sys.stderr)
            sys.exit(1)

    report = generate_report(hours)
    print(report)

    # Save report
    report_file = LOG_DIR / f"report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
    with open(report_file, "w") as f:
        f.write(report)

    print(f"\nReport saved to: {report_file}")


if __name__ == "__main__":
    main()
