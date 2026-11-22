# Backend Feature Matrix

This file records platform and provider support for 2.3.0. Desktop advanced administration uses the bundled Python reference adapter; ordinary transfers use the selected engine. Android/iOS use the shared REST adapter for data and administration and a shared benchmark runtime. Native bridges retain health and basic S3 connection/listing operations. Capability gates and the exceptions below are part of the supported scope, rather than promises of identical SDK coverage.

## Storage Providers

Profiles carry an `endpointType` of `s3Compatible`, `awsS3`, `azureBlob`, or `googleCloudStorage`. An unknown type is rejected; it is never treated as S3.

| Provider | Auth | Python | Go | Rust | Java |
| --- | --- | --- | --- | --- | --- |
| S3-compatible (MinIO, Ceph, etc.) | Access/secret key (SigV4) | Supported | Supported | Supported | Supported |
| AWS S3 | Access/secret key (SigV4) | Supported | Supported | Supported | Supported |
| Azure Blob Storage | Account name + access key (Shared Key) | Supported | Supported | `unsupported_feature` error | `unsupported_feature` error |
| Google Cloud Storage (native JSON API) | Service-account key file | Supported | Supported | `unsupported_feature` error | `unsupported_feature` error |

Azure notes:

- The profile's access-key field holds the storage account name; the secret-key field holds the account access key. An empty endpoint URL resolves to `https://<account>.blob.core.windows.net`; set a custom URL for Azurite or sovereign clouds.
- Buckets map to containers and folder markers to zero-byte blobs with a trailing `/`.
- Azure data operations support Shared Key and SAS. Python/Go also support refreshable Entra credentials on desktop. Rust/Java retain explicit unsupported-provider errors.
- Azure tags, exact versions/snapshots, tiers and signed links have provider-specific actions. Account lifecycle and container-protection management require the desktop reference adapter with Entra/RBAC. ADLS directory/ACL actions require a proven compatible HNS endpoint. S3 bucket policies, ACLs and encryption controls are not translated into Azure account settings.
- Mobile supports static S3/session credentials and Azure Shared Key/SAS, without desktop credential chains or management-plane identity flows.

Legend:

- `Required`: must be implemented for all engines on supported platforms
- `Capability-Gated`: UI may expose only when the target reports support
- `Desktop Only`: required on Windows, macOS, and Linux
- `Shared REST` / `Shared runtime`: implemented in the common Android/iOS adapter

Google Cloud Storage notes:

- The profile's secret is the complete service-account key file. It is stored only in secure storage, like every other credential.
- Listing, upload (simple and resumable), ranged download, copy, move, delete, folder markers, generations as versions, bucket versioning and V4 signed links are supported on desktop with the Python and Go engines. Lifecycle, policy, CORS, default encryption, tagging, tools and benchmarks are not.
- Both engines were run end to end against the `fake-gcs-server` emulator. They have not been run against the live Google service.
- Google Cloud Storage reached with HMAC keys remains an ordinary S3-compatible profile and works with all four engines.
- Mobile does not support native Google Cloud Storage profiles in this version.

Provider templates in the profile editor prefill the endpoint, signing region and addressing style for 21 services. They make no capability claims; entries whose values could not be confirmed in current provider documentation carry a "check these values" note.

## Optional encryption

Nothing in this section is enabled by default.

| Feature | Python | Go | Rust | Java | Android / iOS |
| --- | --- | --- | --- | --- | --- |
| SSE-S3, SSE-KMS, DSSE-KMS on upload, copy, folder creation | Supported | Supported | Supported | Supported | Shared REST |
| SSE-C (customer key) upload, download, details, copy | Supported | Supported | Supported | Supported | Shared REST |
| Azure encryption scope and customer-provided key | Supported | Supported | N/A | N/A | Shared REST |
| Object encryption shown in the inspector | Supported | Supported | Supported | Supported | Shared REST |
| Client-side encryption (age v1 payload cipher) | Supported | Supported | Supported | Supported | Shared REST |
| Passphrase-protected key file with backup and import | App | App | App | App | App |
| Key file sync through an assigned bucket | App | App | App | App | App |

Encryption notes:
- Bucket encryption has forms for SSE-S3, SSE-KMS and DSSE-KMS alongside the JSON editor, plus bucket/prefix vault rules with Default, optional name encryption, and Strict protection. Settings → Encryption offers per-connection editing and a six-part setup guide; opening it does not probe providers.

