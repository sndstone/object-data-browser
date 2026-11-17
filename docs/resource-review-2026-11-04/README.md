# Object Data Browser resource and reliability review

The app has substantial opportunities to reduce its installed footprint, avoid UI stalls, and make transfers more reliable while retaining its current appearance and functions. The strongest size opportunities are the bundled Python development installation and full Java JDK. The strongest runtime opportunities are bounded pending work, smaller progress messages, less repeated UI computation, and avoiding mobile data relays when the provider can copy objects directly.

This is a review of the working tree on 4 November 2026, including existing uncommitted UI and motion work. Application code was not changed. Findings describe current source behavior; proposed savings and speedups are not benchmark results. Existing release artifacts provide a footprint sample and may predate working-tree changes.

Twenty GPT-6.1 Sol reviewers examined separate areas in waves of up to three. Their source-backed findings were consolidated and representative high-impact paths checked again against the working tree. The review identifies implementation candidates rather than proving every failure on every provider/filesystem.

The first fixes should address conditional Azure move deletion, malformed credential hydration, missing Go version pagination, unbounded pending download tasks, permanent-error retry loops and slow-transfer timeouts. These can lose data, hide data, freeze work or waste completed transfers. Runtime trimming and repeated-work reductions follow without removing engines, controls or visual effects.

## Constraints

Keep all four desktop engines, all supported providers, current controls, layouts, typography, animations, previews, selection semantics and access to logs. Keep credentials in the consolidated Keychain item, preserve explicit secure recovery, bounded previews, S3 part limits, cancellation and atomic download publication. Runtime pruning must happen before signing; public macOS artifacts still require Developer ID signing, provisioning and notarization.

## Verification baseline

- Flutter analysis: passed with no issues.
- Full Flutter suite: 403 passed, eight skipped.
- Go engine unit tests: passed.
- Rust engine unit tests: 15 passed, using the repository's cached toolchain and dependencies.
- Java regression harness: passed through Gradle `test`; checks cover multipart limits and download publication cases.
- Default Python contract suite: 147 passed, 42 skipped. This does not establish contract coverage for every compiled engine or live provider.
- No live endpoint benchmarks, physical-device flows, clean-machine package qualification or filesystem-specific reproduction were performed for this review.

## Size priorities

The existing macOS release app uses approximately 1,047 MiB of allocated disk space. Its Python bundle is approximately 619 MiB and its Java bundle 353 MiB. These are installed allocated bytes from `du`, not compressed installer sizes or unique physical storage after filesystem deduplication.

### Stage a dedicated Python runtime

`scripts/stage-engines.sh:100` copies the entire toolchain prefix. The sample contains 268.8 MiB in `python/pkgs` and 23.1 MiB of headers, alongside Conda metadata and development tools. Stage an explicit runtime payload that retains the interpreter, standard library, required shared libraries, TLS roots, boto3, Azure Identity and native extension dependencies. Do not depend on system Python. Windows already uses a different embedded-runtime path and needs separate qualification.

Test the final package without Python or Conda installed. Exercise S3 and Azure contracts, TLS, credential providers, native checksums and multipart transfers, audit shared-library references, then verify signed entitlements. The cache size is evidence of avoidable payload, not a promise that deleting arbitrary directories produces a valid runtime.

### Replace the full JDK with a tested runtime image

`scripts/stage-engines.sh:240` and `scripts/stage-engines.ps1:410` copy the full Java toolchain. The sample includes 78.9 MiB of module archives and 51.7 MiB of source archives. Start with conservative development-file exclusions, then evaluate `jlink` with dependency analysis and an explicit module list for reflection, TLS, security and authentication.

Run Java contracts and credential-provider flows from every final OS/architecture package without a system JDK. Preserve all engine libraries and current capabilities.

### Make dependency payloads reproducible

`scripts/stage-engines.sh:109` and the PowerShell equivalent resolve dependencies using `pip install --upgrade`. Python requirements pin some direct dependencies but leave others and transitive resolutions mutable. Use reviewed platform-specific locks or wheel manifests with hashes. Compare repeated clean-build payload manifests so regressions can be attributed to source changes.

