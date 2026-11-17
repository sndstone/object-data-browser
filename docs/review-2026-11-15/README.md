# Object Data Browser review, 15 November 2026

Six GPT-6.1 Sol reviewers examined the 2.3.5 working tree (branch `ui-review-improvements`) for UI and motion, performance and memory, new features and new providers. A Fable 5.2 agent scoped object encryption. This page ranks what came back; the linked reports hold the full findings with `path:line` anchors.

Everything here is a static, read-only source review. No code changed, and no builds, tests or live endpoints were run. Memory and throughput figures are derived from source, not measured. The coordinator re-read 15 of the highest-severity claims against current source and all 15 held; the rest are as the reviewers reported them.

| Report | Scope | Findings |
|---|---|---|
| [ui-motion.md](ui-motion.md) | Transitions against the `AppMotion` model, with a full animation inventory | 16 |
| [ui-general.md](ui-general.md) | State bugs, consistency, layout, keyboard and accessibility, copy | 19 |
| [performance-flutter.md](performance-flutter.md) | App-layer rebuilds, memory, I/O, startup | 13 |
| [performance-engines.md](performance-engines.md) | Python, Go, Rust and Java engines | 17 |
| [features.md](features.md) | Feature inventory, 22 proposals, parity gaps, sequencing | 22 |
| [providers.md](providers.md) | Provider abstraction, S3-compatible presets, native providers | 12 |
| [encryption-scope.md](encryption-scope.md) | Provider-side and client-side encryption design | phased plan |

## Fix first: defects that affect correctness or data

These are bugs in shipped behaviour, not improvements.

| # | Defect | Where | Report |
|---|---|---|---|
| 1 | A share link generated for object A is attached to object B if the selection changes before the request returns. | `controllers/app_controller.dart:2071` | UI general 1 |
| 2 | Upload destination is read after folder traversal and file sizing, so navigating during preparation sends files to a different prefix. | `browser/browser_workspace.dart:186`, `controllers/app_controller.dart:1590` | UI general 2 |
| 3 | With API logging on, the Python engine reads `http_response.content` on every response, which buffers and consumes streamed download bodies. | `engines/python/src/main.py:552` | Engines 1 |
| 4 | Go and Java apply whole-request deadlines to transfers. A healthy 128 MiB part slower than about 2 MiB/s is killed after roughly 65 seconds. | `engines/go/src/main.go:379`, `Main.java:2063` | Engines 5 |
| 5 | Go has no range-body retry, so a connection reset late in a large download discards every completed range. | `engines/go/src/main.go:1878`, `azure.go:1247` | Engines 6 |
| 6 | Java cancels transfer futures without waiting for workers to exit, so the terminal response can precede the end of network and file activity. | `BoundedTasks.java:39` | Engines 7 |
| 7 | Any settings change, including switching theme, overwrites the benchmark draft's threads, timeouts and output paths. | `controllers/app_controller.dart:2596` | UI general 3 |
| 8 | Cancelling the profile export dialog on desktop still writes `s3-browser-profiles.json` to the download folder. | `settings/settings_workspace.dart:170` | UI general 4 |
| 9 | Breadcrumbs rebuild prefixes with `join('/')`, so a prefix such as `a//b/c/` navigates to `a/b/`. | `browser/object_panel.dart:646` | UI general 6 |
| 10 | "Download current object" and "Delete current object" in the inspector act on the checked batch selection when one exists. | `browser/browser_workspace.dart:1664` | UI general 10 |

## UI and motion

The workspace, settings, inspector, HTML preview and banner already use the motion model. What remains is mostly framework-owned animation that never sees the app's zero-duration preference.

- **Dialogs and sheets.** All 32 `showDialog` calls and both bottom sheets use SDK timings and ignore the preference. A `showAppDialog` and `showAppBottomSheet` pair in `AppMotion` fixes them in one place.
- **Disclosure, dropdowns, tabs, phone navigation.** `ExpansionTile` (20 sites), `DropdownButtonFormField` (9 sites), the benchmark `TabBar`/`TabBarView` and the 500 ms `NavigationBar` all run on SDK defaults.
- **Turning motion off mid-animation.** `AnimatedSwitcher` and implicit animations keep running when the duration changes to zero. Only `DirectionalSwitcher` settles correctly.
- **Abrupt changes.** List to empty state, benchmark chart categories, and several responsive breakpoints (preview details, Tasks split pane, inspector docking) swap with no transition.
- **Interruption bugs.** The trace-tile indicator jumps to a full tile when a result is interrupted, and an in-flight navigation keeps its old axis when the window crosses the rail breakpoint.
- **Tokens.** App-authored motion uses 28 distinct durations. The report maps them onto seven named tokens (`fast` 120, `control` 180, `surface` 220, `layout` 240, `navigation` 300, `progress` 320, `activityMorph` 440 ms).

Outside motion, the general review found raw Material dropdowns and switches in administration dialogs where `AppSelectField` and `AppSwitchTile` exist, row action menus that disappear once an object is selected, Azure objects offered "Copy s3:// URI", benchmark fields that silently substitute invalid input, and no running or failed badge on the Jobs destination.

