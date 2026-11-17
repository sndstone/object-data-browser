## Summary

Object Data Browser already has substantial administration and recovery functionality; the older improvement plans should not be treated as an unfinished backlog. The highest-value additions are a durable everyday transfer queue, reviewed folder sync, bucket-wide search, bulk property editing, and bandwidth controls. Cross-profile bucket copy, Object Lock, archive restore, multipart inspection/abort, named AWS profiles and AssumeRole already exist. The main opportunity is to connect these capabilities into repeatable workflows while preserving credential isolation, bounded resources and explicit unknown mutation outcomes. This was a read-only source review: no files changed, builds/tests/network requests run, or remote state modified.

## Inventory

Paths are repository-relative. “Present” means verified in source, not newly runtime-qualified.

| Area | Verified current behavior | Evidence |
|---|---|---|
| Browsing/search | Hierarchical/flat listing, cursors, sorting, prefix search and local text/regex filtering; bounded listing windows. Text/regex cover loaded objects. | `apps/flutter_app/lib/controllers/app_controller.dart:1050`; `apps/flutter_app/lib/controllers/object_query.dart:22`; `apps/flutter_app/lib/browser/object_panel.dart:115` |
| Transfers | Multipart uploads/downloads, sequential multi-file parent jobs, progress and capability-dependent controls. Separate desktop recoverable-upload/download workflows exist. | `apps/flutter_app/lib/controllers/upload_batch.dart:128`; `apps/flutter_app/lib/browser/storage_admin_dialog.dart:690` |
| Sync | One-time remote bucket copy with checkpoints exists. No folder-sync/mirror planner appears in the inspected contract or dispatch surfaces. | `apps/flutter_app/lib/controllers/app_controller.dart:4742`; `contracts/engine_contract.json:16`; `engines/python/src/advanced_workflows.py:26` |
| Sharing/presign | GET links, expiry, curl command, exact-version sharing and provider-specific SAS. No upload-sharing workflow in the inspected API. | `apps/flutter_app/lib/controllers/app_controller.dart:2071`; `engines/python/src/main.py:2846`; `engines/python/src/advanced_workflows.py:579` |
| Versioning | History, delete markers, exact-version operations, restore-as-current and desktop S3 history copy with remapped version IDs. | `apps/flutter_app/lib/controllers/app_controller.dart:4684`; `engines/python/src/main.py:5434`; `engines/python/src/advanced_workflows.py:306` |
| Lifecycle/policy admin | Access/ACL and lifecycle presets; policy/CORS/tags; protection, retention, legal holds; archive restore. Replication/notifications can be inspected. | `apps/flutter_app/lib/controllers/app_controller.dart:4556`; `engines/python/src/main.py:5491`; `engines/python/src/main.py:5554` |
| Previews | Selectable highlighted source, images and static HTML; bounded loading. Video currently displays a generated URL. | `apps/flutter_app/lib/controllers/app_controller.dart:3836`; `apps/flutter_app/lib/browser/browser_workspace.dart:1552` |
| Profiles/credentials | Consolidated secure credential bundle, metadata-only state/exports, explicit recovery; static/session credentials, desktop AWS chains/roles and Azure identity modes. | `apps/flutter_app/lib/services/app_state_repository.dart:53`; `apps/flutter_app/lib/services/app_state_repository.dart:114`; `apps/flutter_app/lib/widgets/connection_options_editor.dart:43` |
| Benchmarks | Configure/run/results/history, latency/throughput/checksum views, CSV export and continuous worker execution. Mobile workspace hidden. | `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:20`; `engines/python/src/main.py:4918`; `apps/flutter_app/lib/app/s3_browser_app.dart:62` |
| Logs/jobs | Searchable structured events, request relationships, job details, retry/control actions, diagnostic JSON and plain-text event export. In-memory events bounded. | `apps/flutter_app/lib/tasks/tasks_workspace.dart:15`; `apps/flutter_app/lib/event_log/event_log_workspace.dart:17`; `apps/flutter_app/lib/controllers/app_controller.dart:2915`; `apps/flutter_app/lib/controllers/app_controller.dart:4318` |
| Automation | Engine protocol and built-in test-data/delete-all tools; no user-facing sync/scheduling/automation methods in inspected contract. | `contracts/engine_contract.json:49`; `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:30` |
| Platform integration | Desktop drag-in, keyboard shortcuts, platform download/open flows; iOS foreground transfers stop on backgrounding. Files-provider/virtual-drive integration was not found in inspected app surfaces. | `apps/flutter_app/lib/browser/browser_workspace.dart:535`; `apps/flutter_app/lib/app/app_shortcuts.dart:27`; `apps/flutter_app/lib/controllers/app_controller.dart:3089`; `apps/flutter_app/lib/app/s3_browser_app.dart:73` |