### Measure Rust size tuning

`engines/rust/Cargo.toml` has no explicit release profile. Evaluate symbol stripping and thin LTO against executable bytes, startup, throughput, memory and build duration. Keep panic behavior and credential/TLS capabilities. This is a lower-priority experiment; Go already strips symbols during staging.

## Transfer reliability and resource use

### Make Azure moves conditional on the copied source

Python `engines/python/src/main.py:1345` copies and then unconditionally deletes the source at line 1348. A concurrent replacement can be deleted after the older bytes were copied. Capture the source identity, condition the copy, and delete only the captured version/ETag. On conflict, retain the changed source and report the conflict. This is a high-priority data-safety fix. Test replacement between confirmed copy and deletion. Go already has conditional deletion in `azure.go:949`.

### Bound pending tasks as well as active workers

Rust `engines/rust/src/main.rs:1738` and Java `engines/java/src/main/java/com/example/s3browser/Main.java:1649` allocate a task/future for every download range before waiting for completion. A 1 TiB object with 8 MiB ranges creates 131,072 tasks even though only a few transfer concurrently. Rust uploads and multipart copy use a similar pattern with a smaller part-count ceiling.

Use fixed workers claiming range indices or refill a small in-flight completion set. Keep progress and cleanup semantics unchanged. A synthetic large logical object should demonstrate that both active workers and allocated pending tasks remain bounded independently of object size.

### Stop retrying permanent mobile filesystem errors

`apps/flutter_app/lib/services/mobile_storage_transfers.dart:395` catches every exclusive-name creation error and retries with a new suffix forever. Disk-full, permission and invalid-name errors are not collisions. Retry only confirmed collisions, check cancellation each iteration, and clean up a reserved placeholder if publication fails. Inject each error and require bounded termination.

### Support download destinations without hard links

Python `engines/python/src/main.py:1606`, Go `engines/go/src/download_destination.go:80` and Rust `engines/rust/src/download_destination.rs:84` require hard links for default keep-both publication. On a filesystem lacking that feature, publication fails after the complete download. Add a supported no-replace publication path while retaining collision and symlink safety and avoiding partially visible final files. Test on exFAT and inject unsupported-link failures. An unchecked exists-then-rename replacement would weaken current guarantees.

### Close every multipart failure path

Java `Main.java:1308` creates an upload before opening the source file. Abort is confined to the future-collection catch at line 1407; file-open and completion failures can bypass cleanup. Guard the complete upload lifetime and attempt abort for definite failures. Reconcile ambiguous completion responses before reporting or retrying a mutation. Test failures at creation, open, part transfer, cancellation and completion.

### Detect changing upload sources

Python `main.py:2999`, Go `main.go:1628`, Rust `main.rs:1409` and Java `Main.java:1335` read mutable local files across parts/retries without a complete source-consistency check before completion. Replaced or edited files can yield mixed remote objects. Capture and revalidate identity, size and modification state before dispatch and completion; prefer stable handles where practical. Metadata checks are useful but cannot prove immutability against every same-metadata edit. Abort detected changes and test queued growth, truncation, replacement and mid-transfer edits.

### Retry failed response bodies at range granularity

Python `main.py:3245`, Rust `main.rs:1777` and Java `Main.java:1697` propagate mid-body transport failures and discard completed ranges. Add bounded retries around the complete range read, preserving version/ETag conditions, rewriting the same offset and counting progress once. Do not retry object conflicts or disk failures as transport errors. Test a connection reset halfway through a range followed by success and exhaustion.

### Keep healthy slow transfers alive

`desktop_engine_host.dart:499` kills a process after two minutes without progress events. Some Rust paths emit only after a whole part/object. A 128 MiB part taking more than two minutes can trigger this despite continuous network progress. Emit throttled byte progress or liveness during streaming and appropriate retry states. Use monotonic elapsed time and retain a real stall deadline. Test both continuous slow progress and a genuinely stalled transport.

### Reduce repeated progress traffic