## Performance and memory

The 2.3.5 fixes are intact. The remaining costs are in logging, modal routes and the engines' less-travelled paths.

**App layer**

- API trace bodies are kept whole. The 5,000-event cap bounds the count, not the bytes, so repeated listing responses retain thousands of full page trees.
- The inspector's Events tab puts a `shrinkWrap` log list inside another list, which lays out every row instead of the visible ones.
- Each engine log line copies the event list twice and notifies immediately, bypassing progress coalescing.
- The inspector dialog, benchmark results dialog and connection sheet listen to the whole controller, so every transfer tick rebuilds them.
- Jobs scans retained history several times per progress update.
- Sidecar frames up to 128 MiB are decoded on the UI isolate.
- Mobile streamed uploads reopen and stat the source file for every 256 KiB block, about 8,000 opens per GiB.
- Credential hydration runs before `runApp`, so a Keychain prompt appears before any window.

**Engines**

- Python recoverable downloads still read each range into memory: about 1 GiB at eight workers and 128 MiB ranges.
- Python, Java and Rust accept requests without a bounded admission queue or a frame-size limit. Go has both.
- Completed Python benchmarks keep their payload cache, up to 1,024 MiB per run, until the process exits.
- Python Azure caps workers at `256 MiB / partSize`, a leftover from whole-part buffering, so 128 MiB parts run two workers instead of eight.
- Benchmark latency is timed over different boundaries in each engine, so cross-engine comparisons measure different things.
- Exact-key version listing pages through every key sharing the prefix: inspecting `a` can take about 1,000 requests.

## Features

The reviewer found that much of the older backlog already exists (cross-profile bucket copy, Object Lock, archive restore, multipart inspection, AssumeRole). The proposals that add the most are:

1. A transfer queue that survives restart, across all engines (XL).
2. One-way folder sync with a dry-run plan, before any two-way sync (XL, depends on 1).
3. Bucket-wide structured search by size, date, class and tags (L).
4. Bulk tag, metadata and header editing (L).
5. Bandwidth limits and scheduled execution (L, depends on 1).

Quick wins of a week or less each: favourites and recent locations, QR codes for existing share links, structured JSONL event export, and a running or failed badge on Jobs.

## Providers

- **Cheapest breadth:** a connection-preset catalog for S3-compatible services (R2, B2, Wasabi, Spaces, MinIO, Ceph first). These stay `s3Compatible` with a `providerPresetId`; no new protocol or secret fields. The reviewer had no network access, so every endpoint and capability fact in its table needs checking against current provider documentation before it ships.
- **Before any third protocol:** a small provider adapter interface, an authenticated range-read for previews (previews currently require a presigned URL), strict decoding of unknown provider types (they silently become S3 today), and typed credentials inside the existing Keychain item.
- **Then:** Azure completion and first-class ADLS Gen2, followed by native Google Cloud Storage in Python and Go.
- **Defer:** SFTP, WebDAV, SMB and personal-cloud drives need a file-identity model the contract does not have.

## Encryption

Full design in [encryption-scope.md](encryption-scope.md). The agent verified provider facts on the web and tagged what it could not confirm.

**Provider-side (S3 and Azure specification).** No engine sends encryption headers on ordinary uploads today, and the inspector does not show an object's encryption. The plan adds SSE-S3, SSE-KMS and DSSE-KMS on upload, copy and folder creation, then SSE-C and Azure scopes and customer-provided keys. AWS has blocked SSE-C by default on new buckets since April 2026, so SSE-C is an advanced opt-in.

**Client-side (our own workflow).** The recommendation is the age v1 file format, unmodified, with one X25519 key per vault. Keys, headers and the passphrase step stay in Dart; engines only run the chunk cipher. Any object stays recoverable with the stock `age` command-line tool, so users are never locked into this app. It rules out a custom container and filename encryption.

**Fix before either track**, because each becomes a security or data-loss bug once keys exist:

1. Log sanitisers do not redact `x-amz-server-side-encryption-customer-key` or `x-ms-encryption-key`.
2. Rust and Java drop `BlockedEncryptionTypes` when reading and saving bucket encryption.
3. The resumable-upload manifest writes request options to disk and puts the plaintext SHA-256 in object metadata.
4. The Keychain bundle decoder keeps only three fields, so an older build would delete stored keys on its next write.

## Decisions needed

| Decision | Recommendation |
|---|---|
| Client-side format | age v1 unmodified |
| Offer SSE-C at all | Yes, under Advanced, HTTPS only, with a mandatory key backup first |
| Where encryption keys live | The existing single Keychain item, in a top-level `keys` map; bundle version 3 only once keys exist |
| Store the passphrase-wrapped vault key in the bucket | Yes by default, with an enforced strong passphrase |
| Filename encryption | No |
| First provider work | S3-compatible preset catalog, then the adapter interface |
| First feature investment | Durable transfer queue, since sync and scheduling both depend on it |
