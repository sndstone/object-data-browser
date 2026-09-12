# September improvement implementation

Implemented against the September plan for application `2.2.8+1` and desktop
engines `2.2.8`. Windows packages and publication are verified separately from
the local implementation checks below.

## Delivered work

| Plan item | Result |
| --- | --- |
| 1. Azure move safety | Python and Go require an explicit successful copy with the matching copy ID before deleting the source. Pending, failed, aborted, missing, and mismatched responses retain the source. Identical source/destination moves are rejected. |
| 2. Safe destinations | Desktop downloads use temporary files in the destination directory. Keep both is the default; replace publishes only a successfully validated file. Names are sanitized and case-insensitive collisions are handled at publication. Native downloads use staged files or pending MediaStore entries and keep both. Final paths appear in transfer output. |
| 3. Download integrity | Validate actual whole-object sizes, range lengths, and Content-Range before publication. HEAD ETags are sent as If-Match validators where available; they are not treated as checksums. Java uses long byte counts and bounded streaming for settings through 5 GiB. |
| 3a. Action-specific Cancel | Inline controls and action details route through the same task cancellation. Scoped cancellation stops queued requests and multi-step dispatch, ignores late results, and terminates only the desktop process assigned to that request. Native bridges cancel the corresponding request. Dispatched mutations with unconfirmed results are marked unknown; cancellation does not claim rollback. Transfer acknowledgements preserve counters and do not overwrite terminal states with late progress. |
| 4. Measured benchmarks | Removed production synthetic summaries and fabricated percentile/timeline fallbacks, including Android's estimated operation splits and claimed checksum successes. Removed unused Rust synthetic summary helpers. Missing measurements display Unavailable; measured zero remains zero. Demo results stay in the mock service. |
| 5. Independent profile actions | Test accepts a draft without saving or changing the browser selection. Use profile activates session state. Save reports secure persistence success separately. Changing the startup default does not activate a connection. Ordinary settings writes preserve previously saved profile values when the active draft is session-only. |
| 6. Effective settings | Benchmark worker/retry controls live under Benchmark. Connection pool/attempt controls apply to desktop S3 profiles, with the eight-worker cap explained. Native/Azure engine-managed limits are identified. Sequential file batches and automatic per-file sizing are preserved. |
| 7. Persistence feedback | Persistent session-only warnings survive unrelated success banners. Settings offer Retry saving; failed deletion is not described as durable. Explicit Save/import credential recovery boundaries remain intact. |
| 8. Settings workflow | Six groups, one connection editor, phone list-to-editor navigation, retained drafts, advanced transport disclosure, and actionable Azure/engine compatibility guidance. Navigation accounts for text scaling. |
| 9. Focused extractions | Separate action scopes, persistence state, transfer presentation, benchmark metrics, Settings group mapping, and desktop destination helpers. The existing controller and engine entry points remain stable. This is an incremental extraction, not a complete rewrite of the large files. |
| 10. Reproducibility | Flutter 3.44.6 is pinned for bootstrap and CI; mismatched caches fail with guidance. Regression cases run in the ordinary contract suite. CI includes Flutter on Linux/macOS/Windows and Python filesystem safety on macOS/Windows. Transport/capability documentation and version references are reconciled. |

## Verification

- Flutter analysis: no issues. Full Flutter suite: 187 passed, 2 skipped.
- Contract suite against real local sidecars and a loopback storage fixture:
  Python 40 passed; Go 39 passed/1 skipped; Rust 25 passed/15 skipped;
  Java 26 passed/14 skipped. Skips reflect unsupported provider/control features.
- Engine builds: Go, Rust, and Java compiled successfully. Java's 2, 4, and 5 GiB
  part settings were exercised using small downloaded objects, without allocating
  multi-gigabyte test buffers.
- Settings widget checks cover all six groups at widths 390, 700, 1000, 1360,
  and 1500, light/dark themes, and 130%/200% text scaling. Connection editor and
  keyboard focus checks accompany rendered screenshots inspected locally.
- macOS release app built locally; development artifact is ad-hoc signed without
  sandbox entitlements, with signature verification and entitlement inspection.
- iOS simulator target compiled with Xcode package-plugin validation bypassed
  for the locally resolved Swift build plugins. Android debug APK built.
- Workflow actionlint, bootstrap shell syntax, and whitespace checks passed.

## Explicit capability and release limits

- Go/Rust do not support interruption of an active transfer request. Batch Cancel
  stops remaining files and explains that the current file may finish. Python
  and Java expose cooperative transfer controls. Ordinary scoped action
  cancellation is independent of these transfer capabilities.
- Cancellation cannot undo a request already accepted by a storage provider.
  Unknown mutation outcomes require inspection before retry. Native SDK calls
  may finish their in-flight network work before observing cancellation; scoped
  checkpoints prevent subsequent dispatch and late UI changes.
- Mobile downloads currently keep both. Android rejects batches larger than
  its current 2 GiB bridge accounting limit with an explicit error.
- Desktop keep-both publication requires hard-link support in the destination
  filesystem. Unsupported filesystems fail safely without replacing existing
  data. Replacements use each platform's atomic move facility.
- Real-provider fault/transfer checks, Windows/Linux runtime filesystem checks,
  and physical-device iOS Keychain/local-network checks were not performed here.
  CI changes have been prepared locally, not run remotely. Layout and focus
  tests do not replace a VoiceOver/TalkBack session.
- The macOS artifact is for development only. Public macOS/iOS releases still
  require provisioned signing, the stable Keychain group, notarization where
  applicable, and the device checks required by AGENTS.md.

The original review findings and estimates remain in
[the plan](improvement-plan-2026-09.md) as historical context. Use the ordinary
contract tests for current regression verification rather than the historical
script that expected unsafe behavior.
