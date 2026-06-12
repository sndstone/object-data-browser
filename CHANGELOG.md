# Changelog

## 2.1.0 - 2026-06-12

### Azure Blob Storage support
- Added Azure Blob Storage as a third endpoint type alongside S3-compatible and AWS S3.
- Authentication uses the storage account name (access key field) and account access key (secret key field). An empty endpoint URL resolves to `https://<account>.blob.core.windows.net`; a custom URL supports Azurite and sovereign clouds.
- Implemented in the Go and Python engines via raw REST and Shared Key signing — no new runtime dependencies.
- Rust and Java engines return a clean `unsupported_feature` response with instructions to switch engine.
- S3-only features (versioning, presigned URLs, lifecycle/policy/CORS/encryption/tagging) are hidden in the UI for Azure profiles and rejected by engines.
- Containers map to buckets; folder markers are zero-byte blobs with a trailing `/`; objects upload single-shot under 64 MiB and use 16 MiB block uploads above that threshold.

### Benchmark — real parallel execution
- Fixed a serial-execution bug where the Go benchmark ran all operations in a single loop regardless of the thread count setting.
- Replaced with a true goroutine worker pool: mutex-guarded slot planning, lock-free per-op execution, and post-batch result aggregation.
- Per-tick batch cap raised from `threads × 8` (min 32) to `threads × 32` (max 8 192).
- Benchmark now works against Azure Blob Storage targets as well as S3.
- Added four benchmark presets to the UI — Quick check, Standard, Throughput stress (16/64 MiB objects, 128 threads, 5 min), and IOPS stress (4/16 KiB objects, 256 threads, 8 192-object pool).

### Performance — persistent engine processes
- The desktop engine host previously spawned a new engine process for every API call (fork/exec + Python interpreter startup per request). Engine processes are now persistent and pooled.
- Requests are matched to idle workers by request ID; a new worker is spawned only when all existing workers are busy. Crash recovery fails pending requests cleanly and respawns the process automatically. `dispose()` kills all child processes.

### Responsive layout overhaul
- Unified responsive breakpoints into a single `Breakpoints` class: phone < 700 px, tablet 700–1 199 px, desktop ≥ 1 200 px, wide ≥ 1 500 px.
- Breakpoints are window-width driven, so resizing a desktop window walks through the same layouts as physical device sizes — no separate "compact desktop" path.
- Tablet layout now docks the inspector below the object list with a resize handle instead of hiding it entirely.
- Wide desktop (≥ 860 px object panel) adds Storage Class and ETag columns to the object table.

### Performance hygiene
- In-memory event log capped at 5 000 entries (was unbounded).
- Per-page listing-progress notifications coalesced with an 80 ms debounce timer to prevent O(n) UI rebuilds on large buckets.

### Engine versions
- All four engines bumped to version 2.1.0.

## 2.0.17 - 2026-05-18

- Fixed compact desktop inspector resize bounds so small macOS and Windows windows no longer crash with invalid clamp arguments.
- Reworked the 700-1199px browser layout to prioritize object rows by moving the inspector and lesser-used object actions into nested menus.
- Hid the compact desktop drag-and-drop hint while preserving desktop drop uploads.
- Updated fresh-install defaults to 70% UI scale and 80% log text scale for denser mid-size layouts.
- Added macOS DMG packaging verification and refreshed app, sidecar, and packaging metadata.

## 2.0.16 - 2026-05-16

- Added folder-aware uploads that preserve relative object keys for backup-style transfers.
- Hid the benchmark workspace on Android and iOS navigation surfaces.
- Fixed Android platform-channel map normalization for bucket listing.

## 2.0.15 - 2026-05-08

- Renamed the application and packaging metadata to Object Data Browser.
- Updated release artifact names and documentation links for the object data pivot.
- Kept existing S3 workflows while preparing the app identity for broader object data sources.

## 2.0.14 - 2026-05-05

