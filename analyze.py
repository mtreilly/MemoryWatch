#!/usr/bin/env python3
"""
Memory Watch Analyzer - Generate reports from memory logs
Analyzes memory_log.csv, swap_history.csv, and memory_leaks.log
"""

import csv
import sys
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Tuple

LOG_DIR = Path.home() / "MemoryWatch"
CSV_FILE = LOG_DIR / "memory_log.csv"
SWAP_FILE = LOG_DIR / "swap_history.csv"
LEAKS_FILE = LOG_DIR / "memory_leaks.log"
EVENTS_FILE = LOG_DIR / "events.log"


def parse_timestamp(ts: str) -> datetime:
    """Parse timestamp from logs"""
    return datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")


def analyze_memory_trends(hours: int = 24) -> Dict:
    """Analyze memory usage trends over the last N hours"""
    if not CSV_FILE.exists():
        return {}

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

    # Calculate growth rates
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


def analyze_swap_usage(hours: int = 24) -> Dict:
    """Analyze swap usage patterns"""
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

    # Estimate SSD wear (rough approximation)
    # Assume each MB of swap written = 1 MB of SSD write
    # This is a simplification; real wear would need block-level tracking
    total_swap_written = sum(d["swap_mb"] for d in swap_data)

    return {
        "avg_swap_mb": avg_swap,
        "max_swap_mb": max_swap,
        "min_free_pct": min_free,
        "samples": len(swap_data),
        "estimated_ssd_writes_mb": total_swap_written,
        "swap_data": swap_data,
    }


def get_memory_leaks() -> List[str]:
    """Extract memory leak alerts from log"""
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

    # Memory trends
    report.append("## Top Memory Growth Processes")
    report.append("-" * 80)
    trends = analyze_memory_trends(hours)
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
    swap = analyze_swap_usage(hours)
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
    leaks = get_memory_leaks()
    if leaks:
        report.append(f"Found {len(leaks)} potential leak(s):")
        for leak in leaks[-20:]:  # Last 20 leaks
            report.append(f"  {leak}")
    else:
        report.append("✓ No memory leaks detected")
    report.append("")

    report.append("=" * 80)

    return "\n".join(report)


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
