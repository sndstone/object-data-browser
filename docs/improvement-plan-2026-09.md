# Project improvement plan — September 2026

Reviewed on 12 September 2026 against commit `5ee6316`, app `2.2.7+1`.

The next increment should prioritize safe downloads and moves, then trustworthy benchmark reporting and consistent Settings behavior. The project already has useful foundations: bounded sidecar admission, listing cancellation, isolated object queries, lazy browser rows, credential-store recovery, and substantial Flutter coverage. Preserve these while making targeted changes.

Implementation has been completed locally across the items below. See the
[implementation ledger](improvements-implementation-2026-09.md) for the delivered
behavior, verification, and remaining platform release checks. The findings and
estimates below retain the original review context. The earlier
[backend and Settings proposal](backend-settings-improvement-plan.html) supplies
historical mockups; its B01–B03 cases are now normal regression tests.

## Verification and confidence

| Check | Current result |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test --no-pub --reporter expanded` | 156 passed, 2 skipped |
| Go engine compilation | Passed using the repository toolchain |
| `python3 docs/review-2.2.6/reproduce.py` | Reproduced all four unsafe outcomes below |
| Settings, transfer wiring, benchmark fallback, CI | Source inspection; findings distinguished from runtime reproductions below |

The reproduction harness uses disposable local files, a fake Python storage client, and a loopback HTTP server for Go with fictional credentials. It proves application behavior under those inputs; it does not measure how often real providers produce those responses. The complete four-engine contract matrix, native builds, live UI inspection, real-provider transfers, and physical-device checks were not run during this review. A green Flutter suite does not establish backend data safety.

## Ordered backlog

Effort is a rough engineering estimate including focused regression coverage, not a delivery commitment. Cross-platform verification may extend it.

| Order | Work item | Priority | Evidence | Rough effort |
| --- | --- | --- | --- | --- |
| 1 | Require confirmed Azure copy success before source deletion | P0: data safety | Reproduced | 1–2 days |
| 2 | Protect download destinations and resolve name collisions | P0: data safety | Reproduced in Python; audit other engines | 3–5 days |
| 3 | Validate downloaded ranges and actual byte counts | P0: integrity | Reproduced in Python; audit other engines | 2–4 days |
| 3a | Make Cancel stop the action shown in its details | P1: action control; user-requested | Current dispatch inspected; broader runtime audit needed | 3–5 days initially |
| 4 | Remove invented benchmark measurements | P1: reporting correctness | Confirmed source paths | 2–4 days |
| 5 | Make profile testing, saving, and activation distinct | P1: workflow correctness | Confirmed source paths | 2–4 days |
| 6 | Make transfer settings reflect effective engine behavior | P1: configuration correctness | Confirmed source wiring | 3–5 days |
| 7 | Expose general settings persistence failures | P1: persistence feedback | Confirmed source paths | 1–2 days |
| 8 | Simplify Settings navigation and explain capabilities | P2: usability | Product proposal | 2–4 days |
| 9 | Extract cohesive controller and benchmark modules | P2: maintainability | Source structure | Several small changes |
| 10 | Strengthen CI reproducibility and reconcile documentation | P2: maintenance | Source/configuration inspection | 1–3 days initially |

### 1. Azure move must retain the source until copy success

**Evidence:** `engines/go/src/azure.go`, `azureCopyObject` and `azureMoveObject` (around lines 755–795). Copy polling stops after 20 attempts, but only `failed` and `aborted` statuses return errors. A still-pending copy returns success and the move proceeds to DELETE. The current fixture observed `ok: true`, 20 pending polls, and a source DELETE.

**Change:** Require an explicit successful terminal copy status associated with the initiated copy. Return a typed timeout or unresolved outcome when polling ends without confirmation; retain the source. Handle missing status, failed/aborted copies, and source deletion failure explicitly. Audit Python's Azure copy/move semantics in the same change.

**Example:** Moving `invoices/2026.csv` must leave the source intact if the destination copy has not completed by the deadline. Show “Copy not confirmed; source retained,” with enough context to inspect the destination before retrying.

**Acceptance:** Shared loopback tests cover pending forever, missing status, failure, abort, eventual success, and failed source deletion. Only confirmed success permits DELETE. Do not automatically replay a mutation with an unresolved outcome.

### 2. Download safely into staging files and handle collisions

**Evidence:** `engines/python/src/main.py`, `_start_download`, around lines 2922–2925. Destinations use `Path(key).name` and are opened with `wb` before GET succeeds. The fixture downloaded `a/report.txt` and `b/report.txt` into one `report.txt` containing only the second object. A failed GET left an existing destination at zero bytes.

**Change:** Define a shared destination policy and per-object result mapping. Offer explicit conflict choices such as keep both, skip, or replace; use unique temporary files in the target directory and publish the final file only after validation. Decide how to preserve folder structure. If keys become relative paths, enforce containment and account for traversal, symlinks, invalid platform filenames, and case-insensitive collisions. Audit all desktop and mobile download implementations before claiming parity.

**Example:** `team-a/report.csv` and `team-b/report.csv` produce two distinct files, with the final locations shown in Tasks. A failed replacement leaves the user's old file unchanged.

**Acceptance:** Test duplicate basenames, pre-existing files, mid-stream failures, cancellation, zero-byte objects, unsafe keys, and platform-specific collisions. Existing bytes survive every failed transfer; temporary files are cleaned up or clearly recoverable. Check destination conflicts again when committing the staged file.

### 3. Reject incomplete or inconsistent downloads

**Evidence:** Python `_download_one_range`, around lines 2937–2963, writes the received data but returns the requested byte count. The fixture supplied three bytes for a 1 MiB range; the job reported completion and 1 MiB transferred, leaving a mostly zero-filled file.

**Change:** Count actual bytes, reject short/oversized bodies and inconsistent range responses, and validate the complete object before publishing the staged file. Bind range requests to a consistent object version or validator where supported. Use checksums when their algorithm and semantics are known; do not assume every ETag is a content hash.

**Acceptance:** Fixtures exercise short and oversized bodies, ignored ranges, mismatched range metadata, object changes between parts, and ordinary successful downloads. No invalid object reaches `completed`; progress reflects actual accepted bytes. Extend the shared contract suite across engines, starting with Python.

### 3a. Make Cancel stop the action shown in its details

**Requested behavior:** The Cancel button for an active action must stop that specific action, with the same behavior and status in the action details, task controls, and any inline progress panel. Closing an action-details panel must remain separate from cancellation.

**Evidence:** `tasks_workspace.dart` routes action, transfer, tool, and benchmark controls through different controller methods. `AppController.cancelTask` only routes ordinary action cancellation for listing action keys, and that path calls the shared `cancelListing`. Transfer/tool cancellation uses `activeEngineId`, so routing must be audited when the user changes engines after starting a job. `cancelToolTask` marks the task cancelled after receiving a response without deriving that status from the returned execution state. These are source observations, not new runtime reproductions. Existing listing cancellation already releases stalled reads and ignores late results; retain those protections.

**Change:** Bind each running action to its task/request ID, originating engine, and cancellation handle. Have every Cancel entry point invoke the same action-specific command. Stop queued child operations immediately, signal active workers, and cancel/close the underlying request where supported. Preserve unrelated actions and completed results. Keep action details synchronized with the actual lifecycle: Running → Cancelling → Cancelled, or an explicit failed/unknown outcome. Do not mark an action cancelled merely because the button was pressed, or let a late success overwrite its cancellation state.

**Examples:** Cancelling “List objects in photos/” from either its progress panel or action details stops that listing while a separate upload continues. Cancelling a five-file upload stops queued files and requests cancellation of the active file. Its details retain completed files and show which file was interrupted. Changing the selected engine must not redirect cancellation away from the engine that owns the job.

**Engine scope:** Audit listings, connection tests, transfers, benchmark runs, test-data creation, delete-all, and multi-step copy/move/delete actions. Add cooperative cancellation where missing. Until an engine can stop an active operation, clearly show the actual boundary, for example “Stopping after current file; remaining files cancelled.” Never terminate a process shared with unrelated work or imply that completed remote writes were rolled back. Unconfirmed mutations require an explicit unresolved outcome and inspection before retry.

**Acceptance:** Add controller/widget and engine tests for both inline and action-details Cancel controls, hung requests, queued jobs, active workers, repeated clicks, completion/cancellation races, engine/profile switches, and late events. Assert that the targeted action stops dispatching work, releases resources, and reaches a truthful final state in every view; unrelated jobs continue. Preserve completed pages/files and abort incomplete multipart uploads on cancellation where supported. Test unsupported and failed cancellation responses without reporting false success. Run Flutter analysis/full tests and the affected engine contract checks.

### 4. Display measured benchmark data and explicit missing states

**Evidence:** `AppController.benchmarkSummaryForRun` falls back to `_syntheticBenchmarkSummary` when no result summary exists. That method invents time series, percentiles, retries, and successful checksum counts. `benchmark_workspace.dart` also derives missing percentile values from average latency in `_sizeMetricValue` (around line 3796). These are source-confirmed fallback paths; this review did not establish which production engines currently exercise each one.

**Change:** Keep synthetic data inside the mock/demo service. Production results should distinguish measured values, explicitly labeled estimates, and unavailable fields. Preserve legitimate observed totals when detailed metrics are missing. Audit charts and exports together.

**Example:** If a backend supplies average latency but no distribution, show “P99 unavailable” instead of multiplying the average by 1.42. Never infer successful checksum validation from a configuration toggle.

**Acceptance:** A run with no summary or partial metrics produces no invented percentiles, samples, retry counts, or checksum successes in the UI or export. Measured zero remains distinguishable from unavailable. Demo charts remain available through the mock service.

### 5. Separate profile drafts, tests, saves, and activation

**Evidence:** In `settings_workspace.dart` around lines 1543–1573, both Test and Use profile first call `saveProfile`. Test then continues without checking the save result. `testProfileById` updates the profile and, for the selected profile, replaces the bucket list, selects its first bucket, and refreshes objects. Thus testing has persistence and browsing side effects. Secure Save itself already checks persistence success; preserve that protection.

**Change:** Introduce a test operation accepting a draft without persisting or changing browser selection. Return a structured save outcome and keep the session-only state visible independently of connection-test banners. Track persistence state per profile. Make activation and the startup default separate actions; currently `setDefaultProfile` also activates the profile.

**Example:** Editing an endpoint and clicking Test verifies that draft while leaving the saved endpoint, current bucket, and startup default intact. A successful test after failed secure persistence still shows “Credentials available for this session only.”

**Acceptance:** Widget/controller tests cover dirty drafts, failed secure writes followed by successful tests, two profiles with different save states, activation, and startup-default changes. Existing hydration-failure blocking and explicit Save/import recovery boundaries remain intact.

### 6. Make transfer settings effective and explain their scope

**Evidence:** Settings exposes “Concurrent transfers.” `updateSettings` forwards that value into the benchmark draft; ordinary `startUpload`/`startDownload` calls pass multipart settings but no corresponding global concurrency value. Desktop profile serialization uses profile-level `maxConcurrentRequests`; Python part workers additionally cap themselves at eight. File batches intentionally dispatch files sequentially. These represent different limits currently presented without a clear relationship.

**Change:** Document and implement precedence for application defaults, profile overrides, and engine limits. Distinguish simultaneous files from workers within one file. Show the effective limits for the selected engine, and disable or explain controls it cannot honor. Review retry/timeout settings through the same path. Preserve sequential batch dispatch and bounded worker memory unless separately changing that design.

**Example:** Transfer details show “Files: one at a time; part workers: 8; part size: automatic, 64 MiB for this file.” A setting intended only for benchmarks belongs in Benchmark settings.

**Acceptance:** Tests trace each exposed setting from UI through serialization to actual worker/request behavior. Unsupported settings never imply an effect. Multipart sizing boundary tests and memory bounds remain satisfied. Any contract extension must be coordinated across supported engines.

### 7. Show when non-secret settings could not be saved

**Evidence:** `AppController.updateSettings` changes memory and awaits `_persistState` without using its boolean result. `_persistState` logs failures, but this caller provides no direct persistent save-state feedback. `deleteProfile` similarly announces deletion before checking persistence. These are source findings; a disk-failure fixture was not run in this review.

**Change:** Return and consume structured persistence outcomes. Distinguish effective session state from durable state, show a recoverable warning, and offer retry where appropriate. Ensure a profile removed only from memory is not described as durably deleted.

**Acceptance:** Inject metadata-write failures and credential-store blocking. The user sees “Applied for this session; could not save” and a later successful retry clears it. Normal preference changes must not rewrite an unchanged secret bundle; hydration-failure recovery rules remain unchanged.

### 8. Simplify Settings after fixing its behavior

**Proposal:** Reuse the existing report's Settings mockups as a starting point. Reduce the nine desktop categories to six: Connections, Transfers & Storage, Appearance, Safety & Recovery, Benchmark, and About & Diagnostics. Move startup preferences into the relevant connection/engine controls. Use a connection list plus one editor on desktop and a list-to-editor flow on phones. This grouping is a proposal, not a tested user preference.

Expose provider/engine incompatibilities before a user starts a workflow. For example, selecting Azure with Rust should explain that the engine lacks Azure support and offer a supported engine choice. Put advanced transport settings behind progressive disclosure while keeping endpoint, credential state, Test, Save, and Activate easy to find.

**Acceptance:** Check keyboard navigation, focus, screen-reader labels, 130% and 200% text scaling, light/dark themes, and widths near 390, 700, 1000, 1360, and 1500 px. Preserve drafts across navigation. Add focused widget checks for the revised interactions and inspect the actual rendered UI.

### 9. Extract modules around tested responsibilities

**Evidence:** `app_controller.dart` is 4,756 lines and `benchmark_workspace.dart` is 4,749 lines. They combine many independently changing responsibilities. Several engines also live primarily in one multi-thousand-line source file. Size alone is not a bug, but it increases the review surface for fixes.

**Change:** Start with profile/settings persistence outcomes and benchmark result presentation, then transfer orchestration. Retain the existing controller facade initially. Move coherent behavior with its tests, and avoid mixing large file movements with data-safety changes. For engines, extract transfer and provider modules incrementally after contract coverage protects their behavior.

**Acceptance:** Public behavior and request semantics remain stable; existing tests stay green. Each extraction makes a later change localized and independently testable. Do not use this as a prerequisite for fixing items 1–3.

### 10. Make verification reproducible and status documentation accurate

**Evidence:** Verification already runs Flutter analysis/tests and a four-engine contract matrix, which is valuable. Flutter setup follows floating `stable` in both CI and bootstrap; an existing local cache can therefore differ from a fresh CI checkout. README's current application-version sentence still says `2.2.6+1` while the pubspec is `2.2.7+1`. The feature matrix also contains broad cancellation/benchmark-control requirements alongside engine-specific unsupported controls.

**Change:** Pin the tested Flutter version consistently and define an intentional update process. Promote the review harness cases into the normal contract suite as items 1–3 are fixed. Add targeted Windows/macOS verification for changed filesystem or credential behavior. Reconcile documentation against capabilities and separate implemented, unsupported, and proposed features. Record real-provider and physical-device release checks separately from loopback fixtures.

**Acceptance:** A fresh local setup and CI use the same Flutter release. Each repaired backend defect has a failing-before/passing-after regression. Capability documentation agrees with engine descriptors and UI behavior. Dependency upgrades are separate, reviewed changes with appropriate platform verification.

## Suggested delivery sequence

1. **Data safety and cancellation increment:** Implement items 1–3 and the requested action-specific Cancel behavior in item 3a as small reviewable changes with shared regressions. Design download cleanup and cancellation together. Require the complete supported desktop engine contract matrix before calling parity complete.
2. **Trust and configuration increment:** Implement items 4–7. Establish result/save-state models before polishing the controls that display them.
3. **Usability increment:** Implement item 8 using the existing mockups and actual Flutter visual checks.
4. **Maintenance alongside delivery:** Start item 10 immediately; perform item 9 in small extractions where it simplifies the next change.

For every app change, run `flutter analyze` and the full Flutter suite. Add multipart boundary tests when changing sizing. Packaging changes require the repository's platform checks: macOS release build/signature/effective entitlements; iOS simulator build and physical-device Keychain/local-network verification before release. Keep credentials exclusively in the secret store and exports metadata-only throughout.

The best first work item is **Azure copy/move safety**: it has a narrow code path, a repeatable failure, and an unambiguous acceptance criterion. Follow immediately with a joint download-staging and integrity design so items 2 and 3 share the same completion boundary.