## Proposals

Severity below expresses feature priority, not a newly discovered defect. Effort includes implementation and focused verification: **S** small, **M** moderate, **L** substantial, **XL** architectural.

The following shared integration routes avoid repeating long engine inventories in every proposal:

| Route | Contract, controller/service and engine anchors |
|---|---|
| **T — ordinary transfers** | Contract `contracts/engine_contract.json:38`; controller `apps/flutter_app/lib/controllers/app_controller.dart:1590`; Python `engines/python/src/main.py:3131`, `engines/python/src/main.py:3382`; Go `engines/go/src/main.go:1530`, `engines/go/src/main.go:1735`; Rust `engines/rust/src/main.rs:1558`, `engines/rust/src/main.rs:1874`; Java `engines/java/src/main/java/com/example/s3browser/Main.java:1225`, `engines/java/src/main/java/com/example/s3browser/Main.java:1398`; mobile `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:67`. |
| **L — object enumeration** | Contract `contracts/engine_contract.json:34`; controller `apps/flutter_app/lib/controllers/app_controller.dart:1050`; Python `engines/python/src/main.py:2353`; Go `engines/go/src/main.go:748`; Rust `engines/rust/src/main.rs:680`; Java `engines/java/src/main/java/com/example/s3browser/Main.java:658`; mobile `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:231`. |
| **A — advanced operations** | Contract `contracts/engine_contract.json:58`, `contracts/engine_contract.json:69`; controller `apps/flutter_app/lib/controllers/app_controller.dart:4653`; desktop service explicitly selects Python at `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:56`; Python dispatch `engines/python/src/main.py:5423`, `engines/python/src/advanced_workflows.py:52`; mobile dispatch `apps/flutter_app/lib/services/mobile_storage_admin.dart:172`. |
| **P — sharing** | Contract `contracts/engine_contract.json:48`; controller `apps/flutter_app/lib/controllers/app_controller.dart:2071`; Python `engines/python/src/main.py:2846`; Go `engines/go/src/main.go:1991`; Rust dispatch `engines/rust/src/main.rs:315`; Java `engines/java/src/main/java/com/example/s3browser/Main.java:1547`; mobile `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:238`. |

1. **Make the ordinary transfer queue survive restart** — **high · XL · confirmed**

   - **Where:** T and A; `apps/flutter_app/lib/controllers/app_controller.dart:1590`; `apps/flutter_app/lib/services/app_state_repository.dart:132`; UI `apps/flutter_app/lib/tasks/tasks_workspace.dart:15`.
   - **Now/problem:** Ordinary uploads dispatch immediately; application state persists settings/profiles, while recoverable transfers live in a separate administration workflow. Users cannot treat everyday Jobs as a durable queue.
   - **Change:** Persist credential-free queue manifests, per-file outcomes and engine recovery IDs; restore them into Jobs with explicit reconciliation before continuation. Add typed queue/recovery descriptors and resume/inspect operations.
   - **Scope/risks:** All four desktop engines; shared mobile adapter separately. Preserve source fingerprints, staged publication and unknown-completion reconciliation. Keep ordinary failure abort behavior; durable recovery must be an explicit transfer mode.
   - **Competition — from memory, unverified:** rclone tooling and traditional transfer clients offer varying retry/queue/resume workflows; guarantees differ.

2. **Add reviewed one-way folder sync/mirror before two-way sync** — **high · XL · confirmed**

   - **Where:** L/T/A; existing copy controller `apps/flutter_app/lib/controllers/app_controller.dart:4742`; copy UI `apps/flutter_app/lib/browser/bucket_copy_dialog.dart:206`; checkpoint model `apps/flutter_app/lib/services/bucket_copy_journal.dart:5`.
   - **Now/problem:** Bucket copy is a one-time remote operation; it does not express local-folder comparison, deletions or conflicts.
   - **Change:** Add `planSync`/`applySyncPlan` with immutable dry-run results, include/exclude rules and explicit delete propagation. Start local→remote and remote→local; add two-way sync only after durable baselines, tombstones and conflict resolution.
   - **Scope/risks:** Flutter planner plus all transfer engines; desktop first. Plans must expire/revalidate, preserve exact keys and reject unsafe local paths. Retain sequential file dispatch and bounded part workers.
   - **Competition — from memory, unverified:** rclone, WinSCP, Transmit and ForkLift provide synchronization/comparison workflows; Mountain Duck emphasizes mounted access.