Python `main.py:3046` and `main.py:3284` append and resend the full accumulated log after every part. Cumulative log serialization is quadratic in part count. Go `main.go:1894` emits full jobs after every network read on single-stream downloads. Introduce sequenced log deltas and coalesced progress with exact terminal counters and immediate terminal delivery. Preserve access to existing user-visible logs. Measure IPC bytes, serialization CPU, UI parsing and throughput on many-part and small-read workloads.

### Preserve distinct versions in download batches

Python `main.py:3159` and its Azure equivalent index version IDs and metadata by key alone. Two versions of one key collapse to the last version, and totals can undercount. Use ordered immutable object references keyed by entry identity or `(key, versionId)`. Test two different-sized versions of the same key, output contents, names and total bytes.

## Mobile transfer priorities

- `mobile_storage_transfers.dart:374` hardcodes sequential 8 MiB download ranges despite supplied manual sizing. Honor the clamped manual value and evaluate bounded concurrency with streaming memory limits, strict validators and exact reconstruction tests.
- `storage_http_client.dart:107` hashes buffered bodies synchronously, including Azure bodies that do not need the S3 digest. Parts can be 128 MiB. Avoid unnecessary hashing and move heavy S3 hashing/transfer work off the UI isolate without starting a worker per tiny request. Profile frame time, memory and cancellation latency.
- `mobile_storage_transfers.dart:134` relays eligible same-endpoint copies through the phone. Add provider-side copy where authorization and source/destination conflict guarantees support it. Preserve tags, metadata, encryption, version pinning, verification and move safety; retain relay for other cases. Assert no body GET for eligible operations.
- `mobile_storage_transfers.dart:251` selects multipart by part size and ignores the accepted threshold setting. Plan threshold and chunk size independently within provider limits. Test below, at and above threshold with a distinct chunk size.
- `controllers/upload_batch.dart:69` repeatedly folds immutable file sizes during snapshots. Cache prepared totals and preserve parent/per-file outcomes. Measure large-batch snapshot cost.
- Java `Main.java:1435` uses a single-request file body without multipart control checkpoints. Test and implement truthful pause/cancel handling during the body and after server commit, preserving actual remote outcome reporting.

## Transport and Azure operations

- `storage_http_client.dart:174` places a 60-second default timeout on the entire upload body. Continuous healthy progress can time out; at 128 MiB this affects rates below roughly 2.13 MiB/s. Use a progress-based inactivity deadline and separately justified overall limit. Test slow continuous upload and true stall.
- `mobile_storage_admin.dart:21` evicts and force-closes the oldest cached client even if it is active. Lease active clients and evict only idle ones. Test an active oldest client while introducing more profile configurations than the cache holds.
- `storage_http_client.dart:162` registers cancellation-future callbacks that cannot be removed when a request completes. Long scopes accumulate captured requests. Use removable registrations and release in `finally`; verify listener count tracks active requests through thousands of requests and cancellation.
- `storage_http_client.dart:228` uses deterministic backoff without server delay hints. Honor bounded retry-delay headers and add jitter with cancellable waits, retaining conservative mutation replay rules. Test throttling timing and cancellation.
- Python Azure uploads at `main.py:1485` and deletes at line 1377 submit every block/key before completion. Reuse bounded dispatch as in its S3 path. Test 50k logical blocks/large delete batches without a corresponding pending-future population.
- Azure copy observation in Python `main.py:1304` and Go `azure.go:907` uses 20 short polls. Pending copies may outlive the budget and become unknown outcomes. Track the same copy ID with configurable deadlines/backoff or resumable observation. Never retry the copy itself or delete the source before confirmed success. Test long-pending success and copy-ID changes.
- Go `azure.go:1131` reads an entire below-64-MiB upload into memory. Stream through a repeatable bounded reader, retaining length/signing and source checks. Measure peak RSS and time to first transmitted byte, with retry and truncation tests.

## Bulk copy and history durability

Python `main.py:5488` relays same-endpoint bucket copies for default skip/fail policies. Evaluate conditional multipart server-side copy only where endpoint and credentials preserve destination no-overwrite guarantees; retain relay otherwise. A HEAD followed by an ordinary copy is insufficient against destination races. Assert no body GET for eligible cases and test destination races and ambiguous completion.

