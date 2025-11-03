# MemoryWatch Master Plan

## Completed Foundation
- Migrated process snapshots, swap metrics, and alerts into a WAL-tuned SQLite datastore with prepared inserts for low-overhead writes.
- Updated the Swift daemon to stream directly into the datastore, collect CPU/IO metrics, and hydrate history from disk for continuity across restarts.
- Implemented regression-based leak heuristics (slope, R², MAD, growth momentum) with accompanying automated tests to gate regressions.
- Modernised the Python analyzer to read from the new schema while retaining legacy CSV fallbacks for older installs.
- Added retention-aware migrations and surfaced datastore health via `memwatch status`, including WAL checkpoints and quick integrity checks.
- Introduced a `MenuBarState` observable snapshot so the future menu bar UI can hydrate from shared metrics and leak diagnostics.
- Persisted runtime diagnostic hints with JSON metadata (artifact paths, commands) inside SQLite alerts for traceability and tooling.
- Added `memwatch diagnostics <PID>` to automatically capture artifacts for the mapped runtimes and store metadata alongside alerts.

## Phase 2: Hardening & Telemetry (COMPLETE) ✅
- ✅ **MaintenanceScheduler**: Periodic database maintenance with configurable 30-minute intervals, WAL checkpoint optimization, and PRAGMA optimize.
- ✅ **WAL Size Monitoring**: Automated alerts when WAL exceeds warning (100MB) or critical (500MB) thresholds with debounced notifications.
- ✅ **RetentionManager**: Configurable data retention policies respecting user preferences (1-720 hours), with automatic cleanup of old snapshots and alerts.
- ✅ **Database Health**: Enhanced `StoreHealth` metrics including WAL size, free pages, and quick integrity checks.
- ✅ **Type Safety**: Made MemoryAlert and AlertType Sendable for safe concurrent access.
- ✅ **Comprehensive Testing**: 10 new unit tests covering maintenance, retention, and health monitoring (24 total tests passing).

## Phase 3: Toolchain Integrations (COMPLETE) ✅
- ✅ **ToolchainAdapter Protocol**: Abstraction layer for runtime-specific diagnostic tools (capture & analyze).
- ✅ **Chromium Adapter**: Captures V8 heap dumps via SIGUSR2 for Chrome/Electron processes.
- ✅ **Xcode Adapter**: Uses xcrun xctrace to capture malloc stack logs with 30-second recordings.
- ✅ **Node Adapter**: Triggers Node.js heap snapshots and analyzes for leak patterns (detached, listener, callback, closure).
- ✅ **ToolchainAdapterRegistry**: Factory pattern for adapter discovery and custom registration.
- ✅ **ToolchainIntegration**: Coordinates adapters with alert system; auto-triggers when suspicion > 0.7.
- ✅ **Artifact Metadata**: Stores paths, analysis results, and suspected leak info in alert metadata.
- ✅ **Comprehensive Testing**: 21 new unit tests for adapters, analysis, registry, and integration (45 total tests passing).

## Phase 4: Orphan/Residue Detection (COMPLETE) ✅
- ✅ **Deleted-but-Open Files**: Uses lsof to find deleted files still held open by processes.
- ✅ **Stale Swapfile Detection**: Scans /var/vm for unused swap files with configurable age threshold.
- ✅ **Orphaned Process Detection**: Identifies zombies (Z state) and suspended processes (T state) with interval-based checking.
- ✅ **Bundle Path Resolution**: Maps process IDs to application bundles for app-specific remediation.
- ✅ **Unified Report Types**: OrphanReport enum with severity levels and automated remediation suggestions.
- ✅ **Comprehensive Testing**: 28 new unit tests for all detection methods, report types, and properties.

## Phase 5: Documentation & Developer Experience (COMPLETE) ✅
- ✅ **CLI Reference**: Complete command documentation with 8 commands (status, monitor, leaks, diagnostics, orphans, daemon, export, config)
- ✅ **SQLiteStore API**: Full API reference with code examples, retention policies, performance considerations, batch operations
- ✅ **Developer Guide**: Custom adapter development, leak detection extension, database customization, webhook integration patterns
- ✅ **Entitlements Guide**: System permissions, App Sandbox configuration, full disk access setup, troubleshooting permission errors
- ✅ **Troubleshooting Guide**: 20+ common issues with solutions covering permissions, database, performance, CLI, and daemon problems
- ✅ **README Updates**: Modernized with Phase 1-5 completion, quick start guide, architecture overview, integration examples
- ✅ **50+ Code Examples**: CLI usage, API patterns, custom adapters, webhook integration, time series database streaming

## Next Milestones
1. **Production Deployment (Phase 6)** – code signing, app notarization, distribution via App Store or website.

### Menu Bar Implementation Plan
- **Phase 0 – Data plumbing** ✅: a `MenuBarState` observable now aggregates system metrics, suspects, and diagnostic hints for the UI.
- **Phase 1 – SwiftUI shell** ✅: initial `MenuBarExtra` shows metrics, suspects, hints, and includes quick actions (open folders, launch status).
- **Phase 2 – Historical panes** ✅: the menu bar streams recent snapshots via a history provider, renders memory/swap sparklines, overlays SSD-wear estimates, and supports drill-down into point diagnostics.
- **Phase 3 – Alerting hooks** ✅: configurable quiet hours, persistence for delivered alerts across restarts, and WAL/swap/pressure warnings are surfaced through both notifications and the menu UI.
- **Phase 4 – Polish** ✅ (COMPLETE): add preferences (update cadence, retention window overrides), accessibility audits (Dynamic Type, VoiceOver labels), and export options for quick sharing of current status.
  - ✅ Built and installed to `/Applications/MemoryWatch.app`
  - ✅ Menu bar icon verified (memorychip system image)
  - ✅ **Accessibility** (COMPLETE): Full VoiceOver support, semantic labels, accessibility hints for all UI components
  - ✅ **Keyboard Navigation** (COMPLETE): Cmd+S, Cmd+D, Cmd+,, Tab navigation, Escape to close, Return to confirm
  - ✅ **Dynamic Type** (COMPLETE): Support for all text scales (.xSmall to .xxxLarge), responsive layout
  - ✅ **Export Functionality** (COMPLETE): JSON export for current snapshot, CSV export for historical data
  - ✅ **Preference Refinements** (COMPLETE): Update cadence (5-300s) and retention window (1-720h) with UI sliders wired into menu bar refresh + daemon retention
  - ✅ **Daemon Controls** (COMPLETE): Menu bar auto-starts the daemon, adds start/stop controls, provides a launch-at-login toggle backed by launchctl bootstrap/bootout, and falls back to a bundled CLI when PATH lookup fails

## Operational Guidelines
- Keep the monitoring loop lightweight: favour cached statements, avoid repeated tool launches, and batch I/O where possible.
- Treat alerts as actionable: every high/critical alert should have accompanying diagnostics (sample, leak report, or runtime-specific probe).
- Commit early and often; tests (`swift test`, `./analyze.py`) should run clean before each commit.
- Track follow-up tasks in `docs/MASTER_PLAN.md` and mirror high-level updates in `AGENTS.md` so the wider agent network stays in sync.
