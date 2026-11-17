## Summary

The main 2.3.5 improvements remain intact: ordinary progress ticks do not re-sort the 100k-object window, workspace signatures suppress unrelated content rebuilds, and transfer log deltas preserve shared prefix views. The highest-value remaining work is bounding structured trace payload memory, virtualizing embedded logs, batching log notifications, completing Jobs view indexing, and reducing mobile upload filesystem overhead. Several earlier recommendations remain only partially addressed, especially large-response decoding and non-regex version filtering. This was a static, read-only review; no files changed, builds/tests/network operations ran, or disposable artifacts were created.

## Findings

1. **Structured API trace bodies bypass the effective memory budget** — severity `high`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:1434`, `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:1606`, `apps/flutter_app/lib/controllers/app_controller.dart:4363`, `apps/flutter_app/lib/services/diagnostic_safety.dart:10`
   - **What happens now:** With API logging enabled, the service recursively sanitizes the complete response and passes it as `traceBody`. Only the textual message is truncated to 2,000 characters—and only after encoding the complete value. The controller recursively copies the body again into its event record.
   - **Why it matters:** The 5,000-event limit bounds record count, not bytes. Repeated listing responses retain thousands of full page trees independently of the bounded object window. Processing and allocation are O(response size) several times per response.
   - **Proposed change:** Introduce a sanitizing trace serializer with explicit byte, depth, and collection limits. Retain summaries in memory; if complete trace access is required, spool sanitized payloads to bounded disk-backed storage with visible truncation information.
   - **Measure:** Enable tracing against repeated 1,000-object pages; compare retained `Map`/`List` instances in DevTools heap snapshots and add timeline spans around sanitization and encoding.

2. **The Events & Debug inspector defeats log virtualization** — severity `high`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/browser/browser_workspace.dart:2100`, `apps/flutter_app/lib/browser/browser_workspace.dart:2129`, `apps/flutter_app/lib/logs/structured_log_list.dart:77`
   - **What happens now:** The inspector puts `StructuredLogList(embedded: true)` inside an outer `ListView`. Embedded mode enables `shrinkWrap` and disables inner scrolling.
   - **Why it matters:** The inner list must determine its complete extent, so layout can build thousands of log rows instead of the visible viewport. Every new scoped event invalidates that data. This is O(L) widget/layout work with up to 5,000 retained events.
   - **Proposed change:** Give `StructuredLogList` a sliver form and compose controls, trace rows, and debug details in one `CustomScrollView`.
   - **Measure:** Count row builds and inspect frame times when opening the inspector with 5,000 events; compare against the standalone Event Log.

3. **Engine logs bypass progress coalescing and repeatedly copy the event window** — severity `medium`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/controllers/app_controller.dart:4343`, `apps/flutter_app/lib/controllers/app_controller.dart:4370`, `apps/flutter_app/lib/controllers/app_controller.dart:4387`, `apps/flutter_app/lib/event_log/event_log_workspace.dart:66`, `apps/flutter_app/lib/logs/structured_log_list.dart:105`
   - **What happens now:** Each accepted engine log callback prepends by copying `eventLog`, copies again when trimming, and immediately calls `notifyListeners()`. With Event Log visible, the new list invalidates category/count indexing, filtering, and structured grouping caches.
   - **Why it matters:** At capacity, insertion alone copies about 10,000 references per event. Visible log processing adds several O(5,000) passes. A burst of callbacks still performs controller-side work individually even if Flutter combines their eventual builds.
   - **Proposed change:** Use a bounded deque with a revisioned view; batch log notifications using the configured interval, while keeping errors and action completion immediate. Incrementally maintain counts and request groups.
   - **Measure:** Count callbacks, notifications, grouping passes, and allocated bytes during a synthetic 100-events/second trace stream.

4. **Jobs still scans retained history several times per progress rebuild** — severity `medium`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/controllers/ordered_records.dart:11`, `apps/flutter_app/lib/controllers/app_controller.dart:3336`, `apps/flutter_app/lib/tasks/tasks_workspace.dart:17`, `apps/flutter_app/lib/tasks/tasks_workspace.dart:44`
   - **What happens now:** O(1) indexed updates invalidate the ordered snapshot. When Jobs reads it, the snapshot materializes through an intermediate list. The workspace then filters the selected view, scans for selection, and independently filters running and failed counts.
   - **Why it matters:** With T retained jobs, a default 10 Hz progress stream causes several O(T) passes plus list allocations. This is the remaining presentation cost after the shipped indexed-update fix; the row list itself is lazy.
   - **Proposed change:** Maintain status counts and ordered view indexes in the task store. Expose per-task listenables so progress updates rebuild the affected card/details without reconstructing history views.
   - **Measure:** Display one live transfer alongside 10,000 completed jobs; count `tasksForView` calls and profile allocations/frame times.