3. **Provide bucket-wide structured search with honest execution modes** — **high · L · confirmed**

   - **Where:** L; `apps/flutter_app/lib/controllers/object_query.dart:22`; UI `apps/flutter_app/lib/browser/object_panel.dart:115`; model `apps/flutter_app/lib/models/domain_models.dart:560`.
   - **Now/problem:** Text/regex operate on a bounded loaded window; users cannot query the complete bucket by size/date/storage class/tags/metadata.
   - **Change:** Add a structured query model and cancellable search jobs. Distinguish native provider predicates, paged scans and indexed inventory searches. Add Azure tag-query support where available; never describe ordinary S3 listing as arbitrary server-side metadata search.
   - **Contract/scope:** Typed `searchObjects`, cursor, execution mode, completeness and scan-cost counters; all enumeration implementations, with provider capability gates.
   - **Risks:** HEAD/tag request amplification, stale indexes and scan costs; preserve current memory and regex execution bounds.
   - **Competition — from memory, unverified:** Azure Storage Explorer supports blob-oriented filtering; AWS Console and S3 Browser expose listing/filter workflows with differing scopes.

4. **Add bulk tags, metadata, headers and carefully gated ACL editing** — **high · L · confirmed**

   - **Where:** A; controller `apps/flutter_app/lib/controllers/app_controller.dart:4653`; single-object editor `apps/flutter_app/lib/browser/storage_admin_dialog.dart:136`; handlers `engines/python/src/main.py:5550`, `engines/python/src/main.py:5591`; mobile `apps/flutter_app/lib/services/mobile_storage_admin.dart:548`.
   - **Now/problem:** Property editors target one object, forcing repetitive work across a selection.
   - **Change:** Add a reviewed patch operation with merge/remove/replace semantics, per-object preconditions and partial results. Add bulk actions beside existing selection controls.
   - **Contract/scope:** `planBulkProperties`/`applyBulkProperties`; Python reference and mobile first. Go/Rust/Java need work only if native parity is chosen.
   - **Risks:** S3 copy-to-self may create versions; preserve ACL/Object Lock/headers, reject unreadable protection state and respect ownership/public-access restrictions.
   - **Competition — from memory, unverified:** S3 Browser, MSP360 Explorer and provider consoles expose varying bulk property operations.

5. **Implement bandwidth limits and scheduled queue execution** — **high · L · confirmed**

   - **Where:** T; profile rejection `engines/go/src/main.go:333`; controller `apps/flutter_app/lib/controllers/app_controller.dart:1690`; Jobs UI `apps/flutter_app/lib/tasks/tasks_workspace.dart:31`.
   - **Now/problem:** Worker concurrency controls do not provide a shared bytes-per-second budget or time-window scheduling.
   - **Change:** Add shared upload/download token buckets, effective-limit display and queue `notBefore`/allowed-window settings. Scheduler dispatches durable jobs rather than sleeping inside engine requests.
   - **Contract/scope:** Optional byte-rate limits and scheduled-job metadata; all transfer engines and mobile transports. Desktop scheduling first.
   - **Risks:** Intentional throttling must not trigger no-progress timeouts; clock/time-zone changes and app suspension require explicit semantics. Do not parallelize selected files.
   - **Competition — from memory, unverified:** rclone has bandwidth scheduling; WinSCP and several desktop clients expose speed limits or scheduled execution.

6. **Add favourites, recent locations and saved searches** — **medium · S · confirmed**

   - **Where:** Controller `apps/flutter_app/lib/controllers/app_controller.dart:1274`; persistence `apps/flutter_app/lib/services/app_state_repository.dart:132`; UI `apps/flutter_app/lib/browser/browser_workspace.dart:2471`.
   - **Now/problem:** Navigation operates on the current bucket/prefix; repeated visits require rediscovery.
   - **Change:** Persist profile-ID/bucket/prefix references and query settings; add pin/recent controls and broken-reference handling.
   - **Contract/scope:** No engine contract additions; Flutter on all platforms.
   - **Risks:** Store no credentials or signed URLs; deleting a profile must invalidate its references without selecting another endpoint silently.
   - **Competition — from memory, unverified:** Cyberduck bookmarks and Transmit/ForkLift favourites are familiar navigation patterns.

7. **Add bucket analytics backed by paged inventory** — **medium · L · confirmed**

   - **Where:** L; list model `apps/flutter_app/lib/models/domain_models.dart:560`; controller `apps/flutter_app/lib/controllers/app_controller.dart:1050`; bucket UI `apps/flutter_app/lib/browser/browser_workspace.dart:2494`.
   - **Now/problem:** Object size/class/date exist per row, but there is no inspected aggregate workflow for understanding bucket growth or expensive prefixes.
   - **Change:** Add resumable aggregation by prefix, storage class and age; show totals, coverage timestamp and a treemap. Separate current-object and version-storage estimates.
   - **Contract/scope:** Optional inventory/aggregation job and coverage schema; reuse all engines’ pagination, Python reference first for orchestration.
   - **Risks:** Partial scans must never appear complete; use disk-backed aggregation rather than retaining all objects.
   - **Competition — from memory, unverified:** AWS Console/Storage Lens and MinIO Console offer storage summaries; rclone provides size reporting.

