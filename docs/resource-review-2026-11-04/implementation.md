# Implemented fixes and verification

The recommended reliability and resource fixes are implemented, with a new Performance settings section. Existing workspace changes, visual styling, animations, fonts, engines and provider functions have been retained. This work does not claim measured network-throughput or battery improvements; executable tests establish behavior, and the local macOS artifacts establish a smaller installed footprint.

## Performance settings

| Control | Default | Allowed values | Effect |
| --- | --- | --- | --- |
| Progress update interval | 100 ms | 50–2,000 ms | Coalesces UI updates and supported desktop transfer events. Terminal states remain immediate. |
| Objects per listing window | 100,000 | 1,000–100,000 | Releases large object windows sooner; continuation retains access to the rest of the listing. |
| Idle engine lifetime | 120 seconds | 0–3,600 seconds | Desktop only. Zero keeps engines warm; expiry never evicts active jobs or pinned benchmarks. |
| Server copy observation timeout | 300 seconds | 5–3,600 seconds | Desktop only. Tracks the existing copy operation longer without replaying an uncertain mutation. |
| Image preview detail | 32 megapixels | 4–64 megapixels | Bounds expanded decode detail and memory; inline images decode near display size. |

Settings round-trip through metadata, migrate with defaults for older state, and retain the existing secure-persistence boundary. Existing transfer part-size and connection limits remain in their established sections. Desktop-only options are hidden on mobile.

## Reliability changes

- Azure moves pin the copied source and condition deletion on its identity.
- Credential bundles require the supported schema and valid records. Failed hydration continues to block ordinary persistence until explicit recovery.
- Metadata model validation occurs inside last-good recovery. macOS location selection considers recoverable state without mistaking backup rotation timestamps for a newer valid primary.
- Go returns paired version cursors correctly. Shared object/version continuation guards reject missing, repeated and cyclic cursors while retaining loaded results.
- Selection changes immediately, late artifacts cannot replace a newer selection, context menus retain their target, and folder navigation resets batch selection.
- Permanent download-name errors terminate; only real collisions retry. Reservations and staging files are cleaned up on failure.
- Rust, Go and Python use native atomic no-replace publication where available, with conservative fallbacks. Java publication safety remains intact.
- Multipart lifetime guards clean up definite failures; ambiguous completion remains explicitly uncertain.
- Upload source identity, size and modification checks detect ordinary source mutation before publication.
- Response-body range retries retain validators, rewrite the same range and commit counters once.
- Transfer progress/liveness prevents healthy slow bodies from being mistaken for stalled work. Mobile body deadlines no longer simply bound total body duration.
- Text previews cancel superseded work, bound body/overall waits and reject failed or invalid range responses. Image loading bounds actual responses and decoded dimensions.
- Benchmark CSV offsets reconcile crash tails and reject missing committed data. Checksum failures are exported truthfully.
- Independent review regressions are covered: stale image display, history mapping cache invalidation after lost responses, and failed-request log-buffer release.

## Resource changes

- Rust/Java transfer dispatch and Python Azure dispatch bound pending work as well as active workers.
- Progress is coalesced; Python sends optional sequenced log deltas and history mapping deltas. Immutable prefix views retain complete accessible output without copying the whole prefix per update.
- History replay stores an immutable manifest plus a checksummed, fsynced append journal, preserving pre-mutation and confirmed-outcome durability.
- Downloads reuse per-batch destination indexes, conservatively invalidating them after observed external directory changes.
- Eligible same-authority server copies avoid relaying object bytes. Strict conflict policies and unsupported endpoint/provider combinations retain safe relay behavior.
- Mobile downloads stream manual-sized ranges; multipart threshold and chunk size are planned independently. Large S3 hashing uses a reusable worker with bounded blocks; Azure skips the unnecessary S3 digest.
- Mobile client leases prevent active eviction. Native clients are reused and released, Android work is tied to lifecycle, and bucket-version lookups are bounded/cached with invalidation.
- Desktop idle processes expire according to settings. IPC byte limits apply before line framing/JSON decoding; watchdog elapsed time is monotonic.
- Object query workers reuse datasets and derived sort keys and return indices. Version filtering is cached and regex execution is killable.
- Version rows build lazily; version append/deduplication avoids full-history copies. Selection snapshots, byte summaries and themes are cached.
- Task/transfer updates use indexed records and materialize ordered history snapshots when read.
- Source syntax spans are cached; collapsed log details defer formatting; log categories/counts and unchanged task-output joins are cached.
- Hidden inspectors mute tickers, opaque scroll masks bypass shader compositing without replacing scrollers, and animated indicators reuse static geometry.
- Benchmark summary derivation is cached and planning uses order-statistic key selection rather than a full active-key scan per worker.

