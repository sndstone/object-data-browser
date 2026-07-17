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
- `Android`: required on Android engines

## Core Browser Features

| Feature | Python | Go | Rust | Java | Android | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Health and engine descriptor | Required | Required | Required | Required | Rust/Go | Stubbed |
| Endpoint profile validation | Required | Required | Required | Required | Rust/Go | Stubbed |
| Capability detection | Required | Required | Required | Required | Rust/Go | Stubbed |
| Bucket listing | Required | Required | Required | Required | Rust/Go | Stubbed |
| Bucket create/delete | Required | Required | Required | Required | Rust/Go | Planned |
| Bucket versioning get/set | Required | Required | Required | Required | Rust/Go | Planned |
| Bucket lifecycle CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Rust/Go | Planned |
| Bucket policy CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Rust/Go | Planned |
| Bucket CORS CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Rust/Go | Planned |
| Bucket encryption read/write | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Rust/Go | Planned |
| Bucket tagging read/write | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Rust/Go | Planned |
| Object list pagination | Required | Required | Required | Required | Rust/Go | Stubbed |
| Flat and hierarchical listing | Required | Required | Required | Required | Rust/Go | Planned |
| Metadata, headers, and tags | Required | Required | Required | Required | Rust/Go | Planned |
| Version listing and delete markers | Required | Required | Required | Required | Rust/Go | Planned |
| Upload | Required | Required | Required | Required | Rust/Go | Planned |
| Download | Required | Required | Required | Required | Rust/Go | Planned |
| Delete single and batch | Required | Required | Required | Required | Rust/Go | Planned |
| Copy, move, rename | Required | Required | Required | Required | Rust/Go | Planned |
| Create folder marker | Required | Required | Required | Required | Rust/Go | Planned |
| Presigned URL generation | Required | Required | Required | Required | Rust/Go | Planned |
| Resumable transfer jobs | Desktop Only | Desktop Only | Desktop Only | Desktop Only | Optional | Planned |
| Drag and drop ingest | Desktop Only | Desktop Only | Desktop Only | Desktop Only | N/A | App shell ready |

Transfer notes:

- The Flutter shell selects an automatic S3 multipart upload size from the largest file in each batch and sends that effective size through the existing engine contract.
- Python, Go, Rust, and Java upload parts concurrently with bounded workers. Automatic sizing remains within S3's 5 MiB–5 GiB part range and 10 000-part maximum.
- Users can disable automatic sizing and supply the manual upload part size in Settings. The manual value also remains the download range size.

## Benchmark Features

| Feature | Python | Go | Rust | Java | Android | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Benchmark config validation | Required | Required | Required | Required | Rust/Go | Planned |
| Mixed/write/read/delete workloads | Required | Required | Required | Required | Rust/Go | Planned |
| Duration and operation count modes | Required | Required | Required | Required | Rust/Go | Planned |
| Pause/resume/stop | Required | Required | Required | Required | Rust/Go | Planned |
| CSV export | Required | Required | Required | Required | Rust/Go | Planned |
| In-app charts input schema | Required | Required | Required | Required | Rust/Go | Stubbed |

## Inspector Tools

| Feature | Python | Go | Rust | Java | Android | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Put test data (`runPutTestData`) | Required | Required | Required | Required | Rust/Go | Implemented (native, all desktop engines) |
| Delete all (`runDeleteAll`) | Required | Required | Required | Required | Rust/Go | Implemented (native, all desktop engines) |

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