8. **Expose checksum verification as an ordinary object/transfer action** — **medium · L · confirmed**

   - **Where:** T/A; benchmark checksum UI `apps/flutter_app/lib/benchmark/benchmark_workspace.dart:22`; SDK checksum configuration `engines/python/src/main.py:398`; object model `apps/flutter_app/lib/models/domain_models.dart:560`.
   - **Now/problem:** Checksums exist in benchmark/SDK paths, but users lack an explicit ordinary-object verification report.
   - **Change:** Add Verify selected/downloaded objects, showing algorithm, source, full/composite semantics, bytes checked and unavailable/mismatch states.
   - **Contract/scope:** Typed checksum descriptors and verification results; all desktop engines plus mobile.
   - **Risks:** ETags are not universally content hashes. Bound hashing memory, pin object versions/validators and disclose when verification requires downloading data.
   - **Competition — from memory, unverified:** rclone and WinSCP expose comparison/verification features; cloud-client support depends on provider checksum semantics.

9. **Complete identity onboarding rather than reimplementing existing AWS chains** — **medium · L · confirmed**

   - **Where:** `apps/flutter_app/lib/widgets/connection_options_editor.dart:43`; import controller `apps/flutter_app/lib/controllers/app_controller.dart:2984`; JSON importer `apps/flutter_app/lib/services/app_state_repository.dart:161`; mobile gates `apps/flutter_app/lib/services/storage_http_client.dart:446`.
   - **Now/problem:** Named/default AWS credentials and AssumeRole already exist, but named-profile guidance requires prior SSO login. Import accepts app JSON; mobile rejects desktop identity modes.
   - **Change:** Add discovered AWS-profile selection, reviewed AWS/rclone configuration import and explicit sign-in/expiry/MFA workflows. Treat mobile Entra as its own authenticated token-provider slice.
   - **Contract/scope:** Credential-provider status/challenge descriptors; desktop SDK adapters and native mobile identity integration.
   - **Risks:** Never execute imported commands automatically. Persist secrets/tokens only through `ProfileSecretStore`; retain metadata-only exports and explicit recovery boundaries.
   - **Competition — from memory, unverified:** Azure Storage Explorer integrates Entra sign-in; Cyberduck and rclone support several credential-provider workflows.

10. **Add browser tabs before independent native windows** — **medium · L · confirmed**

   - **Where:** Shared controller `apps/flutter_app/lib/controllers/app_controller.dart:197`; shell `apps/flutter_app/lib/app/s3_browser_app.dart:219`; workspace enum `apps/flutter_app/lib/models/domain_models.dart:23`.
   - **Now/problem:** Workspace tabs are application sections; browsing state remains a single controller context.
   - **Change:** Extract per-browser-session profile/bucket/prefix/selection state while sharing Jobs, credential access and engine admission. Add two browsing tabs; then evaluate separate windows.
   - **Contract/scope:** No initial engine additions; Flutter desktop first, tablet later.
   - **Risks:** Cross-tab stale responses, credentials/profile changes and concurrent mutations need ownership isolation. Respect global process and request bounds.
   - **Competition — from memory, unverified:** Transmit and ForkLift use tabs/panes; Cyberduck supports separate browser windows.

11. **Add conditional edit-in-place for small text objects** — **medium · M · confirmed**

   - **Where:** A/T; preview controller `apps/flutter_app/lib/controllers/app_controller.dart:3888`; source UI `apps/flutter_app/lib/browser/preview_source_view.dart:1`; property handler `engines/python/src/main.py:5591`.
   - **Now/problem:** Source is selectable but there is no inspected content-edit/save path.
   - **Change:** Add an explicit editor with Save as and conditional Save, retaining original version/ETag and required content properties.
   - **Contract/scope:** Bounded text-write operation with validator and structured conflict result; Python/mobile first or all T implementations for native parity.
   - **Risks:** Never save a truncated preview as the whole object. Preserve protection/metadata, detect encoding changes and keep unknown PUT outcomes unresolved.
   - **Competition — from memory, unverified:** Cyberduck, Transmit and WinSCP support remote editing through editors or temporary local files.

