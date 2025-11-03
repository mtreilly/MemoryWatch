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

## Next Milestones
1. **Hardening & Telemetry (Phase 2)** – automated vacuum scheduling, retention-trim alerts, WAL size budgeting + alerting when WAL exceeds thresholds.
2. **Toolchain Integrations** – expand runtime diagnostic adapters (Chromium heap dumps, Xcode malloc stack logging, Node heap snapshots) and capture their artefacts alongside alerts.
3. **Orphan/Residue Detection** – extend filesystem sweeps for deleted-but-open files, stale swapfiles, and orphaned processes; map offenders back to bundles for remediation workflows.
4. **Documentation & Developer Experience** – expand CLI docs, add API references for the datastore, and publish guidance on enabling required system entitlements.
5. **Production Deployment** – code signing, app notarization, distribution via App Store or website.

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
  - ✅ **Preference Refinements** (COMPLETE): Update cadence (5-300s) and retention window (1-720h) with UI sliders

## Operational Guidelines
- Keep the monitoring loop lightweight: favour cached statements, avoid repeated tool launches, and batch I/O where possible.
- Treat alerts as actionable: every high/critical alert should have accompanying diagnostics (sample, leak report, or runtime-specific probe).
- Commit early and often; tests (`swift test`, `./analyze.py`) should run clean before each commit.
- Track follow-up tasks in `docs/MASTER_PLAN.md` and mirror high-level updates in `AGENTS.md` so the wider agent network stays in sync.