`advanced_workflows.py:69` rewrites and fsyncs the entire history manifest and growing mappings before and after every replay entry. Use a single immutable manifest plus a durable append-only operation journal and compact checkpoints. Preserve the pre-mutation unknown-outcome record and confirmed mapping; test crashes at each boundary and compaction. Merely reducing fsync frequency would weaken current recovery guarantees.

History resumes in 25-entry batches (`app_controller.dart:4683`), with full source relisting and accumulated mapping responses (`advanced_workflows.py:212`, line 283). A 100k-version plan can examine roughly 400 million source-version rows across batches. Return mapping deltas with explicit full export, and investigate execution sessions or snapshots that retain source-change detection and full validation after restart. Test external source changes and resume/reconciliation.

`bucket_copy_journal.dart:16` reads a single checkpoint without typed validation or last-good recovery. Add validated generations and conservative reconciliation of in-flight writes; consider cross-instance locking/unique temporary names. Never replay uncertain overwrites because an older checkpoint is readable. Test corrupted current state, in-flight older generations and concurrent writers while keeping credentials absent.

## Browser and UI computation

### Correct and bound pagination

Go `engines/go/src/main.go:1234` requests only the first 1,000 versions and line 1288 always returns `hasMore: false`. It ignores incoming paired version markers. Implement the existing opaque paired-marker contract and truthful continuation state. Test multiple pages of versions/delete markers, including many versions of one exact key. This is a functional reliability defect, not a proposed reduction in history access.

`app_controller.dart:1021` accepts listing cursors without a shared missing/repeated/cyclic-token guard. Repeated empty pages can evade count/character budgets and loop until cancelled. Validate progress centrally and retain bounded cursor identities, preserving partial results. Test missing tokens, repeats, A→B→A cycles and valid advancing empty pages.

`app_controller.dart:4545` rebuilds a full identity set and list for every additional version page, without a retained-memory window. Maintain an incremental identity index and paged storage/backing store so older versions remain accessible with bounded memory. Test 100k-version pagination, deduplication, context invalidation and access to older pages. Virtualized rows alone do not solve retained-data growth.

### Move version filtering out of synchronous getters

`app_controller.dart:3086` evaluates arbitrary regular expressions on the UI isolate; pathological patterns can freeze it. Counts repeat the filter. Use cached results and a generation-controlled worker with a deadline and termination, preserving all filter options and ordering. Test adversarial regexes in isolation, stale completion and page invalidation.

### Apply selection before loading details

`app_controller.dart:1163` deduplicates the whole selection under one busy action, dropping a second click while the first detail request is pending. Set local selection immediately and generation-control artifact loading separately. Bind context-menu actions to explicit targets. Test delayed A, selection B and late A completion.

`openFolder` at line 1205 and `navigateUp` at line 1225 mutate the prefix before the refresh comparison that resets selection. Centralize navigation and selection invalidation so delayed or failed listings cannot leave actions targeting the previous folder.

### Avoid repeated work for large selections and datasets

- `object_selection.dart:23` scans the visible list even for ordinary non-range toggles. Perform index lookup only for range selection.
- `browser_workspace_frame.dart:40` copies and joins selected keys into a signature on every application notification. Use a selection revision and cached immutable snapshot.
- `object_panel.dart:560` scans the loaded object window to total selected bytes. Cache by dataset and selection revision or maintain indexed/incremental totals.
- `object_query.dart:101` repeatedly lowercases and derives content types during comparisons. Decorate entries with derived keys once, preserving exact tie and folder ordering.
- `object_query.dart:41` copies the dataset into a new isolate for each large query and returns full objects. Evaluate a dataset worker with compact query messages and returned indices; preserve killable regex execution and bounded lifetime.
- `browser_workspace.dart:1723` eagerly constructs all accumulated version rows. Use a builder/sliver while preserving row appearance, controls and scroll position.
- `s3_browser_app.dart:169` reconstructs themes on unrelated controller events. Cache the exact current theme by appearance settings and preserve existing animation semantics.

