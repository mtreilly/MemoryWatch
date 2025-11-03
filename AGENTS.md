# MemoryWatch Agent Notes

## Current Status
- ✅ **Menu Bar App (Phase 1-3 Complete)**: SwiftUI menu bar extra built, tested, and installed to `/Applications/MemoryWatch.app`
  - Real-time memory/swap metrics display
  - Leak detection with regression-based heuristics
  - Memory history charts with point drill-down
  - Configurable notifications with quiet hours
  - System alerts (memory pressure, swap, WAL thresholds)
- 🔄 **Phase 4 – Polish (IN PROGRESS)**: Improving accessibility (keyboard nav, VoiceOver), adding preference UI refinements, export functionality

## Architecture

### Data & Storage
- Persistent data lives in `~/MemoryWatch/data/memorywatch.sqlite` with WAL + prepared statements—consult `SQLiteStore.swift` before adding new tables.
- Leak detection now relies on regression-based heuristics (see `LeakHeuristics.swift`); keep tests in `MemoryWatchApp/Tests` green when tuning thresholds.
- `SnapshotHistoryProvider.swift` loads historical data for charts; caches computed metrics (cumulative wear, top process per snapshot).

### Monitoring Loop
- Primary runtime is the Swift `memwatch` CLI/daemon; prefer it over the legacy shell script to keep memory collection efficient.
- `ProcessMonitor.swift` drives the monitoring loop, persists snapshots, and generates system/WAL/swap alerts.
- `memwatch status` surfaces datastore health (snapshot counts, retention window, WAL size) via the SQLite store—run it for sanity checks.

### Diagnostics & Runtime Support
- Runtime-specific diagnostic hints are generated in `RuntimeDiagnostics.swift`; extend mappings when supporting new runtimes (Python/Java/Ruby/Go/etc.).
- Use `memwatch diagnostics <PID>` (also triggered from menu bar or leak notifications) to execute collectors; outputs land in `~/MemoryWatch/samples` and metadata stored in alerts.
- `DiagnosticExecutor.swift` handles runtime detection and artifact capture.

### Menu Bar UI
- `MenuBarState.swift` exposes an observable snapshot (metrics, suspects, hints, alerts) for the menu bar—reuse it instead of re-querying system.
- `MenuBarApp.swift` (target `MemoryWatchMenuBar`) builds the SwiftUI interface; keep it responsive by reading from `MenuBarState` and SQLite, never direct syscalls.
- `NotificationPreferences.swift` handles quiet hours, delivery tracking; `NotificationPreferencesSheet.swift` provides the preferences UI.
- `DeliveredAlertHistoryStore.swift` persists notification delivery state across app restarts to avoid alert spam.

### Reporting & Analysis
- Reporting tooling has moved to SQLite backend; `analyze.py` can read both SQLite and legacy CSV for backwards compatibility.
- Analyzer updates now include preference snapshot and alert metadata for full traceability.

## Guidelines
- Keep the monitoring loop lightweight: favour cached statements, avoid repeated tool launches, and batch I/O where possible.
- Treat alerts as actionable: every high/critical alert should have accompanying diagnostics (sample, leak report, or runtime-specific probe).
- Commit early and often; tests (`swift test`, `./analyze.py`) must pass before commits.
- Roadmap and outstanding tasks are tracked in `docs/MASTER_PLAN.md`; update both files when advancing the plan.
