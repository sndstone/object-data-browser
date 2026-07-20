# Changelog

## Unreleased

## 2.2.4 - 2026-07-20

### Benchmark workspace refresh
- Reworked the active-run dashboard with clearer run identity, status, progress, live throughput, latency, data-rate cards, output controls, and a terminal-style live log.
- Refined benchmark history and result presentation with denser summaries, clearer metric cards, and improved chart axes, smoothing, fills, markers, and stacked-series rendering.

### Per-run benchmark outputs
- Benchmark CSV, JSON, and log artifacts now write to a folder named after the run ID so repeated runs no longer overwrite earlier results.
- Applied the per-run output layout consistently across the Python, Go, Rust, Java, Android, and mock benchmark implementations.

## 2.2.3 - 2026-07-18

### Dynamic multipart sizing
- Uploads now choose an S3-compliant part size from the largest selected file, balancing parallel throughput with bounded worker memory and the 10 000-part limit.
- Automatic sizing is enabled by default. Disabling it restores the manual multipart chunk setting; downloads continue to use the manual range size.

### macOS credentials and expanded previews
- macOS credentials persist in Keychain-backed secure storage, and metadata-only imports no longer erase existing credentials.
- Profile credentials now use one versioned Keychain bundle, reducing post-update authorization to one prompt. Data Protection per-field items migrate with one bulk read, and unchanged settings no longer rewrite credentials.
- Fixed ad-hoc macOS packaging that sandboxed the app without provisioned Keychain access. Ad-hoc artifacts now restore legacy Keychain access, probe both historical Keychain modes during migration, and stop automatic listing with a direct error when hydration fails.
- macOS startup now recovers the newest profile metadata across sandboxed and unsandboxed Application Support locations, preventing an update from pairing valid Keychain items with an older empty profile list.
- Text and image previews can open in a larger dialog; text is selectable and scrollable, while images support pan and zoom.
- Recognized source files now use selectable syntax highlighting. Expanded HTML previews default to source and can switch to a static page render without executing scripts.
- Added a Developer ID release lane with an embedded provisioning profile, stable team-scoped Data Protection Keychain identity, hardened signing, DMG signing, and notarization. GitHub releases now fail closed when the required Apple signing secrets are missing instead of publishing an update-unsafe ad-hoc build.
- Signed releases migrate credentials from the legacy Keychain into the stable Data Protection Keychain bundle. Ad-hoc builds retain the reverse migration fallback for local development only.
- Upgraded secure storage to fix macOS `errSecParam` (`-50`) when updating an existing Keychain credential bundle; Android now explicitly targets API 23 or newer as required by the upgraded secure-storage implementation.
- Stopped issuing the legacy macOS Keychain bulk-read query that also returns `errSecParam` (`-50`) during startup migration. Older ad-hoc profiles now enter a safe one-time recovery state and can be consolidated by re-entering credentials and saving once.
- Credential-bearing profile imports now act as an explicit Keychain recovery operation, while metadata-only imports preserve existing secrets and generated exports remain credential-free.
- Added a separately persisted default endpoint selector beside the default engine setting; runtime endpoint switches no longer determine the next startup endpoint when a default is configured.

## 2.2.2 - 2026-07-07

### Fixed: release version metadata
- Updated the in-app version details, engine version fallbacks, and bundled engine catalog so the Settings version panel matches the packaged release.
- Bumped all engine-reported versions to 2.2.2 for this release.

## 2.2.1 - 2026-07-03

### Fixed: bucket and object context menus
- Restored right-click context menus for bucket rows and object rows so actions are anchored to the element under the pointer.
- Object row context menus select the target cheaply before offering inspect, folder open, download, presign, and delete actions.

## 2.2.0 - 2026-07-02

### Parallel large-file transfers (all engines)
- Multipart uploads now upload parts concurrently in the Python, Go, Rust, and Java engines with a bounded worker pool (up to 8 concurrent parts, capped by the profile's max concurrent requests).
- Ranged downloads fetch byte ranges concurrently and write them at the correct offsets into a pre-sized file.
- Go and Java no longer read the entire file into memory for multipart uploads; parts are read on demand with positional reads. Rust no longer buffers whole objects in memory on either path — uploads read per-part and downloads stream each range straight to disk.
- Failed multipart uploads are now aborted server-side (previously the Rust engine leaked incomplete multipart uploads on failure).
- Progress events, response shapes, and single-part paths are unchanged.

### Fixed: Python engine "token is malformed" on AWS S3
- When a profile had no session token, the Python engine serialized JSON `null` to the literal string "None" and sent it as `x-amz-security-token`, which AWS rejects with "the provided token is malformed or otherwise invalid". Session tokens are now only passed to the client when actually present, matching the other engines.

### Inspector tools now run natively on the selected engine
- "Put test data" and "Delete all" are real implementations in all four engines instead of Python-script stubs: put-testdata creates the configured objects/versions with a bounded worker pool; delete-all pages through object versions (falling back to plain listing where versioning is unsupported), batch-deletes with configurable batch size, workers, and delay, and reports counts, durations, and failures.
- Tool labels changed from "put-testdata.py"/"delete-all.py" to "put-testdata"/"delete-all"; whatever engine is selected performs the work.

### UI: anchored, downward-opening select menus
- All dropdown selectors (endpoint profile, backend engine, default engine, inspector placement, endpoint type, AWS region, filter/sort modes, page and copy-destination selectors) use a new shared `AppSelectField` widget.
- Menus now open anchored directly beneath the field and animate downward (fade + top-aligned expansion); when there is not enough room below, they flip and open upward from the field instead. The selected item is highlighted with a check mark and scrolled into view.

### UI: more compact desktop layout
- Reduced desktop chrome: header margins/padding 14→12, outer panel padding 14→12, panel gaps 10→8, bucket panel width 300→272, inspector section dividers 28→16, lifecycle card padding 12→10, resize handles 14→10.
- Desktop list tiles are now dense with compact visual density by default.

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