5. **Large valid sidecar messages still decode on the UI isolate** — severity `medium`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/services/desktop_engine_host.dart:448`, `apps/flutter_app/lib/services/desktop_engine_host.dart:585`, `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:1797`, `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:91`
   - **What happens now:** Framing correctly rejects oversized messages before JSON decoding, but accepts frames up to 128 MiB. UTF-8 conversion, `jsonDecode`, model construction, and full history-mapping ingestion remain on the UI isolate.
   - **Why it matters:** A large legitimate recovery response can monopolize the UI event loop and temporarily retain encoded bytes, strings, decoded trees, and converted records. This remains an open part of the earlier IPC recommendation.
   - **Proposed change:** Decode large frames in a reusable worker, with bounded admission/backpressure and request association preserved. Keep small progress messages on a low-overhead path.
   - **Measure:** Add timeline spans around framing, decoding, and conversion; feed representative large recovery responses and record longest UI stalls and peak heap.

6. **Modal inspector and benchmark views bypass workspace rebuild scoping** — severity `medium`, effort `S`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/browser/browser_workspace.dart:749`, `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:1578`, `apps/flutter_app/lib/app/s3_browser_app.dart:983`
   - **What happens now:** These routes listen directly to the entire controller through `AnimatedBuilder`. An unrelated transfer tick rebuilds the inspector panel, results workspace, or connection sheet.
   - **Why it matters:** The main workspace signature protections do not cover these routes. Completed benchmark results can therefore regenerate chart data during an unrelated transfer; inspector previews can repeat layout work at the progress frequency.
   - **Proposed change:** Apply the existing signature-frame approach to modal content, or expose narrowly scoped listenables for inspector data, benchmark results, and connection choices.
   - **Measure:** Use rebuild counters or `debugPrintRebuildDirtyWidgets` with each modal open during unrelated progress. Assert unchanged modal content does not rebuild.

7. **Streamed mobile uploads reopen and stat the source for every small block** — severity `medium`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/services/mobile_storage_transfers.dart:365`, `apps/flutter_app/lib/services/mobile_storage_transfers.dart:373`, `apps/flutter_app/lib/services/mobile_storage_transfers.dart:624`, `apps/flutter_app/lib/services/mobile_storage_transfers.dart:639`
   - **What happens now:** The streamed path reads 256 KiB blocks for local uploads. Each block performs source verification, opens a file, seeks, reads, closes, and verifies again. S3 parts larger than 8 MiB traverse this stream once for hashing and again for upload.
   - **Why it matters:** Per GiB through that S3 path, this means roughly 8,192 opens/closes and 16,384 source-stat checks, before retries. Filesystem scheduling can limit throughput despite bounded memory and off-isolate hashing.
   - **Proposed change:** Reuse one stable file handle per bounded part worker. Preserve source-change detection using handle-aware checks and explicit checks before dispatch, between appropriate boundaries, and before completion.
   - **Measure:** Instrument opens, stats, bytes read, and elapsed time for automatic parts above 8 MiB and equivalent manual configurations.

8. **Large non-regex version filters remain synchronous** — severity `medium`, effort `M`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/controllers/object_query.dart:209`, `apps/flutter_app/lib/controllers/object_query.dart:227`, `apps/flutter_app/lib/controllers/object_query.dart:274`, `apps/flutter_app/lib/controllers/object_query.dart:367`
   - **What happens now:** Version filtering is cached, and regex execution is killable. However, every changed page length or non-regex filter synchronously traverses and materializes the accumulated version list. Paged storage performs binary page lookup through indexed access.
   - **Why it matters:** Loading 100 pages of 1,000 versions can visit roughly five million accumulated rows across successive filter refreshes. Filter submission or visibility toggles can synchronously process all 100k loaded versions.
   - **Proposed change:** Apply a dataset-size worker threshold to non-regex version queries too. Incrementally filter appended pages when the filter is unchanged, retaining generation guards and exact ordering.
   - **Measure:** Time `VersionQuery.resolve` while appending pages and changing text/prefix filters; record UI event-loop stalls.

