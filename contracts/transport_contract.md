# Transport Contract

## Desktop

- Request/response: line-delimited JSON on stdin/stdout
- Progress/events: line-delimited JSON on stdout with `event`
- Transfer progress events use `{"event":"transferProgress","job":{...}}` with the same transfer job shape returned by the final response
- Fatal diagnostics: stderr
- Process contract: exit code `0` on graceful shutdown, non-zero on engine failure

## Android

- Logical parity with desktop methods
- Native adapters translate platform-channel or FFI calls into the same method names and payload shapes

## Versioning

- Initial contract version: `1.0`
- Breaking request or response changes require a contract version bump

## Download publication and cancellation

`startDownload.params.conflictPolicy` is optional and defaults to `keepBoth`.
Desktop engines accept `keepBoth` and `replace`. `keepBoth` publishes a unique
portable basename without replacing existing files; `replace` publishes over the
matching destination only after the full download validates. Mobile UI always
uses `keepBoth`. Folder hierarchy is flattened on desktop; Android's Downloads
integration may preserve safe relative folders. Final destinations appear in job
output lines. Temporary `.odb-*.part` files are never successful output files.

Ranged responses must match the requested interval and object size, including
Content-Range. Received byte counts must match the HEAD size before publication.
Engines bind downloads to the HEAD ETag where available using If-Match; ETags are
validators, not assumed checksum hashes. Storage without hard-link support can
reject keep-both publication safely instead of overwriting existing data.

A `cancelTransfer` response with status `cancelling` acknowledges the request;
the original transfer's terminal response confirms worker cleanup. Python and
Java use this distinction. Go and Rust still do not advertise interactive
transfer controls. Cancellation of a multi-file parent stops queued files even
when its active engine cannot interrupt the current file.

The Flutter host owns per-action cancellation scopes. Read cancellation stops
only the owning request and discards late results. Desktop mutation cancellation
may terminate its exclusively owned sidecar; it then records `unknown` because
remote writes already accepted cannot be rolled back or presumed absent. Native
bridges use request IDs and cancellation tokens/tasks. Completed output remains
visible. An unknown mutation must not be automatically retried.