- Key creation shows the exact generated key before saving, with Copy and Generate another actions. Imports can be revealed, and key-file dialogs can generate and copy a random 125-bit passphrase. Secrets remain in the dialog and encrypted key file.
- Header transmission and client-side ciphertext are covered by loopback fixtures and shared vectors in every engine. Provider acceptance of each mode (KMS permissions, SSE-C blocking, compatible stores) has not been tested against live endpoints.
- Key file sync runs in the app on every platform, independent of the selected engine. The sync bucket must be on an S3-type profile with static access keys. It was run against a loopback test server and the `gofakes3` emulator, not against a live provider.
- Customer-key objects cannot be previewed or shared by link; they must be downloaded.
- Benchmarks and the resumable-transfer workflows do not take encryption options.
- Client-encrypted objects carry a `.age` suffix and can be decrypted outside the app with the `age` tool and the vault key. Name protection is optional and off by default. Default keeps names visible; Default with names encrypted preserves folders using deterministic encrypted segments; Strict uses a random encrypted name for each upload, flattens folders, and never overwrites. Encrypted names require an unlocked key file for uploads and display. Sizes, counts and dates remain visible; deterministic names also reveal folder structure, lengths and equality, while Strict reveals path length rounded to 16 bytes. The destination prefix stays visible. Some S3-compatible stores limit segments to 255 characters (about 170 UTF-8 bytes per deterministic name or 143 bytes per Strict path). Name recovery from the vault key is documented in `contracts/transport_contract.md`.
- Mobile encrypts and decrypts in Dart and reproduces the shared vectors byte for byte. It has not been run on a physical device; on this development Mac the cipher path handles about 42 MiB/s, and phones will be slower.

## Core Browser Features

| Feature | Python | Go | Rust | Java | Android | iOS | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Health and engine descriptor | Required | Required | Required | Required | Native Kotlin | Native Swift | Implemented |
| Endpoint profile validation | Required | Required | Required | Required | Native / REST | Native / REST | Implemented |
| Capability detection | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Bucket listing | Required | Required | Required | Required | Native / REST | Native / REST | Implemented |
| Bucket create/delete | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Bucket versioning get/set | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Bucket lifecycle CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Shared REST | Shared REST | Implemented |
| Bucket policy CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Shared REST | Shared REST | Implemented |
| Bucket CORS CRUD | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Shared REST | Shared REST | Implemented |
| Bucket encryption read/write | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Shared REST | Shared REST | Capability-gated |
| Bucket tagging read/write | Capability-Gated | Capability-Gated | Capability-Gated | Capability-Gated | Shared REST | Shared REST | Implemented |
| Object list pagination | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Flat and hierarchical listing | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Metadata, headers, and tags | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Version listing and delete markers | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Upload | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Download | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Delete single and batch | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Copy, move, rename | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Create folder marker | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Presigned URL generation | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Live pause/resume/cancel | Supported | Unsupported | Unsupported | Supported | Capability-gated | Capability-gated | Job capability-gated |
| Drag and drop ingest | Desktop Only | Desktop Only | Desktop Only | Desktop Only | N/A | N/A | App shell ready |

Transfer notes:

- Python and Java accept concurrent controls on the original job process. Go and Rust use sequential request loops and return `unsupported_feature` for interactive controls; their job payloads must not advertise pause/resume/cancel. The separate desktop reference recovery workflow supports explicit restart-resume for S3 uploads/range downloads and Azure block uploads/range downloads. It verifies source/destination identity and reconciles unknown completion before further writes; ordinary transfer jobs do not imply durable recovery.
- Host admission is bounded (four global / two per engine processes, 64 queued requests). Ordinary requests have a two-minute deadline; transfers use a no-progress deadline, suspended while explicitly paused. Control requests have a 15-second deadline. Timeout outcomes can be unknown and must not be automatically retried as successful mutations.

- The Flutter shell sizes each file independently. Multi-file selections use one parent UI job with aggregate bytes/status, sequential single-file engine requests, and nested per-file event records. Part workers remain parallel and bounded inside the active file. Cancellation stops queued files; sequential engines may finish the active file first.
- Python, Go, Rust, and Java upload parts concurrently with bounded workers. Automatic sizing remains within S3's 5 MiB–5 GiB part range and 10 000-part maximum.
- Users can disable automatic sizing and supply the manual upload part size in Settings. The manual value also remains the download range size.