12. **Add structured data previews** — **medium · M · confirmed**

   - **Where:** `apps/flutter_app/lib/controllers/app_controller.dart:3836`; preview UI `apps/flutter_app/lib/browser/browser_workspace.dart:1562`; preview enum `apps/flutter_app/lib/models/domain_models.dart:100`.
   - **Now/problem:** CSV/JSON are source views; there is no table-oriented exploration or inspected Parquet reader.
   - **Change:** Add bounded CSV/JSON table views and static Markdown rendering; follow with range-based Parquet schema/row-group sampling.
   - **Contract/scope:** None for bounded text views; typed range-read/sampling support for Parquet through A or a dedicated read method. Flutter all platforms.
   - **Risks:** Explicit row/column/byte budgets, malformed inputs and clear partial-data notices. Markdown must not execute HTML/scripts or automatically open links.
   - **Competition — from memory, unverified:** Azure Storage Explorer and provider consoles offer selected structured-data inspection workflows.

13. **Turn video URLs into previews; add PDF/audio/archive inspection incrementally** — **medium · L · confirmed**

   - **Where:** P; controller `apps/flutter_app/lib/controllers/app_controller.dart:3842`; UI `apps/flutter_app/lib/browser/browser_workspace.dart:1568`; expanded eligibility `apps/flutter_app/lib/browser/browser_workspace.dart:1472`.
   - **Now/problem:** Video classification produces selectable URL text; expanded previews accept text/images.
   - **Change:** Add range-aware audio/video playback, bounded PDF pages and archive directory listings with explicit extraction.
   - **Contract/scope:** Existing links may support initial playback; authenticated range/session reads need explicit capability negotiation. Flutter/native plugins across platforms.
   - **Risks:** Decoder memory, archive bombs/path traversal, expired links and unintended resource requests. Retain preview identity, byte limits and static HTML rules.
   - **Competition — from memory, unverified:** Transmit/ForkLift use OS preview facilities; provider-console preview coverage varies.

14. **Export structured audit records and optionally retain them across sessions** — **medium · M · confirmed**

   - **Where:** `apps/flutter_app/lib/controllers/app_controller.dart:2915`; structured capture `apps/flutter_app/lib/controllers/app_controller.dart:4318`; UI `apps/flutter_app/lib/event_log/event_log_workspace.dart:17`.
   - **Now/problem:** Plain-text export omits captured request relationships, engine/method/status/latency and trace structure; bounded in-memory history is not a durable audit trail.
   - **Change:** Add redacted JSONL/CSV export, filtered export and optional rotating local retention with explicit completeness limits.
   - **Contract/scope:** No initial engine changes; preserve existing event fields. Flutter all platforms.
   - **Risks:** Retention/storage limits and token redaction. Do not market local logs as authoritative provider audit records.
   - **Competition — from memory, unverified:** WinSCP supports session logging; rclone supports machine-readable logging.

15. **Provide constrained CLI and scripting hooks** — **medium · L · confirmed**

   - **Where:** Existing protocol `contracts/engine_contract.json:16`; controller tools `apps/flutter_app/lib/controllers/app_controller.dart:2163`; advanced dispatch `engines/python/src/main.py:5423`; Jobs UI `apps/flutter_app/lib/tasks/tasks_workspace.dart:15`.
   - **Now/problem:** Engines are programmable internally, but inspected application workflows provide no supported headless profile/job interface.
   - **Change:** Add a desktop CLI for list/copy/verify/run-plan/status with JSON output and meaningful exit codes, reusing queue/planner services.
   - **Contract/scope:** Typed job IDs/status and idempotency/reconciliation semantics; desktop host plus supported engines.
   - **Risks:** Avoid secrets in arguments, exports or logs; secure-store access must fail explicitly when unavailable. No arbitrary script execution inside object previews.
   - **Competition — from memory, unverified:** rclone and WinSCP have mature command-line automation; Cyberduck has duck CLI.

16. **Add scoped upload sharing and QR presentation** — **medium · M · confirmed**

   - **Where:** P; bundle model `apps/flutter_app/lib/models/domain_models.dart:674`; share UI `apps/flutter_app/lib/browser/browser_workspace.dart:1820`; Python GET signer `engines/python/src/main.py:2855`.
   - **Now/problem:** Sharing is download-oriented; receiving files requires another workflow.
   - **Change:** Add provider-gated signed PUT or S3 POST policy generation with key/prefix, expiry, size/type conditions where enforceable; add QR rendering for existing GET links first.
   - **Contract/scope:** Typed share request/result including HTTP method/form fields and enforced conditions; all signing implementations for parity.
   - **Risks:** Signed URLs are bearer capabilities; redact them, explain overwrite scope and avoid promising universal revocation or POST parity across providers.
   - **Competition — from memory, unverified:** S3 Browser and cloud consoles expose signed-link workflows; upload-link support varies.