## Packaging and verification automation

Python staging omits package caches, headers, development metadata, static archives and duplicate toolchain site-packages. Its dependencies are constrained to the resolved version set. Runtime smoke checks use the packaged interpreter, native extensions and certificate bundle with bytecode/user-site fallback disabled.

Java staging uses a linked runtime containing Java SE plus the distribution's crypto, security and naming providers. Go remains stripped; Rust release symbols are stripped. Unused Google Fonts/Cupertino dependencies were removed while retaining the bundled Inter/Sora fonts and licenses.

Staging qualifies each manifest executable. Release workflows additionally run contracts from final payloads. Mandatory CI now runs native suites, cross-platform filesystem contracts and an iOS simulator compile. Windows installer expectations derive from the application version. Workflow syntax and shell syntax checks pass.

## Verification results

| Check | Result |
| --- | --- |
| Flutter analysis | No issues |
| Full Flutter suite | 445 passed, eight skipped |
| Go race-enabled suite | Passed |
| Rust native suite | 23 passed |
| Java regression harness | Passed |
| Packaged Python contracts | 167 passed, 42 skipped |
| Packaged Go contracts | 166 passed, 43 skipped |
| Packaged Rust contracts | 194 passed, 15 skipped |
| Packaged Java contracts | 195 passed, 14 skipped |
| Android Kotlin compilation | Passed |
| iOS generic simulator ARM64 compilation | Passed with local host workarounds below |
| macOS release-configuration development app and DMG | Built; deep signature verification and DMG checksum passed |
| Effective ad-hoc signed entitlements | No sandbox/Keychain-group entitlements, as required for legacy-Keychain development builds |
| Workflow actionlint, shell syntax and diff whitespace | Passed |

Contract skips include engine-specific internal suites and unsupported fixture capabilities; these results do not establish live-provider coverage.

## Local footprint

The existing macOS sample used 1,072,248 KiB of allocated installed space. The new development app uses 387,308 KiB, approximately 378 MiB, with all four engines. That is approximately 64% smaller than the sampled app. This compares local artifacts, not controlled runtime throughput measurements or guaranteed sizes on other platforms. The new DMG is approximately 155 MiB.

| Payload | Existing sample KiB | New development build KiB |
| --- | ---: | ---: |
| Python | 633,912 | 181,608 |
| Java | 361,128 | 143,320 |
| Go | 13,236 | 13,252 |
| Rust | 23,720 | 16,720 |

## Qualification limits and retained design choices

The installed Xcode host rejects multi-architecture `lipo` verification and the project's older deployment targets. Local macOS compilation used ARM64 with a temporary macOS 12 target. The project deployment policy was not raised; signed public releases reject this local override. iOS verification used an ARM64/15.0 command-line override and cached Smithy host-tool placement. Default simulator compilation remains affected by this host's CoreSimulator/Xcode mismatch. These builds do not qualify the original minimum OS versions.

Physical-device Keychain/local-network flows, real exFAT publication, Windows/Linux execution and live-provider performance still require qualification. The macOS artifact is ad-hoc development output, not an update-safe public release. No release or repository publication was performed.

The broader review also suggested deeper redesigns. Loaded version history is still retained so all loaded versions remain accessible; rows, filtering and appends are optimized, but bounded disk-backed older-page access needs asynchronous paging. Task output retains one selectable document to preserve Select All/copy behavior, with unchanged-output joins cached. History resume still fully validates source history before each batch; removing that validation without provider snapshot guarantees would weaken source-change detection. Checkpoint JSON encoding remains synchronous after cached summary derivation. Binary dependency hashes and cross-platform wheel manifests remain follow-up reproducibility work beyond the committed version constraints. These are explicitly retained constraints, not claimed completed optimizations.