## Benchmark Features

| Feature | Python | Go | Rust | Java | Android | iOS | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Benchmark config validation | Required | Required | Required | Required | Shared runtime | Shared runtime | Implemented |
| Mixed/write/read/delete workloads | Required | Required | Required | Required | Shared runtime | Shared runtime | Implemented |
| Duration and operation count modes | Required | Required | Required | Required | Shared runtime | Shared runtime | Implemented |
| Pause/resume/stop | Required | Required | Required | Required | Shared runtime | Shared runtime | Implemented |
| CSV export | Required | Required | Required | Required | Shared runtime | Shared runtime | Implemented |
| In-app charts input schema | Required | Required | Required | Required | Shared runtime | Shared runtime | Implemented |
| S3 API conformance (`s3ConformanceOp`, see `docs/s3-api-conformance-spec.md`) | Required | Required | Required | Required | Not offered | Not offered | Implemented (desktop only) |

## Inspector Tools

| Feature | Python | Go | Rust | Java | Android | iOS | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Put test data (`runPutTestData`) | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |
| Delete all (`runDeleteAll`) | Required | Required | Required | Required | Shared REST | Shared REST | Implemented |

Both tools execute inside the selected desktop engine or shared mobile adapter (no external scripts): put-testdata creates the configured object count/size/versions with a bounded worker pool; delete-all pages object versions (falling back to plain listing when versioning is unsupported) and batch-deletes with configurable batch size, workers, and delay.

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

## September reliability implementation

- Desktop downloads stage and validate data before publishing. Keep-both is the
  default; explicit replacement commits only validated files. Python/Go Azure
  downloads follow the same publication boundary. iOS and Android keep unique
  destinations and validate size before making files available.
- Azure copy/move success requires an explicit successful copy status and a
  matching copy ID. Pending, missing, failed, aborted, or replaced copy identities
  retain the source. Moves to the same source/destination are rejected.
- Cancel in action details and inline browser controls targets the owning action.
  Read requests stop independently; cancelling a dispatched mutation can produce
  an unknown outcome. This does not promise rollback or restart-resume.
- Python/Java transfer cancellation first reports `cancelling`; the original
  transfer response confirms completion of cleanup. Go/Rust active transfer
  controls remain unsupported and are explained in Tasks; batch cancellation
  still stops remaining files. Native bridges can stop the parent transfer
  action, with an unresolved remote outcome reported when applicable.
- Benchmark views use engine measurements. Missing detail stays unavailable;
  demonstration data remains in MockEngineService.
- Settings has six groups. Connection Test, Save, Use profile, and startup
  preferences are independent. Ordinary settings writes do not save unsaved
  profile credentials. Benchmark-only settings are labeled and grouped as such.

## October 2.3.0 administration and recovery

- Access/ACL presets and lifecycle tiering presets generate bucket/endpoint-aware configuration, preserve custom rules and require fresh configuration before saving.
- Current-content bucket copy supports configured S3/Azure endpoints with bounded relay, exact keys, metadata/tags where representable and metadata-only restart checkpoints. Desktop S3 history copy preserves chronological versions/delete markers in an empty versioned destination prefix. Selected bucket configuration is reviewed and applied after content completes.
- Exact-version actions, Object Lock/retention/legal holds, archive restore, content headers/encryption and multipart inspection/cleanup are exposed through advanced administration. Unsupported provider semantics remain explicit.
- Delete recovery retries normally first. Only confirmed never-versioned compatible buckets may perform conditional empty-PUT/delete recovery. AWS, enabled/suspended/unknown versioning and protection/permission failures cannot enter that fallback. The alternative versioned fallback remains deferred by request.
- Benchmark state is credential-free. Engines retain bounded recent operation histories with cumulative totals and full CSV exports; elapsed timing and checksum/error/retry results are measured.
- Local qualification uses real MinIO and Azurite plus protocol fixtures. See [2.3.0 checks and boundaries](2.3.0-verification.md) and [repeatable performance results](local-s3-performance.md). This does not claim live-cloud or physical-device qualification.

The broad requirements above describe desired parity. Interactive controls and
provider support are governed by the explicit capability exceptions; they are
not unconditional guarantees for every engine. See
[implementation and verification](improvements-implementation-2026-09.md).