17. **Make archive restores and protection operations trackable in Jobs** — **medium · M · confirmed**

   - **Where:** A; handler `engines/python/src/main.py:5554`; restore handler `engines/python/src/main.py:5567`; UI `apps/flutter_app/lib/browser/storage_admin_dialog.dart:525`.
   - **Now/problem:** Restore/protection actions already exist, but archive restore returns request acceptance rather than a long-lived readiness workflow.
   - **Change:** Add bulk restore plans, periodic readiness inspection and download-when-ready. Surface retention/legal-hold state in selection summaries and explain blocked operations.
   - **Contract/scope:** Restore observation/job descriptors; Python reference and mobile provider adapters. Other engines only for native parity.
   - **Risks:** Retrieval costs, expiry and permissions; never enable governance bypass implicitly or equate accepted restore with available content.
   - **Competition — from memory, unverified:** AWS Console and S3 Browser expose archive restore management.

18. **Add tray/menu-bar status, notifications and deliberate OS handoffs** — **medium · L · likely**

   - **Where:** Lifecycle `apps/flutter_app/lib/app/s3_browser_app.dart:73`; transfer entry `apps/flutter_app/lib/controllers/app_controller.dart:1590`; drag-in UI `apps/flutter_app/lib/browser/browser_workspace.dart:535`.
   - **Now/problem:** Transfers are primarily app-window workflows; drag-in exists, but comparable drag-out/provider handoffs were not found in inspected surfaces.
   - **Change:** Start with completion notifications and tray status; add staged drag-out/Quick Look and Finder/Explorer share handoffs. Treat an iOS Files provider as a separate strategic project.
   - **Contract/scope:** Usually no storage additions initially; native desktop/mobile integration and durable queue dependencies.
   - **Risks:** Native permissions, local staging lifetime and signed Apple identity/entitlements. iOS Files-provider completeness is **unverified** without a full native integration audit.
   - **Competition — from memory, unverified:** Mountain Duck provides mounted access; Transmit/ForkLift integrate closely with macOS.

19. **Extend administration to replication, notifications, inventory and access points** — **low · L · confirmed**

   - **Where:** A; existing reads `engines/python/src/main.py:5491`; mobile reads `apps/flutter_app/lib/services/mobile_storage_admin.dart:240`; configuration-copy exclusions `engines/python/src/advanced_workflows.py:517`.
   - **Now/problem:** Replication/notification inspection exists; inspected dispatch lacks corresponding management workflows and inventory/access-point administration.
   - **Change:** Add independent capability-gated read/plan/apply surfaces, beginning with notification and replication diffs. Keep inventory consumption separate from inventory configuration.
   - **Contract/scope:** Typed action schemas and per-section statuses; Python reference first, mobile/native parity explicitly scoped.
   - **Risks:** IAM roles, destination ownership and unintended data movement. Do not silently copy these settings with bucket content.
   - **Competition — from memory, unverified:** AWS Console provides these service-specific management workflows; MinIO Console covers a subset of comparable administration.

20. **Add a conservative duplicate finder** — **low · L · confirmed**

   - **Where:** L; object identity fields `apps/flutter_app/lib/models/domain_models.dart:560`; query pipeline `apps/flutter_app/lib/controllers/object_query.dart:22`; browser selection UI `apps/flutter_app/lib/browser/object_panel.dart:201`.
   - **Now/problem:** There is no inspected duplicate-analysis action; names/sizes/ETags alone cannot safely establish byte identity.
   - **Change:** Use inventory to group candidates by size, then compare trustworthy checksums or explicitly hash content. Export groups before offering reviewed deletion.
   - **Contract/scope:** Inventory and verification result reuse; all engines through L/T, with optional A orchestration.
   - **Risks:** Download/request costs and false equivalence; versions and retention must remain explicit. No automatic deletion.
   - **Competition — from memory, unverified:** rclone provides deduplication tools for applicable backends; general file managers offer duplicate-oriented workflows.

21. **Upgrade multipart cleanup from individual aborts to reviewed cleanup plans** — **low · M · confirmed**

   - **Where:** A; UI `apps/flutter_app/lib/browser/storage_admin_dialog.dart:790`, `apps/flutter_app/lib/browser/storage_admin_dialog.dart:872`; handlers `engines/python/src/main.py:5541`, `engines/python/src/main.py:5580`.
   - **Now/problem:** Listing, part inspection and individual confirmed abort already exist; large orphan populations require repetitive action.
   - **Change:** Add age/prefix filters, part-byte estimates, exclusions for known recovery records and a reviewed batch abort report. Reuse the existing lifecycle cleanup preset for recurring server-side cleanup.
   - **Contract/scope:** Optional batch-plan action; Python reference/mobile first, no compulsory native engine work.
   - **Risks:** Aborting another client’s active upload; stale plans and partial failures require fresh checks and explicit results.
   - **Competition — from memory, unverified:** S3 Browser, MSP360 Explorer and provider consoles expose multipart administration.