Validate visual parity across existing light/dark, scaling, compact-row and motion tests. Profile 1k, 10k and 100k object windows and long-key selections. Existing fixed-extent object virtualization, debounce and browser subtree caching should remain.

## Persistence and process lifecycle

### Validate credential schema before successful hydration

`app_state_repository.dart:400` ignores the credential bundle version and accepts a missing profiles map as empty. Malformed or future-schema JSON can enable ordinary saves with emptied credentials. Require the supported schema and record types, routing failure through the existing secure-recovery boundary. Test `{}`, missing/null profiles, unknown versions and malformed records; ordinary saves must perform no secure write after failed hydration. Valid deliberately empty records must remain supported.

### Recover semantically damaged metadata

`atomic_metadata_store.dart:35` validates only outer containers. Model parsing can fail later, outside last-good recovery. Validate typed metadata before accepting a primary or rotating it over a backup. `app_state_repository.dart:181` also selects between macOS locations using primary files alone; consider valid primary/backup candidates in both locations. Test alternate-backup-only and newer-corrupt/older-valid cases without any credential copying or Keychain mutation.

### Reclaim idle sidecar resources

`desktop_engine_host.dart:50` retains idle processes without expiry. Evaluate an idle timeout or memory budget while keeping recently used runtimes warm and excluding active transfers and pinned benchmarks. Measure app-plus-child RSS and subsequent cold/warm latency. This pool is already bounded; this is not an unbounded leak.

### Bound IPC before framing and decoding

`desktop_engine_host.dart:413` applies line splitting before diagnostic bounds, and line 563 decodes JSON synchronously. A huge or newline-free line can consume arbitrary memory first. Enforce protocol and diagnostic byte limits during framing, sized for supported maximum payloads, and consider worker decoding for large valid responses. Test giant diagnostics, oversized JSON and legitimate large pages/exports.

### Keep client cache locks short

Rust `main.rs:2424` holds a global mutex across asynchronous configuration; Python `main.py:348` and Azure line 953 build clients under a shared cache lock. A slow cold profile can block unrelated cache hits. Build outside short locks or coordinate initialization per key, retaining active-client ownership. Test a slow miss concurrently with a warm hit.

## Preview resource boundaries

### Bound actual image loading and decoded pixels

`app_controller.dart:3684` checks listed encoded size, but `browser_workspace.dart:1505` and `object_preview_dialog.dart:243` use unrestricted network images. A replaced object can exceed the listed size, and a highly compressed image can expand to hundreds of MiB of decoded pixels. Use a bounded cancellable loader, validate current response and identity where feasible, and manage decoded dimensions separately from encoded bytes. Inline decoding should match display needs while expanded pan/zoom retains controlled higher-resolution access. Test huge dimensions, stale listings, chunked oversized responses and zoom fidelity.

Rendered HTML at `object_preview_dialog.dart:338` can also reference many external images. Confirm the pinned renderer's loading behavior, then apply bounded resource concurrency and aggregate budgets, with cancellation on close/source switch. Preserve relative resolution and static rendering without forwarding authorization to unrelated origins.

### Cancel superseded text loads and validate responses

`app_controller.dart:3825` has no body inactivity or overall deadline; stale-result rejection does not close the superseded request. Give preview loads cancellation ownership and terminate them on selection change and disposal. The same method accepts error bodies without checking HTTP status, so an expired URL's error document can appear as ready object content. Validate expected success/range responses and show bounded sanitized failures. Test headers-then-stall, slow bodies, disposal, selection changes and 403/404/500 responses.

### Parse source previews once

`preview_source_view.dart:54` invokes syntax parsing for width measurement and `source_code_preview.dart:20` parses again for selectable text. Cache tokens by source/language, share styled spans and cache measurement by presentation settings. Test exact selectable text and colors, count parser calls and profile 64 KiB documents during resizing.

## Logs and animation work

