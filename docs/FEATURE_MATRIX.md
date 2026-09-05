# Backend Feature Matrix

This file is the required parity checklist for all backend engines. A feature is only considered complete when every supported engine on a platform implements the same request and response semantics.

## Storage Providers

Profiles carry an `endpointType` of `s3Compatible`, `awsS3`, or `azureBlob`.

| Provider | Auth | Python | Go | Rust | Java |
| --- | --- | --- | --- | --- | --- |
| S3-compatible (MinIO, Ceph, etc.) | Access/secret key (SigV4) | Supported | Supported | Supported | Supported |
| AWS S3 | Access/secret key (SigV4) | Supported | Supported | Supported | Supported |
| Azure Blob Storage | Account name + access key (Shared Key) | Supported | Supported | `unsupported_feature` error | `unsupported_feature` error |

Azure notes:

- The profile's access-key field holds the storage account name; the secret-key field holds the account access key. An empty endpoint URL resolves to `https://<account>.blob.core.windows.net`; set a custom URL for Azurite or sovereign clouds.
- Buckets map to containers and folder markers to zero-byte blobs with a trailing `/`.
- Versioning, lifecycle, policy, CORS, encryption, tagging, and presigned URLs are S3-only; engines return `unsupported_feature` and the UI hides those controls for Azure profiles.

Legend:

- `Required`: must be implemented for all engines on supported platforms
- `Capability-Gated`: UI may expose only when the target reports support
- `Desktop Only`: required on Windows, macOS, and Linux
- `Android` / `iOS`: required on the native mobile engines

## Core Browser Features

| Feature | Python | Go | Rust | Java | Android | iOS | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Health and engine descriptor | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Endpoint profile validation | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Capability detection | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Bucket listing | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Bucket create/delete | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Bucket versioning get/set | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Bucket lifecycle CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Native Kotlin | Native Swift | Implemented |
| Bucket policy CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Native Kotlin | Native Swift | Implemented |
| Bucket CORS CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Native Kotlin | Native Swift | Implemented |
| Bucket encryption read/write | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Native Kotlin | Unsupported | Capability-gated |
| Bucket tagging read/write | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Native Kotlin | Native Swift | Implemented |
| Object list pagination | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Flat and hierarchical listing | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Metadata, headers, and tags | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Version listing and delete markers | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Upload | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Download | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Delete single and batch | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Copy, move, rename | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Create folder marker | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Presigned URL generation | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Live pause/resume/cancel | Supported | Unsupported | Unsupported | Supported | Capability-gated | Capability-gated | Job capability-gated |
| Drag and drop ingest | Desktop Only | Desktop Only | Desktop Only | Desktop Only | N/A | N/A | App shell ready |

Transfer notes:

- Python and Java accept concurrent controls on the original job process. Go and Rust use sequential request loops and return `unsupported_feature` for interactive controls; their job payloads must not advertise pause/resume/cancel. No engine promises resume across process restarts.
- Host admission is bounded (four global / two per engine processes, 64 queued requests). Ordinary requests have a two-minute deadline; transfers use a no-progress deadline, suspended while explicitly paused. Control requests have a 15-second deadline. Timeout outcomes can be unknown and must not be automatically retried as successful mutations.

- The Flutter shell sizes each file independently. Multi-file selections use one parent UI job with aggregate bytes/status, sequential single-file engine requests, and nested per-file event records. Part workers remain parallel and bounded inside the active file. Cancellation stops queued files; sequential engines may finish the active file first.
- Python, Go, Rust, and Java upload parts concurrently with bounded workers. Automatic sizing remains within S3's 5 MiB–5 GiB part range and 10 000-part maximum.
- Users can disable automatic sizing and supply the manual upload part size in Settings. The manual value also remains the download range size.

## Benchmark Features

| Feature | Python | Go | Rust | Java | Android | iOS | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Benchmark config validation | Required | Required | Required | Required | Native Kotlin | Deferred | Capability-gated |
| Mixed/write/read/delete workloads | Required | Required | Required | Required | Native Kotlin | Deferred | Capability-gated |
| Duration and operation count modes | Required | Required | Required | Required | Native Kotlin | Deferred | Capability-gated |
| Pause/resume/stop | Required | Required | Required | Required | Native Kotlin | Deferred | Capability-gated |
| CSV export | Required | Required | Required | Required | Native Kotlin | Deferred | Capability-gated |
| In-app charts input schema | Required | Required | Required | Required | Native Kotlin | Deferred | Capability-gated |

## Inspector Tools

| Feature | Python | Go | Rust | Java | Android | iOS | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Put test data (`runPutTestData`) | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Delete all (`runDeleteAll`) | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |

Both tools execute directly inside the selected engine (no external scripts): put-testdata creates the configured object count/size/versions with a bounded worker pool; delete-all pages object versions (falling back to plain listing when versioning is unsupported) and batch-deletes with configurable batch size, workers, and delay.

## Error and Reliability Requirements

Every engine must return typed error codes for:

- `auth_failed`
- `tls_error`
- `timeout`
- `throttled`
- `unsupported_feature`
- `invalid_config`
- `object_conflict`
- `partial_batch_failure`
- `engine_unavailable`
- `unknown`

Every engine must:

- Avoid unhandled process crashes for recoverable API failures
- Return structured partial-failure payloads for batch operations
- Provide progress events for long-running transfers and benchmark runs
- Respect cancellation requests from the UI shell