22. **Localise the app and extend accessibility validation** — **medium · L · confirmed**

   - **Where:** Shell `apps/flutter_app/lib/app/s3_browser_app.dart:203`; shortcuts `apps/flutter_app/lib/app/app_shortcuts.dart:27`; touch policy `apps/flutter_app/lib/widgets/touch_targets.dart:5`; literal UI strings `apps/flutter_app/lib/tasks/tasks_workspace.dart:64`.
   - **Now/problem:** Inspected UI uses English literals without configured localisation delegates. Accessibility foundations already include system text scaling, reduced motion, shortcuts and touch targets.
   - **Change:** Extract messages into localisation resources; add plural/date/number handling and RTL coverage. Extend keyboard/screen-reader validation to object selection, live progress and modal actions.
   - **Contract/scope:** No initial engine additions; retain machine error codes and localise their presentation. All Flutter platforms.
   - **Risks:** Long translations, RTL technical fields and excessive live announcements. Specific screen-reader failures are **unverified**; this is a coverage proposal.
   - **Competition — from memory, unverified:** WinSCP and several established clients offer multiple languages and extensive keyboard workflows.

## Parity gaps

| Confirmed gap | Specific source evidence | Practical consequence |
|---|---|---|
| **Advanced desktop actions always depend on Python** | `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:62`; Python `engines/python/src/main.py:5423`; Go unsupported default `engines/go/src/main.go:309`; Rust default `engines/rust/src/main.rs:325` | Selecting Go/Rust/Java does not make advanced administration native to that engine. This is an intentional architecture boundary, not missing end-user functionality while Python is available. |
| **Go/Rust live transfer controls unsupported** | `engines/go/src/main.go:287`; `engines/rust/src/main.rs:311`; Java control handlers `engines/java/src/main/java/com/example/s3browser/Main.java:330` | Active-file pause/resume/cancel differs by engine. Preserve capability gates; durable restart recovery is a separate promise. |
| **Durable file recovery is separate and reference-backed** | `apps/flutter_app/lib/browser/storage_admin_dialog.dart:690`; `engines/python/src/main.py:5181`; `engines/python/src/advanced_workflows.py:33`; ordinary dispatch `apps/flutter_app/lib/controllers/app_controller.dart:1610` | Existing recovery must not be advertised as restart persistence for ordinary jobs across all engines. |
| **Azure ordinary data support excludes Rust/Java** | `engines/rust/src/main.rs:2550`; `engines/java/src/main/java/com/example/s3browser/Main.java:1945` | Azure users must use Python/Go on desktop; advanced reference actions do not erase selected-engine data-path restrictions. |
| **Mobile identity excludes desktop chains and Entra** | `apps/flutter_app/lib/services/storage_http_client.dart:446`; `apps/flutter_app/lib/services/storage_http_client.dart:486`; desktop UI modes `apps/flutter_app/lib/widgets/connection_options_editor.dart:43` | Mobile needs distinct credential-provider integration rather than merely exposing desktop authentication choices. |
| **Mobile advanced recovery/history/config-copy actions absent** | Mobile action inventory `apps/flutter_app/lib/services/mobile_storage_admin.dart:145`, fallback `apps/flutter_app/lib/services/mobile_storage_admin.dart:568`; desktop workflows `engines/python/src/advanced_workflows.py:26` | Current-content copy and ordinary operations do not imply mobile history-copy/configuration-plan/durable-recovery parity. |
| **Rust custom-CA/disabled-verification options explicitly unsupported** | `engines/rust/src/main.rs:2566` | Private-endpoint users need a supported engine; do not imply universal transport-option parity. |
| **Go rejects request-rate limits** | `engines/go/src/main.go:333` | A profile request-rate field is not an implemented cross-engine bandwidth control. |
| **Video “preview” is a URL display** | `apps/flutter_app/lib/controllers/app_controller.dart:3842`; `apps/flutter_app/lib/browser/browser_workspace.dart:1568`; expanded gate `apps/flutter_app/lib/browser/browser_workspace.dart:1472` | Classification/link generation exists; playback and expanded media preview do not. |
| **Mobile benchmark runtime exists but workspace is hidden** | `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:46`; `apps/flutter_app/lib/app/s3_browser_app.dart:62`; `apps/flutter_app/lib/app/app_shortcuts.dart:21` | Enabling the workspace is qualification work, not implementing benchmarks from scratch. |
| **iOS foreground/background boundary remains explicit** | `apps/flutter_app/lib/app/s3_browser_app.dart:73`; `docs/IOS_PLAN.md:58` | Durable background continuation requires native lifecycle work beyond desktop queue persistence. |
| **Advanced contract remains loosely typed** | `contracts/engine_contract.json:64`; action string `contracts/engine_contract.json:76` | Before adding more workflows, define action-specific request/result/error schemas and capability negotiation; method enumeration alone cannot establish parity. |