9. **Successful transfers retain unnecessary retry closures and selection data** — severity `medium`, effort `S`, confidence `confirmed`
   - **Where:** `apps/flutter_app/lib/controllers/app_controller.dart:1658`, `apps/flutter_app/lib/controllers/app_controller.dart:1790`, `apps/flutter_app/lib/controllers/app_controller.dart:1827`, `apps/flutter_app/lib/controllers/app_controller.dart:3292`, `apps/flutter_app/lib/controllers/app_controller.dart:3328`
   - **What happens now:** Upload retry closures capture copied path lists and mappings. Download closures capture copied selected keys and the profile. Successful jobs retain these closures even though `canRetryTask` only permits failed tasks. Cleanup occurs when the user clears finished tasks.
   - **Why it matters:** Retained memory grows with cumulative transfer selections, beyond the history records themselves. Repeated large batch selections can retain many otherwise unnecessary strings and maps.
   - **Proposed change:** Remove retry descriptors on confirmed successful completion. Retain descriptors needed by failed/retryable jobs and preserve unknown-outcome safeguards.
   - **Measure:** Complete repeated large batches and inspect retaining paths through `_retryTransfers`; assert successful jobs leave no retry entries.

10. **Benchmark chart derivation and painting still scale with all retained samples** — severity `medium`, effort `M`, confidence `confirmed`
    - **Where:** `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:3450`, `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:3617`, `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:2714`, `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:4027`
    - **What happens now:** Raw timeline ordering is cached, but derived series are recreated by scanning per operation, formatting values, and allocating points. `_timeAxisSummary` flattens and sorts them again. The painter constructs offsets and paths for every point on a horizontally oversized canvas.
    - **Why it matters:** Work is O(N) for derivation/painting and O(N log N) for the axis summary. A 10,000-point single-operation latency series requests approximately 140,000 logical pixels of chart width despite showing only a small viewport.
    - **Proposed change:** Cache derived series and axis metadata by summary/filter settings. Isolate chart repainting and render viewport-relevant samples with boundary neighbours; use detail-preserving pixel aggregation where appropriate.
    - **Measure:** Profile 10k-point charts while resizing, scrolling, and receiving updates; count point allocations and painter duration.

11. **Credential hydration delays the first application frame** — severity `medium`, effort `M`, confidence `confirmed`
    - **Where:** `apps/flutter_app/lib/main.dart:40`, `apps/flutter_app/lib/services/app_bootstrap.dart:23`, `apps/flutter_app/lib/services/app_bootstrap.dart:60`, `apps/flutter_app/lib/services/app_state_repository.dart:82`
    - **What happens now:** `runApp` waits for directory resolution, metadata loading/recovery, and consolidated Keychain hydration. Keychain authorization can therefore occur before an application loading screen exists.
    - **Why it matters:** Time to first frame includes platform I/O and any authorization delay. Engine initialization is already correctly deferred until after the first frame.
    - **Proposed change:** Render a bootstrap/loading surface immediately, then initialize the repository/controller. Parallelize independent directory lookups. Continue blocking authenticated listings and ordinary persistence until hydration succeeds.
    - **Measure:** Timestamp process entry, bootstrap stages, Keychain completion, and first frame; test delayed authorization and denied hydration.

12. **Settings slider movement queues complete durable metadata saves** — severity `medium`, effort `M`, confidence `confirmed`
    - **Where:** `apps/flutter_app/lib/widgets/app_slider.dart:259`, `apps/flutter_app/lib/widgets/app_slider.dart:291`, `apps/flutter_app/lib/settings/settings_workspace.dart:563`, `apps/flutter_app/lib/controllers/app_controller.dart:2596`, `apps/flutter_app/lib/services/app_state_repository.dart:104`, `apps/flutter_app/lib/services/atomic_metadata_store.dart:66`
    - **What happens now:** Each slider step invokes `updateSettings`, which queues a complete save. Saves serialize rather than replace superseded pending settings. Each replacement encodes metadata, flushes the pending file, validates it, validates the previous primary, and flushes the backup.
    - **Why it matters:** A single drag can enqueue many obsolete generations and repeated disk flushes. Unchanged credentials correctly avoid a Keychain write, but metadata work still repeats.
    - **Proposed change:** Separate immediate in-memory preference updates from coalesced settings persistence, with drag-end/short-debounce flushing. Preserve immediate explicit profile Save/import recovery and truthful save-status reporting.
    - **Measure:** Count queued saves, metadata encodes, and flushes during a full slider drag; verify the last setting is durable and failures remain visible.