- `app_controller.dart:5058` scans and reconstructs task histories on each transfer update. Use indexed records and ordered IDs with revision-based view/count caches while preserving all retained history and newest-updated order. Test one live transfer with 10k completed jobs.
- `tasks_workspace.dart:408` repeatedly joins and lays out full selected-task output. Cache by output revision and evaluate incremental/lazy selectable output while preserving all accessible lines, copying and scrolling.
- `structured_log_list.dart:360` parses legacy payloads and line 403 eagerly formats details for collapsed rows. Defer detail construction until expansion and cache immutable payloads. Require no detail formatting for collapsed entries and identical expanded content.
- `event_log_workspace.dart:62` repeats category/severity scans outside its filter cache. Cache counts together by event revision, normalize search once and skip searchable-string creation for an empty query. Preserve level-or-source matching and export behavior.
- `app_controller.dart:3184` clears finished tasks without clearing `_jobEngineOwners`. Remove obsolete terminal ownership after reconciling late callbacks; test that clearing returns bookkeeping to active-job size.
- `browser_workspace.dart:462` keeps the collapsed inspector under `Offstage`, which leaves descendant tickers active. Mute them with `TickerMode` only once the panel is fully collapsed, preserving its visible transition and live state.
- `edge_fade_scroll.dart:63` and line 128 retain shader masking even when the gradient is fully opaque. Evaluate a stable render proxy that bypasses masking when neither edge fades, preserving scroller identity.
- `trace_tile_indicator.dart:279` and `file_scan_indicator.dart:211` rebuild static paths and metrics each frame. Cache fixed geometry while retaining current animated effects and disposing native resources. This is a modest opportunity; profile before prioritizing it.

Existing motion code already uses repaint-driven painters and boundaries, stops paused/terminal controllers, supports reduced motion and disposes resources. There is no basis here for removing animations or claiming a general controller leak.

## Benchmark accuracy and overhead

- `mobile_benchmark_service.dart:641` rebuilds and sorts up to 10k retained records and 3,600 series points on status polls, including unchanged runs; checkpoints repeat summary and synchronous JSON work. Cache by measurement revision and evaluate incremental aggregates/worker encoding. Require exact output/statistics parity and profile UI latency.
- `mobile_benchmark_service.dart:238` flushes CSV before the periodic checkpoint, but resume appends without reconciling uncommitted rows. Store and validate a committed CSV offset/count and reconcile crash tails. Reject missing/truncated committed data unless it can be reconstructed. Test termination between CSV flush and checkpoint, including histories beyond the retained-record window.
- `mobile_benchmark_service.dart:435` increments checksum errors but records success, and CSV line 263 hardcodes success. Align validation/transport fields with the cross-engine contract and export the actual result. Test same-length corrupted responses across live history, CSV, JSON and summaries.
- `mobile_benchmark_service.dart:344` rescans the active-object set for each worker. Build indexed batch candidates and reserve incrementally, preserving exact operation/key planning, bounds and distribution. Test sequence parity before benchmarking 100k-object, 64-worker planning.
- Go `benchmark_owner.go:86` holds the owner mutex during network batches and checkpoint work, blocking status/pause/stop. Separate immutable snapshots and short state transitions from network execution, with independently accessible controls. Test acknowledgment while a fake request remains blocked, plus truthful remote outcomes.

## Native mobile lifecycle and dependency opportunities

- Android `MainActivity.kt:322` sequentially requests versioning for every bucket after listing, adding one network request per bucket. Cache metadata with explicit invalidation and bound concurrent cache misses. Internally distinguish failed lookups from confirmed disabled versioning. Test 100 delayed/denied lookups and unchanged successful metadata.
- Android `MainActivity.kt:1207` and iOS `IosEngine.swift:1367` construct clients per native request. Android has no explicit client shutdown. Use active leases with a bounded idle cache or close short-lived clients in `finally`, respecting credential/configuration identity. Measure client/pool counts and warm latency; do not assume an iOS leak from construction alone.
- Android `MainActivity.kt:63` owns an executor and outstanding requests without corresponding Activity/engine teardown cleanup. Detach handlers, cancel owned work and release executors/results exactly once at owner teardown. Test recreation while a request is blocked and preserve truthful mutation outcomes.
- `google_fonts` only disables its own runtime fetching, while Inter/Sora already use bundled family names; `cupertino_icons` has no functional icon references. Evaluate removing these dependencies and catalogue entries while retaining fonts/licenses. Tree shaking may already eliminate most payload, so actual size benefit requires a release asset report and visual verification.

