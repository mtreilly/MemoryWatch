This directory contains detailed LLM agent prompts to analyze MemoryWatch outputs and produce actionable recommendations. Each prompt is designed for direct use with modern LLMs.

Files:
- snapshot_analysis.md — Interprets `memwatch snapshot --json` output and recommends actions.
- daemon_report_triage.md — Prioritizes issues found in `memwatch report` and `memwatch suspects`.
- io_hotspot_triage.md — Diagnoses heavy disk I/O from `memwatch io` output.
- dangling_files_cleanup.md — Guides cleanup of deleted-but-open files from `memwatch dangling-files`.
- port_conflict_resolution.md — Resolves port conflicts using `memwatch check-port/ports`.

Usage:
1) Generate output with MemoryWatch (JSON preferred when available).
2) Paste the output under the “User input” section in the prompt file.
3) Send the entire prompt to your LLM. Adjust thresholds or policies in the “Org policy” section if needed.