13. **Mobile benchmark payload generation and checksumming still consume the UI isolate** — severity `medium`, effort `M`, confidence `confirmed`
    - **Where:** `apps/flutter_app/lib/services/mobile_benchmark_service.dart:238`, `apps/flutter_app/lib/services/mobile_benchmark_service.dart:606`, `apps/flutter_app/lib/services/mobile_benchmark_service.dart:624`, `apps/flutter_app/lib/services/mobile_benchmark_service.dart:505`
    - **What happens now:** The asynchronous benchmark worker runs in a zone, not an isolate. Payload generation fills every byte and calculates both SHA-256 and the configured checksum locally; GET validation also hashes response chunks locally. Payload creation calculates both digests even when validation is disabled.
    - **Why it matters:** CPU work scales with transferred bytes and competes with Flutter rendering. Yielding between 256 KiB blocks improves scheduling but does not remove hashing/generation CPU or its effect on measured benchmark latency.
    - **Proposed change:** Use a reusable bounded worker for generation and validation. Skip genuinely unused digests, retaining S3 signing requirements and exact validation results.
    - **Measure:** Exercise the mobile service directly—the mobile navigation currently hides Benchmark—and compare UI frame times plus generation/hash CPU at increasing concurrency.

## Checked and fine

- **Listener inventory and normal rebuild scope:** Three baseline AppController subscriptions: application bookkeeping (`app/s3_browser_app.dart:69`), shell `ListenableBuilder` (`:219`), and banner timer bookkeeping (`:1228`). The connection sheet, inspector dialog, and results dialog each add one while mounted. Search/inspector/delete request notifiers are separate.
- **Progress ticks:** Transfer notifications are coalesced at `controllers/app_controller.dart:5223`. The shell/header/banner update; Browser, Settings, Benchmark, and Event Log children remain cached when their signatures are unchanged. Jobs remains the exception described above.
- **Selection changes:** They notify immediately and invalidate Browser content through selection/data signatures (`controllers/app_controller.dart:427`, `:1219`; `browser/browser_workspace_frame.dart:24`). I found no unconditional 100k-object filtering/sorting on ordinary progress ticks.
- **Object browsing:** Fixed-extent lazy rows (`browser/object_table.dart:89`), set-backed selection with cached snapshots (`controllers/object_selection.dart:5`), cached query results, reusable object workers, and returned indices (`controllers/object_query.dart:22`).
- **Listing bounds:** Object-count/key-character budgets and cursor-cycle checks remain present (`controllers/app_controller.dart:1074`, `:1118`). Event Log is capped at **5,000**, so 100k retained structured events are not reachable through its normal controller path.
- **Transfer logs:** Shared immutable prefix views survive parsing without full-history copies (`services/transfer_log_accumulator.dart:40`; `services/desktop_sidecar_engine_service.dart:2055`). Failed-request accumulator cleanup remains present.
- **HTTP/mobile transfers:** Reused leased clients, removable cancellation registration, streamed downloads, bounded part workers, and reusable large-payload hashing remain implemented. Azure skips S3 payload hashing.
- **Credentials:** Consolidated bundle hydration, supported migration fallback, unchanged-bundle write suppression, and explicit secure-recovery boundaries remain intact (`services/app_state_repository.dart:249`, `:368`).
- **Previews:** Actual encoded-response limits, aggregate HTML image budgets, bounded decode dimensions, cancellation/disposal, static HTML rendering, and cached source tokens/spans remain present.
- **Animations:** Inspected banner/transfer painters use repaint listenables and boundaries; controllers stop for relevant paused/terminal/reduced-motion states and are disposed. Tile/document geometry caching remains present. The glyph’s `saveLayer` is bounded to 36×40 logical pixels, not a large surface.
- **Known retained tradeoffs:** Loaded version history, the single selectable task-output document, and synchronous benchmark checkpoint encoding remain as documented in the shipped implementation. These were not counted as new regressions.
- **Formatting/models:** No repeated `DateFormat` construction was found. Object rows hold compact listing fields rather than full metadata maps; exact per-object heap size was not measured.

## Not covered

- Runtime profiling, benchmarks, builds, tests, physical-device checks, and background-window animation behaviour were not executed under the read-only constraints. Performance costs above are source-derived estimates.
- Detailed review of every routine administration/edit dialog, generic form/menu widget, mock-engine path, and platform-specific branch was not completed; repository-wide static searches supplemented the focused inspections.
- No files were changed or staged, and no remote state was mutated. Nothing required cleanup: **0 bytes created or removed**. Existing untracked review directories were preserved.