## Sequencing

| Phase | Suggested work | Dependencies and boundaries |
|---|---|---|
| **Quick wins — individual slices ≤1 week** | Favourites/recent locations; QR presentation of existing GET links; structured event export; clearer recovery entry points from Jobs; visible effective engine limitations. | Reuse existing APIs. Keep each slice narrow; these estimates exclude broad platform release qualification. |
| **Medium increments** | Bulk tags first, then metadata/headers; CSV/JSON table preview and static Markdown; archive-readiness tracking; reviewed multipart cleanup; AWS-profile discovery/import; localisation foundation. | Add typed A-action schemas and shared per-item outcomes. Metadata editing must retain the 2.3.5 protection-preservation boundary. |
| **Strategic foundation** | Durable queue plus recovery integration, then byte-rate controls and desktop scheduling. | Credential-free journal, stable job identities, explicit reconciliation, source/destination validation and engine capability declarations come first. |
| **Strategic workflows** | One-way sync with dry-run, then explicit mirror deletions; bucket inventory supporting search, analytics and duplicate candidates. | Sync depends on queue/recovery and conditional operations. Search/analytics/dedup share inventory coverage and verification semantics. |
| **Later architectural bets** | Two-way sync, multi-window browsing, native background transfers, iOS Files provider and broad automation. | Two-way sync needs durable baselines/conflicts; multi-window needs isolated browser sessions; mobile background work needs native implementation and physical-device qualification. |

For any implementation touching Flutter, run `flutter analyze` and the full Flutter suite; multipart sizing changes require boundary tests. macOS packaging changes require release build/signature/effective-entitlement checks. iOS changes require simulator compilation and physical-device Keychain/local-network verification before release.

## Already present, no action

- **Cross-profile/bucket copy:** current contents, checkpoints, S3 history replay and reviewed configuration copy already exist; improve integration rather than proposing them anew. `apps/flutter_app/lib/controllers/app_controller.dart:4742`; `engines/python/src/advanced_workflows.py:306`.
- **Object Lock, retention, legal holds, storage-class properties and archive restore:** existing advanced actions. `engines/python/src/main.py:5554`; `engines/python/src/main.py:5567`; `engines/python/src/main.py:5591`.
- **Multipart listing/inspection/abort:** already implemented; only bulk planning is proposed. `engines/python/src/main.py:5541`; `engines/python/src/main.py:5580`.
- **AWS named/default credentials and STS AssumeRole:** already wired; remaining opportunity is onboarding/challenges/mobile support. `apps/flutter_app/lib/widgets/connection_options_editor.dart:43`; `engines/java/src/main/java/com/example/s3browser/Main.java:2077`.
- **Secure persistence and metadata-only exports:** preserve the consolidated bundle and secure-write boundary. `apps/flutter_app/lib/services/app_state_repository.dart:53`; `apps/flutter_app/lib/services/app_state_repository.dart:114`.
- **Multipart sequencing and bounds:** preserve sequential selected-file dispatch and independent sizing. `apps/flutter_app/lib/controllers/upload_batch.dart:128`; `apps/flutter_app/lib/services/multipart_sizing.dart:5`.
- **Continuous benchmark execution:** current worker execution supersedes the older polling-driven finding. `engines/python/src/main.py:4918`.
- **2.3.5 resource/reliability fixes:** consulted the implementation ledger and current affected source; did not re-report bounded query workers, progress handling, safe publication or protection-preserving property rewrites as missing features. `docs/resource-review-2026-11-04/implementation.md:17`; `CHANGELOG.md:5`.

## Not covered

- Competitor comparisons are **from memory, unverified**; no network research was performed.
- S3 Select/content search was considered but is **unverified** as a suitable provider-supported feature. No handler appeared in the inspected contract/dispatch surfaces; validate provider availability before ranking it above structured search.
- New storage providers belong to the separate provider review.
- Server-side/client-side encryption belongs to the separate encryption design effort.
- No live-cloud, physical-device, interactive accessibility, native extension or throughput qualification was performed. Historical verification results in `docs/2.3.5-verification.md:7` were read, not rerun.
- No files changed or artifacts created; cleanup freed **0 B**. Existing untracked `docs/motion-review/` and `docs/resource-review-2026-11-04/` were preserved.