- Redesigned the app shell with a dark storage navigation rail, compact header controls, and a quieter white workspace canvas.
- Restyled bucket browsing, object listing, inspector panels, settings, tasks, tools, and event log surfaces around the new 0.2.14 design reference.
- Bumped app metadata to 2.0.14.

## 2.0.13 - 2026-05-05

- Improved settings readability and spacing for diagnostics and endpoint profile editing.
- Updated default UI scale to 75% and kept log text scale at 90%.
- Bumped app metadata to 2.0.13.

## 2.0.12 - 2026-04-28

- Added task/listing cancellation hooks so long bucket and object listings can stop cleanly and show partial results.
- Improved benchmark startup feedback, default throughput settings, and reduced-noise benchmark logging for heavier test runs.
- Refined desktop density, browser panel sizing, compact selectors, and mobile bucket-to-object navigation.
- Fixed Android profile import handling and Android version details so desktop-only dependencies and engines are filtered out.
- Bumped app metadata to 2.0.12.

## 2.0.10 - 2026-03-25

- Refined the Tasks tab selector hover and selection styling to remove the awkward square overlay artifact.
- Fixed the Inspector tab chips so the selected state no longer renders the broken default icon/check treatment.
- Bumped app, sidecar, and packaging metadata to 2.0.10.

## 2.0.9 - 2026-03-24

- Fixed the Android native bridge build issues and bumped app, sidecar, and packaging metadata to 2.0.9.

## 2.0.8 - 2026-03-22

- Improved Event Log and inspector trace rendering with grouped send/response cards.
- Added separate log text scaling and phone-oriented layout updates.
- Bumped app, sidecar, and packaging metadata to 2.0.8.

## 2.0.7 - 2026-03-16

- Promoted Tasks into a dedicated top-level workspace and expanded task detail cards for transfers, tools, and browser actions.
- Added richer transfer telemetry plumbing so desktop sidecars can stream detailed upload/download progress into the Tasks workspace.
- Improved browser create flows with a named Create prefix dialog, refined selected-profile readability, and expanded Windows Android APK build support.
- Bumped app, sidecar, and packaging metadata to 2.0.7.

## 2.0.6 - 2026-03-14

- Routed benchmark runs through the selected S3 profile so all sidecar engines execute real benchmark traffic.
- Updated the benchmark throughput area chart to stack per-operation metrics for total request visibility.
- Bumped app, sidecar, and packaging metadata to 2.0.6.

## 2.0.5 - 2026-03-12

- Improved browser object pagination with local 1000-item pages plus a show-all mode.
- Refined object, settings, task, and benchmark preview UX, including richer chart controls and preview image export.
- Bumped app, sidecar, and packaging metadata to 2.0.5.

## 2.0.4 - 2026-03-11

- Bump app, sidecar, and packaging metadata to 2.0.4.

## 2.0.3 - 2026-03-11

- Bump app, sidecar, and packaging metadata to 2.0.3.

## 2.0.0 - 2026-03-08

- Rebuilt the project as `Object Data Browser`, a Flutter-based cross-platform object data browser targeting Windows, macOS, Linux, and Android.
- Added a desktop sidecar engine model with packaged Python, Go, Rust, and Java engines, with the Python engine implemented as the first real S3 backend.
- Added Windows MSI packaging and engine staging so desktop releases bundle the app plus the engine sidecars under `engines/`.
- Added a benchmark workspace, adaptive navigation shell, clustered settings, and an Event Log workspace with export support.
- Added endpoint profile management with secure-secret integration points, profile testing, selection, creation, and deletion.
- Added bucket and object browsing flows with real Python-backed bucket listing, object listing, object details, versions, tags, headers, presigned URLs, and bucket admin inspection.
- Added bucket creation with versioning and object-lock options.
- Added transfer, diagnostics, debug logging, and busy-state feedback improvements so actions immediately show progress in the UI.
- Added portable bootstrap and build scripts that stage local toolchains and produce self-contained Windows artifacts.

## 1.x

- Legacy Python Tkinter object data browser implementation before the `Object Data Browser` rewrite.
