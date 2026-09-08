# Listing cancellation fix

Follow-up to the 2.2.6 backend/settings review. Included in application version 2.2.7. See the GitHub release for published
Windows/Linux packages; the macOS DMG is a local development build.

Cancel previously changed a paging generation and removed queued object-list
requests, but left the controller awaiting the current engine response. A
bucket timing out therefore stayed busy until its network/host deadline.

The controller now cancels its wait immediately, retains completed pages and
their continuation cursor, and ignores late responses or errors. Cancelling a
refresh before its first page returns preserves the current rows when the
prefix is unchanged. The task becomes cancelled and the object-panel button
returns to Refresh. Cancelled enumeration preserves the existing bucket list.
Version/detail reads within the listing workflow also participate, and no new
inspector/admin reads are started after cancellation.

The desktop service propagates a distinct cancellation outcome across manifest
lookup, request admission and response handling. It never substitutes mock data
or reports an intentional cancellation as an engine crash. The host terminates
processes handling cancellable read-only browser requests, cancels queued reads
and releases their admission permits. Transfer processes and their job ownership
remain intact, so uploads and their controls continue working.

Cancellation also wins when a response/error was queued immediately before the
button was pressed. Late errors remain observed and cannot fail a newer listing.

## Verification

- `flutter analyze --no-pub`: no issues found.
- `flutter test --no-pub`: **156 passed, 2 skipped**.
- New regressions cover hung bucket/object reads, retained partial pages and
  cursors, immediate retry, stale data/timeouts, queued-response races, version
  reads, real Cancel-button interaction, manifest-lookup cancellation, fallback
  suppression, process-slot recovery and an unaffected active upload.
- Local host fixtures exercise actual sidecar process termination on macOS.
  Shell-based host tests skip Windows; Windows process behavior was not run here.
- No real storage endpoint or credentials were used. The engine wire contract is unchanged. Release packaging is tracked separately
  from these regression checks.

Native mobile adapters benefit from immediate UI cancellation and stale-result
suppression; their underlying SDK calls are not forcibly aborted by this change
and may continue until their native timeout. The desktop path actively stops the
listing process.