## Verification gaps to close with optimization

- `.github/workflows/verification.yml:80` builds native engines but does not run their unit/regression suites. Add mandatory Go/Rust/Java native tests alongside protocol contracts; confirm executed tests and intentional-failure propagation.
- `.github/workflows/release-matrix.yml:67` and `scripts/verify-windows-package.ps1:55` hardcode release 2.3.3 while the app declares 2.3.4. Derive current qualification expectations from the version source; keep an older upgrade fixture explicitly separate.
- Final packaged runtimes lack routine contracts on all platforms. Run each manifest executable from its final payload and working directory in a clean environment, with no fallback to system Python/Java. This is essential before runtime pruning.
- Cross-platform download-safety CI at `verification.yml:88` defaults to Python. Include staged Go/Rust/Java with explicit engine commands and required availability, especially for publication changes.
- Ordinary CI lacks an iOS simulator compile check. Add one for relevant native/dependency changes; retain physical-device Keychain/local-network release qualification.

## Implementation order

1. Fix conditional Azure move deletion, secure hydration validation, selection targeting, permanent-error loops, multipart cleanup and pending-task bounds. Add fault-injection tests before performance tuning.
2. Produce runtime-only Python and Java staging, dependency manifests and signed clean-machine package qualification. Measure installed and compressed bytes separately.
3. Reduce progress/IPC volume, cache selection/query/theme work, virtualize versions and remove unnecessary mobile UI-isolate hashing.
4. Add compatible publication, per-range recovery, source-change checks and provider-side mobile copies with explicit conflict and uncertain-outcome tests.
5. Tune idle process retention, query worker reuse and Rust release profiles using measured memory/latency tradeoffs.

For each change, retain the same UI and feature contract, run Flutter analysis and the full suite after app changes, and run affected engine contracts. Record p50/p95 latency, UI frame timing, idle and active CPU, app-plus-sidecar peak RSS, network bytes and installer/installed size on the same hardware and workloads. Do not turn estimates into claimed improvements before those measurements.

## Review coverage

| Reviewer | Focus |
| --- | --- |
| 01 | Controller object querying and selection |
| 02 | Mobile transfers and multipart planning |
| 03 | Rust transfers |
| 04 | Go transfers |
| 05 | Python transfers |
| 06 | Java transfers |
| 07 | Desktop sidecar process and IPC lifecycle |
| 08 | Credentials, metadata persistence and recovery |
| 09 | Runtime packaging and release footprint |
| 10 | Browser widget construction and repeated computation |
| 11 | Motion, tickers and raster work |
| 12 | Text, code, image and HTML previews |
| 13 | Tasks, event logs and transfer presentation |
| 14 | Mobile HTTP transport and cancellation |
| 15 | Azure transfers and copy safety |
| 16 | Bulk copy and durable history workflows |
| 17 | Benchmark overhead, controls and result integrity |
| 18 | CI and package qualification |
| 19 | Native mobile lifecycle and Flutter dependencies |
| 20 | Listing pagination and resource bounds |

## Reproduction and measurement checklist

Use deterministic fake endpoints for source replacement, connection resets, throttling, malformed pagination and stalled responses. Use synthetic large logical range counts instead of allocating huge test objects just to verify scheduler bounds. Benchmark long-key object selections, accumulated version pages, retained task histories and many-part progress independently so each saving can be attributed.

Qualify real exFAT publication and final signed runtime packages separately from source tests. For mobile changes, compile the simulator target and complete physical-device Keychain and local-network flows before release. Validate typography, all icons, scrolling, selectable previews, pan/zoom and representative interrupted motion states when changing resource management around presentation.

Retain existing protections: bounded object windows, fixed-extent object rows, search debounce, stale-response guards, scoped listing cancellation, consolidated secrets and unchanged-bundle write suppression, source validators and range validation, staging before publication, bounded transfer buffers, conservative mutation retries and explicit unknown-outcome reconciliation.
