# S3 API conformance suite

The S3 API conformance suite checks how an S3 endpoint behaves against the
AWS S3 API specification, through each of the app's desktop SDK engines. It
lives in the Benchmark workspace of the **desktop app only** (Benchmark →
*S3 API conformance*). It is not a load test: every check makes a few calls and
compares the responses with what AWS documents. The latency of every call is
recorded, so the results double as a per-operation latency profile.

This document describes the design, the staged bucket lifecycle, every check
and its AWS expectation, the per-SDK behaviour the suite has to account for, and
the results of the reference run against the AWS emulator.

## Architecture

The suite has two parts. The council (Claude Opus 5.5, GPT-6.2 Sol and
Gemini 4 Neon) chose this split so that the expectations exist only once and
every SDK is judged by the same code.

| Part | Where | Responsibility |
| --- | --- | --- |
| Catalog and orchestration | `apps/flutter_app/lib/conformance/` (pure Dart) | The check catalog, the AWS expectations, bucket staging, Expected-vs-Actual records, cancellation, teardown, reports and the cross-engine comparison. |
| Engine primitive | `s3ConformanceOp` in each desktop engine | Executes **one** S3 operation through the engine's real SDK and returns what came back: HTTP status, S3 error code, allow-listed headers, parsed output, body digest and latency. |

The wire contract is in `contracts/transport_contract.md`, section
"S3 API conformance (desktop only)", with the JSON schema in
`contracts/engine_contract.json` and the shared body-generator vectors in
`contracts/vectors/s3-conformance-body.json`.

Engines implementing the primitive:

| Engine | SDK | Module | Input mapping |
| --- | --- | --- | --- |
| `python` | boto3 / botocore 1.43.89 | `engines/python/src/s3_conformance.py` | Generic: botocore operation model (`xform_name`) behind an allowlist |
| `go` | aws-sdk-go-v2, service/s3 1.96.4 | `engines/go/src/s3_conformance.go` | Typed dispatch table; JSON decoded into the SDK input structs |
| `rust` | aws-sdk-s3 1.125.0 | `engines/rust/src/s3_conformance*.rs` | Typed builders and output projections per operation |
| `java` | AWS SDK for Java v2 2.41.29 | `engines/java/.../S3Conformance.java` | Generic: `SdkPojo.sdkFields()` driven by AWS member names |

A future desktop engine (for example a raw-HTTP Rust engine) joins the suite by
implementing `s3ConformanceOp` and advertising the `conformance.s3`
capability with the operations it supports. Operations an engine does not
implement are reported as *unsupported by the engine*, never as endpoint
failures.

### Engine client settings

Every engine builds a dedicated client for conformance calls, separate from the
client used for browsing:

- **One attempt.** SDK retries are off, so an error status is observed as the
  endpoint returned it and latency is not inflated by hidden retries.
- **Checksums only when requested.** Request checksum calculation and response
  checksum validation are `when_required` for every endpoint type, including
  AWS S3. A check that wants a checksum asks for it explicitly.
- **No redirect following.** A 3xx response is reported, not chased.
- The profile's endpoint, region, addressing style, TLS settings, CA bundle and
  credentials are reused.

### Observation model

A service response of any status is a successful observation
(`outcome: service`). `sdk_validation` (the SDK refused the input before
sending), `sdk_decode` (a response arrived but the SDK could not parse it) and
`transport` (connection, TLS or timeout) are reported as such. Only
`service` outcomes are compared with the specification; an `sdk_decode`
result is itself a finding (see the Rust notes below). `httpStatus` is the wire
status: an S3 error embedded in a `200` response (CompleteMultipartUpload,
copies) is reported as `200` with its error code, and the host never counts a
2xx that carries an error code as a success. `attempts` counts real HTTP sends;
the Python engine removes botocore's S3 region redirector from its
conformance client so one observation is always one request.

Header-bound values (ETag, `x-amz-version-id`, checksums, lock headers) are
read from the allow-listed response headers, so every SDK is judged on the same
wire data. Body-bound values come from the minimum output projection in the
contract.

## Running it

### In the app

1. Select an S3 or S3-compatible endpoint profile.
2. Open **Benchmark → S3 API conformance → Setup & run**.
3. Enter a **base bucket name** (3–40 lower-case letters, digits and hyphens).
4. Choose one engine, or several to compare SDKs (they run one after another).
5. Choose the options, then **Run conformance**.

| Option | Default | Effect |
| --- | --- | --- |
| Object Lock bucket | on | Runs phase 3 on a second, lock-enabled bucket. |
| Short COMPLIANCE check | on | Locks one object in COMPLIANCE mode for 5 seconds. Teardown waits for it. |
| SSE-C checks | on | Runs only on HTTPS or loopback endpoints; otherwise skipped. Keys are throwaway and never stored. |
| SSE-KMS check | on | Informational; a KMS key ID may be given. |
| Keep buckets when checks fail | off | Off: buckets are always emptied and deleted. On: locks and uploads are released but the buckets stay for inspection. |

**Stop and clean up** stops after the in-flight call and still runs teardown.
**Stop without cleanup** skips teardown after confirmation and reports the
buckets it left behind.

*Results* groups checks by phase and category. Each check expands to show the
AWS expectation, every Expected-vs-Actual comparison (mismatches first, with an
explanation), and every call with its status, error code and latency.
*Compare engines* shows a check-by-engine matrix, by default only the checks
whose status differs between engines. Reports can be saved as JSON (every check
and call) or Markdown (summary, discrepancies, and non-passing checks).

The feature is shown only when the app runs on Windows, macOS or Linux with the
desktop sidecar engine service. Mobile builds never construct it: the mobile
engine services do not implement `S3ConformanceTransport` and the mode selector
is not rendered.

### Headless

The same suite runs without the app for scripted verification:

```sh
cd apps/flutter_app
dart run tool/s3_conformance.dart \
  --profile /path/to/profile.json \
  --engine 'python=/path/to/python3 ../../engines/python/src/main.py' \
  --engine 'go=/path/to/s3-browser-go-engine' \
  --engine 'rust=/path/to/s3-browser-rust-engine' \
  --engine 'java=/path/to/s3-browser-java-engine' \
  --base odb-conf --out /tmp/conformance
```

The profile file is an engine profile (`endpointType`, `endpointUrl`,
`region`, `accessKey`, `secretKey`, `pathStyle`, `caBundlePath`, ...). The
credentials are passed to the engine process only; they are never printed or
written to the reports. Flags: `--no-lock`, `--no-compliance`, `--no-ssec`,
`--retain`.

## Staged bucket lifecycle

Each engine run creates its own buckets, so engines never share state:

| Bucket | Name | Purpose |
| --- | --- | --- |
| Bucket 1 | `<base>-std-<run>` | Created without Object Lock. Phase 1 runs while versioning has never been enabled; phase 2 enables it. |
| Copy peer | `<base>-xb-<run>` | Created and deleted inside `copy.cross-bucket`. |
| Bucket 2 | `<base>-lock-<run>` | Created with `ObjectLockEnabledForBucket: true` for phase 3. |

`<run>` is eight random lower-case characters. Before anything is created the
suite sends HeadBucket for all three names and needs an affirmative `404` for
each; otherwise it picks new names (five attempts) and, failing that, stops
without creating anything. A HEAD followed by a CreateBucket still leaves a
short race on endpoints whose CreateBucket succeeds for a bucket you already
own (AWS in `us-east-1`); the random run ID makes a collision in that window
practically impossible. A create whose outcome is not definite (a decode
failure, `3xx`, `5xx` or throttling) is reported for manual inspection and
never purged. A bucket counts
as **owned** only when its CreateBucket returned 2xx; only owned buckets are
purged and deleted. A create without a definite outcome (for example a
transport failure) is reported for manual inspection and never purged, and a
`409` (someone else's or a pre-existing bucket) is never touched.

1. **Setup.** Create bucket 1 and verify HeadBucket, GetBucketLocation,
   ListBuckets, duplicate creation and the initial (absent) versioning status.
   If bucket 1 cannot be created, phases 1 and 2 are skipped.
2. **Phase 1, non-versioned.** Object CRUD, keys, metadata, checksums,
   conditional requests, ranges, attributes, copy, delete, listing, tagging,
   ACLs, multipart, presigned URLs, server-side encryption, bucket
   subresources and error responses.
3. **Gate.** `versioning.gate` records whether every *required* phase-1 check
   passed. Coverage must be affirmative: a required check that failed, errored,
   was unsupported or was skipped leaves the gate incomplete. Phase 2 runs
   either way, so versioning remains diagnosable; the gate result is shown in
   the report as "required coverage met" or "incomplete". A *deviation*
   counts as covered: for the AWS SDK for Java v2 the
   listing checks verify the decoded keys, prefixes and StartAfter, but the
   wire encoding itself is unobservable through that SDK.
4. **Phase 2, versioning.** `PutBucketVersioning(Enabled)`, then
   `versioning.ready` (probe writes until a version ID reads back, at most 60 s,
   because AWS documents a propagation delay), then the versioning checks,
   then `PutBucketVersioning(Suspended)` and the "null" version checks. If
   versioning does not take effect within the budget, the remaining phase-2
   checks are skipped rather than reported as failures.
5. **Phase 3, Object Lock.** First the negative checks on bucket 1 (Object
   Lock calls on a bucket without Object Lock must fail), then bucket 2.
6. **Teardown.** Always runs, also after Stop (unless *Stop without cleanup*).

### Object Lock safety

- GOVERNANCE retention is used for every protected fixture and lasts at most
  about three minutes (`now + 120 s`, extended once by 60 s). Times are taken
  from the server's `Date` header, not the local clock.
- The default bucket retention (`GOVERNANCE`, 1 day) is written, read back and
  **cleared before any object is written**. Protected writes start only after
  a successful GetObjectLockConfiguration shows Object Lock enabled with no
  default rule; anything else (a failed clear, a failed or unreadable read)
  skips them.
- The only COMPLIANCE lock is the optional 5-second check. Its retain-until date
  is recorded before the PUT is sent, so even a timed-out write is waited for:
  teardown waits for that date (at most 20 s) before deleting the version.
- An endpoint that rejects lock-enabled bucket creation marks the phase
  *unsupported*. One that accepts the flag but reports no lock configuration
  fails `lock.config.get`, and protected writes are skipped.

### Teardown

For each owned bucket (lock bucket first):

1. HeadBucket. Only a definite `404` means the bucket is already gone; an
   engine failure or another non-service outcome leaves the bucket reported
   as retained with an error, never silently skipped.
2. Abort every in-progress multipart upload (paginated); a listing failure is
   reported.
3. On the lock bucket, set every legal hold that is ON to OFF.
4. Delete page by page from the start of the listing (at most 1000 entries in
   memory) with `DeleteObjects` (`BypassGovernanceRetention: true` on the lock
   bucket), falling back to per-object `DeleteObject` for entries the batch
   could not remove. Plain keys are used only for a bucket whose versioning
   status is confirmed absent, so a delete can never add delete markers.
5. DeleteBucket, then HeadBucket must return `404`; a `204` that leaves the
   bucket in place is reported as retained. A listing the engine could not
   project, or a bucket still listing versions after 200 rounds, is reported.

*Stop without cleanup* pressed during teardown stops before the next cleanup
request (and ends any wait) and lists the remaining buckets as retained.

The result (`teardown.complete` and the teardown summary) lists deleted and
retained buckets, removed versions, aborted uploads, cleared holds, leftovers
and the first errors.

## Result model

| Status | Meaning |
| --- | --- |
| Pass | Every expectation held. |
| Fail | A required check had at least one mismatch that is not informational. |
| Deviation | An informational check had a mismatch, or a required check had only informational mismatches (for example an exact 2xx code or an error code where only the status is normative). |
| Unsupported | The endpoint returned `501 NotImplemented`, or the engine does not implement the operation (or lacks an optional SDK dependency). |
| Skipped | A prerequisite check did not pass, or the option is off. |
| Error | Transport failure or a harness error. |

Severity is **required** for behaviour every S3 implementation is expected to
provide, and **informational** for endpoint-optional features (acceleration,
analytics, inventory, intelligent tiering, request payment, logging, website,
notification, replication, SSE-KMS, SSE-C), for AWS legacy behaviours, and for
details the AWS documentation states inconsistently.

Every check records the calls it made (operation, outcome, HTTP status, S3
error code, latency in ms, attempts) and every comparison as
`{field, expected, actual, ok, explanation}`. Records are bounded: at most 64
calls and 96 comparisons per check, strings clipped to 240 characters, no
bodies.

## Specification details the catalog encodes

These AWS behaviours are commonly misremembered; the catalog asserts the AWS
behaviour:

- HeadObject and HeadBucket errors have no body. Only the status is compared;
  the code an SDK synthesises (`404`, `NotFound`) is ignored. The same applies
  to `304 Not Modified`.
- DeleteObject on a missing key returns `204`, not `404`.
- GetObject `If-None-Match` with the current ETag returns `304`, not `412`.
  `If-Match` true takes precedence over a false `If-Unmodified-Since` (200),
  and `If-None-Match` false over a true `If-Modified-Since` (304).
  Conditional dates are whole seconds *after* Last-Modified, never in the
  future, after waiting until the server clock has passed them.
- A range whose end lies beyond the object is clamped (`206`), a range that
  starts at the object size is `416 InvalidRange`, and S3 ignores
  multi-range requests (`200` with the whole object, informational).
- GetObjectAttributes returns the ETag **without** quotes.
- `EncodingType=url` encodes keys form-style: a space is `+` and a literal
  `+` is `%2B`. ListObjectsV2 `KeyCount` counts common prefixes.
- PutObject `If-None-Match: *` returns `412 PreconditionFailed` when the key
  exists; PutObject `If-Match` returns `404 NoSuchKey` for a missing key.
- A wrong `x-amz-checksum-*` or Content-MD5 returns `400 BadDigest` and stores
  nothing.
- GetObjectTagging on an untagged object returns `200` with an empty TagSet;
  GetBucketTagging on an untagged bucket returns `404 NoSuchTagSet`.
- In a versioned bucket, GetObject of a key whose latest version is a delete
  marker returns `404` with `x-amz-delete-marker: true`; GetObject or
  HeadObject **of the delete marker's version ID** returns
  `405 MethodNotAllowed`. Deleting the marker by version ID restores the
  previous version.
- In a suspended bucket, writes replace the single `"null"` version; a simple
  delete creates a `"null"` delete marker.
- A legal hold blocks a version delete even with
  `x-amz-bypass-governance-retention`. COMPLIANCE retention cannot be bypassed,
  shortened or switched to GOVERNANCE.
- PutObject with Object Lock headers requires Content-MD5 or an
  `x-amz-checksum-*` header (required check; the engines send checksums only on
  request, so the request really lacks one) and stores nothing when rejected.
- `EntityTooSmall` is reported by CompleteMultipartUpload, not by UploadPart.
- AWS buckets created since 2023 have SSE-S3 default encryption,
  BucketOwnerEnforced ownership and Block Public Access; the catalog accepts both
  the AWS default and the absent state for those initial reads.

## Per-SDK notes

| SDK | Behaviour that affects conformance testing | How the suite handles it |
| --- | --- | --- |
| boto3 | Adds `EncodingType=url` to ListObjects/V2/Versions when the caller omits it, and decodes the result itself. With an explicit `EncodingType`, it returns the raw encoded values. | Listing checks without encoding compare decoded keys; the `encoding-url` checks send it explicitly and decode on the host. |
| boto3 | CRC32C requires the optional `awscrt` package, which the bundled engine does not ship. | Reported as **unsupported by the engine** (`checksum.crc32c.valid`), not as an endpoint failure. |
| boto3 | `CopySource` as a dict is percent-encoded once (`+` → `%2B`). | Matches the contract. |
| boto3 | The S3 region redirector re-sends after `301`/`400` and may probe HeadBucket; an error embedded in a `200` is turned into `500`. | The conformance client removes the redirector, counts sends and reports the wire status. |
| AWS SDK for Java v2 | URL-decodes `EncodingType=url` listing responses before returning them, so the wire encoding cannot be inspected. | The engine declares it (`client.urlEncodedListings: decodedBySdk`); the keys are compared as returned and the check records a deviation instead of decoding twice. For any other engine, unencoded keys are a failure. |
| AWS SDK for Java v2 | CopyObject/UploadPartCopy name the destination `DestinationBucket`/`DestinationKey`. | The engine maps the contract's `Bucket`/`Key` and `CopySource` structure. |
| aws-sdk-s3 (Rust) | Strictly checks the XML root element of every response. | An endpoint that uses the wrong root element produces `sdk_decode`; this is how the emulator's ListBucketAnalyticsConfigurations and ListBucketIntelligentTieringConfigurations root-name deviations were found. |
| aws-sdk-s3 (Rust) | The engine's ordinary client rejects custom CA bundles. | The conformance client trusts `caBundlePath` in addition to the native roots; `verifyTls: false` remains unsupported. |
| aws-sdk-go-v2 | Copy sources need explicit encoding; the engine reuses its proven `+`-preserving encoder. | Matches the contract. |
| aws-sdk-s3 (Rust) | The SDK takes a pre-encoded copy source. | The engine encodes the bucket and each key segment once and keeps `/` literal, like the other engines. |
| All | Recent SDK versions add CRC checksums by default (`when_supported`). | Disabled for conformance (`when_required`), so a checksum is sent only when a check asks for it. |
| All | HEAD error codes differ by SDK (`404`, `NotFound`, empty). | Ignored; only the status is compared. |

## Secret hygiene

The suite follows `AGENTS.md`:

- Credentials, session tokens, `Authorization`, SSE-C keys and presigned URLs
  never appear in results, logs, traces or exports. With API logging on, the
  desktop app traces conformance calls by method, status and latency only;
  request and result bodies, and engine error text, are not traced. The engines report only
  allow-listed response headers; `PresignedRequest` reports the query
  parameter **names** only and strips query strings from transport errors.
- SSE-C keys are generated per run in memory, sent only through the existing
  `encryption`/`sourceEncryption` objects (which the engines and the host's
  `DiagnosticSafety` already redact), refused inside `input`, and sent only
  to HTTPS or loopback endpoints.
- Free-form diagnostics (error messages, error codes, request IDs) lose every
  profile credential whatever its length, SigV4 signing values
  (`Signature=`, `Credential=`, `X-Amz-Security-Token=`, `Authorization`) and
  URL query strings, and are clipped to 256 characters only after scrubbing.
  In S3 data (outputs and headers) profile credentials of 16 characters or
  more are replaced; shorter ones, such as an emulator's `test`, are ordinary
  words there and are kept. Customer keys are always removed. URL-valued headers (`location`,
  `x-amz-website-redirect-location`) lose their query string. The host
  applies the same scrub again to every engine result before recording it. Presigned error documents are parsed for `Code` and
  `Message` only, because AWS error documents can echo the canonical request.
- The engines' response sanitizers keep opaque pagination cursors
  (`ContinuationToken`, `NextContinuationToken`, markers, upload IDs) while
  still redacting real secrets. The Java engine's sanitizer previously
  redacted any field containing "token"; it now exempts exactly
  `ContinuationToken` and `NextContinuationToken` and nothing else.
- Records and exports are bounded (see Result model); at most five reports are
  kept in memory and none are persisted unless the user saves them. Teardown
  holds one listing page at a time, the headless runner discards response
  frames over 64 MiB, and the Python engine drops structured output over
  4 MiB (S3 pages hold at most 1000 entries).
- Known S3 error codes (and HTTP-status codes that SDKs synthesise for HEAD)
  are kept verbatim, so redaction never turns `AccessDenied` into something an
  assertion cannot recognise; any other error code, and every request ID, is
  scrubbed like a message. Presigned error documents are XML-decoded before
  scrubbing.
- **Residual risk:** the response caps above apply after the SDK has read the
  response. The engines' SDKs read a structured (XML) response
  completely before parsing it, so a misbehaving endpoint that returns an
  enormous listing or error document can make one engine process allocate
  that much memory before any cap applies. This is the same exposure as the
  engines' ordinary browsing calls; streamed object bodies are bounded
  (32 MiB is hashed, not stored).
- Base bucket names covered by a client-encryption (vault) rule are refused.

## Verification

- Engines: `pytest tests/contract/test_python_s3_conformance.py`,
  `go test ./...`, `cargo test`, the Java Gradle test harness
  (`S3ConformanceTest`). Each runs the generator vectors and a local fake S3
  server covering success and error observations, header allow-listing, cursor
  preservation, copy-source encoding, the unknown-operation error, refusal of
  customer keys in `input`, and presigned requests without URL leakage.
- Host: `test/conformance_suite_test.dart` (preflight and staging order, gate,
  teardown, a colliding bucket never purged, cancellation with and without
  cleanup, unsupported mapping, SSE-C gating and key leakage, JSON round trip,
  discrepancy detection) and
  `test/conformance_view_test.dart` (desktop-only visibility and layout at
  1000, 1280 and 390 px wide, 100 % and 150 % scale, with text-size and
  no-clipping checks).

## Council review

The feature was designed, implemented and reviewed by a three-model council:
Claude Opus 5.5 (lead, catalog, host, Python engine, UI, docs), GPT-6.2 Sol
(Go and Rust engines, Rust custom CA support, review) and Gemini 4 Neon (Java
engine, UI design, review). Both reviewers' Stage 3 findings were fixed before
the reference run below, among them: teardown ownership proof and name
preflight, fail-closed teardown and Object Lock guards, single-send Python
observations with wire status, credential and signed-URL scrubbing, gate
coverage, a versioning readiness probe, stricter post-rejection assertions,
encoded listing fields, and bounded memory.

## Check catalog

The catalog below lists every check in execution order, the operations it calls
and the AWS behaviour it expects.

### Setup — bucket 1

| Check | Severity | Operations | AWS specification expectation |
| --- | --- | --- | --- |
| `bucket.create` | required | CreateBucket | CreateBucket: 200 OK with a Location header; omit LocationConstraint in us-east-1. |
| `bucket.head` | required | HeadBucket | HeadBucket: 200 OK; AWS adds x-amz-bucket-region. |
| `bucket.location` | required | GetBucketLocation | GetBucketLocation: 200; LocationConstraint is empty/null for us-east-1, else the region. |
| `bucket.list` | informational | ListBuckets | ListBuckets: 200; Buckets[].Name contains the bucket with a CreationDate. |
| `bucket.create.duplicate` | informational | CreateBucket | CreateBucket: 409 BucketAlreadyOwnedByYou (AWS us-east-1 legacy behaviour may return 200). |
| `bucket.versioning.initial` | required | GetBucketVersioning | GetBucketVersioning: 200 with no Status element. |

### Phase 1 — bucket 1, versioning never enabled

| Check | Severity | Operations | AWS specification expectation |
| --- | --- | --- | --- |
| `object.put` | required | PutObject | PutObject: 200 OK with a quoted ETag; for a single-part unencrypted upload the ETag is the MD5 of the payload. |
| `object.get` | required | GetObject | GetObject: 200 with the same ETag, Content-Length and Content-Type; payload unchanged. |
| `object.head` | required | HeadObject | HeadObject: 200 with ETag, Content-Length, Last-Modified and Accept-Ranges: bytes. |
| `object.overwrite` | required | PutObject, GetObject | PutObject on an existing key in an unversioned bucket replaces it; GetObject returns the new bytes and ETag. |
| `object.empty` | required | PutObject, GetObject, HeadObject | PutObject with an empty body: 200, ETag "d41d8cd98f00b204e9800998ecf8427e"; GetObject returns 0 bytes. |
| `object.binary` | required | PutObject, GetObject | PutObject/GetObject preserve arbitrary binary payloads (0x00–0xFF). |
| `object.key.space` | required | PutObject, HeadObject, GetObject, ListObjectsV2 | PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: "p1/keys/hello world.txt". |
| `object.key.plus` | required | PutObject, HeadObject, GetObject, ListObjectsV2 | PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: "p1/keys/a+b=c.txt". |
| `object.key.percent` | required | PutObject, HeadObject, GetObject, ListObjectsV2 | PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: "p1/keys/100% literal %2B.txt". |
| `object.key.unicode` | required | PutObject, HeadObject, GetObject, ListObjectsV2 | PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: "p1/keys/ünïcødé-日本語-🚀.txt". |
| `object.key.nested` | required | PutObject, HeadObject, GetObject, ListObjectsV2 | PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: "p1/keys/deep/nested/path/leaf.txt". |
| `object.key.reserved` | required | PutObject, HeadObject, GetObject, ListObjectsV2 | PutObject/HeadObject/GetObject/ListObjectsV2 address the exact UTF-8 key: "p1/keys/sym!$&'()*,;=:@~.txt". |
| `object.key.plus-vs-space` | required | PutObject, GetObject | S3 keys are opaque: "x+y" and "x y" address different objects (a + in the path is not a space). |
| `metadata.system` | required | PutObject, HeadObject, GetObject | PutObject Content-Type, Content-Disposition, Content-Encoding, Content-Language and Cache-Control are returned unchanged by HeadObject and GetObject. |
| `metadata.user` | required | PutObject, HeadObject, GetObject | PutObject Metadata is returned as lower-case x-amz-meta-* headers by HeadObject and GetObject. |
| `checksum.crc32.valid` | required | PutObject, HeadObject, GetObject | PutObject ChecksumAlgorithm=CRC32: 200 with x-amz-checksum-crc32; HeadObject/GetObject with ChecksumMode=ENABLED return the same value. |
| `checksum.crc32.mismatch` | required | PutObject, HeadObject | PutObject with a well-formed but wrong x-amz-checksum-crc32: 400 BadDigest; nothing is stored. |
| `checksum.crc32c.valid` | required | PutObject, HeadObject, GetObject | PutObject ChecksumAlgorithm=CRC32C: 200 with x-amz-checksum-crc32c; HeadObject/GetObject with ChecksumMode=ENABLED return the same value. |
| `checksum.crc32c.mismatch` | required | PutObject, HeadObject | PutObject with a well-formed but wrong x-amz-checksum-crc32c: 400 BadDigest; nothing is stored. |
| `checksum.sha1.valid` | required | PutObject, HeadObject, GetObject | PutObject ChecksumAlgorithm=SHA1: 200 with x-amz-checksum-sha1; HeadObject/GetObject with ChecksumMode=ENABLED return the same value. |
| `checksum.sha1.mismatch` | required | PutObject, HeadObject | PutObject with a well-formed but wrong x-amz-checksum-sha1: 400 BadDigest; nothing is stored. |
| `checksum.sha256.valid` | required | PutObject, HeadObject, GetObject | PutObject ChecksumAlgorithm=SHA256: 200 with x-amz-checksum-sha256; HeadObject/GetObject with ChecksumMode=ENABLED return the same value. |
| `checksum.sha256.mismatch` | required | PutObject, HeadObject | PutObject with a well-formed but wrong x-amz-checksum-sha256: 400 BadDigest; nothing is stored. |
| `checksum.content-md5.valid` | required | PutObject, GetObject | PutObject with Content-MD5: 200. |
| `checksum.content-md5.mismatch` | required | PutObject, HeadObject | PutObject with a well-formed but wrong Content-MD5: 400 BadDigest; nothing is stored. |
| `conditional.fixture` | required | PutObject, HeadObject | PutObject then HeadObject: ETag and Last-Modified are available. |
| `conditional.get.if-match` | required | GetObject | GetObject: 200 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-match-fail` | required | GetObject | GetObject: 412 PreconditionFailed (RFC 7232 as documented for GetObject). |
| `conditional.get.if-none-match` | required | GetObject | GetObject: 304 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-none-match-other` | required | GetObject | GetObject: 200 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-modified-since` | required | GetObject | GetObject: 304 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-modified-since-earlier` | required | GetObject | GetObject: 200 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-unmodified-since` | required | GetObject | GetObject: 200 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-unmodified-since-fail` | required | GetObject | GetObject: 412 PreconditionFailed (RFC 7232 as documented for GetObject). |
| `conditional.get.if-match-precedence` | required | GetObject | GetObject: 200 (RFC 7232 as documented for GetObject). |
| `conditional.get.if-none-match-precedence` | required | GetObject | GetObject: 304 (RFC 7232 as documented for GetObject). |
| `conditional.head.if-match-fail` | required | HeadObject | HeadObject: 412 (RFC 7232 as documented for HeadObject). |
| `conditional.head.if-none-match` | required | HeadObject | HeadObject: 304 (RFC 7232 as documented for HeadObject). |
| `conditional.put.if-none-match-star` | required | PutObject, GetObject | PutObject If-None-Match: *: 200 for a new key, 412 PreconditionFailed when the key exists; the first payload survives. |
| `conditional.put.if-match` | required | PutObject, GetObject | PutObject If-Match: 200 when the ETag matches, 412 PreconditionFailed otherwise; 404 NoSuchKey for a missing key. |
| `range.fixture` | required | PutObject | PutObject: 200. |
| `range.single` | required | GetObject | GetObject Range: 206 Partial Content, Content-Range bytes 2-5/1024, exact slice. |
| `range.suffix` | required | GetObject | GetObject Range: 206 Partial Content, Content-Range bytes 1020-1023/1024, exact slice. |
| `range.open-ended` | required | GetObject | GetObject Range: 206 Partial Content, Content-Range bytes 1000-1023/1024, exact slice. |
| `range.clamped` | required | GetObject | GetObject Range: 206 Partial Content, Content-Range bytes 1000-1023/1024, exact slice. |
| `range.unsatisfiable` | required | GetObject | GetObject Range bytes=1024-: 416 InvalidRange. |
| `range.multiple` | informational | GetObject | GetObject: S3 does not serve multipart/byteranges; AWS returns the whole object with 200. |
| `range.empty-object` | informational | PutObject, GetObject | GetObject Range bytes=0-0 on an empty object: 416 InvalidRange. |
| `object.attributes` | required | PutObject, GetObjectAttributes | GetObjectAttributes: 200; ETag without quotes, ObjectSize, StorageClass, Checksum.ChecksumSHA256 for an object uploaded with SHA256. |
| `copy.fixture` | required | PutObject | PutObject with Content-Type, metadata and tags: 200. |
| `copy.same-bucket` | required | CopyObject, HeadObject, GetObject | CopyObject: 200 with CopyObjectResult ETag and LastModified; MetadataDirective COPY keeps Content-Type and x-amz-meta-*. |
| `copy.replace-metadata` | required | CopyObject, HeadObject | CopyObject REPLACE: the destination has only the metadata and Content-Type sent with the copy. |
| `copy.special-destination` | required | CopyObject, GetObject, ListObjectsV2 | CopyObject: 200; the destination key is exactly the requested UTF-8 key. |
| `copy.tagging` | required | CopyObject, GetObjectTagging | CopyObject: TaggingDirective COPY (default) keeps the source tag set; REPLACE uses x-amz-tagging. |
| `copy.cross-bucket` | required | CreateBucket, CopyObject, GetObject, DeleteObject, DeleteBucket, HeadBucket | CopyObject between buckets: 200; the destination payload equals the source. |
| `copy.conditional` | required | CopyObject | CopyObject CopySourceIfMatch with another ETag: 412 PreconditionFailed. |
| `copy.missing-source` | required | CopyObject | CopyObject: 404 NoSuchKey. |
| `copy.onto-itself` | informational | CopyObject | CopyObject source = destination with COPY: 400 InvalidRequest; with MetadataDirective REPLACE: 200. |
| `delete.existing` | required | PutObject, DeleteObject, HeadObject | DeleteObject: 204 No Content; a following HeadObject returns 404. |
| `delete.missing` | required | DeleteObject | DeleteObject on a key that does not exist: 204 No Content (not 404). |
| `delete.batch.verbose` | required | PutObject, DeleteObjects, ListObjectsV2 | DeleteObjects Quiet=false: 200; Deleted lists every key including missing ones; Errors is empty. |
| `delete.batch.quiet` | required | PutObject, DeleteObjects, ListObjectsV2 | DeleteObjects Quiet=true: 200; no Deleted entries; Errors empty. |
| `list.fixture` | required | PutObject | PutObject: 200 for each fixture key. |
| `list.v2.prefix` | required | ListObjectsV2 | ListObjectsV2: 200; Contents sorted by UTF-8 bytes; KeyCount equals returned keys; IsTruncated false. |
| `list.v2.delimiter` | required | ListObjectsV2 | ListObjectsV2: Contents holds direct children; CommonPrefixes holds p1/list/c/; KeyCount counts both. |
| `list.v2.pagination` | required | ListObjectsV2 | ListObjectsV2: IsTruncated true with NextContinuationToken until the last page; no gaps or duplicates. |
| `list.v2.start-after` | required | ListObjectsV2 | ListObjectsV2: keys strictly after StartAfter in binary order. |
| `list.v2.encoding-url` | required | ListObjectsV2 | ListObjectsV2: EncodingType url in the response; Key, Prefix, Delimiter and StartAfter are URL-encoded (space as +). |
| `list.v2.encoding-url-fields` | required | PutObject, ListObjectsV2 | ListObjectsV2 EncodingType=url: Prefix, StartAfter, Key and CommonPrefixes are URL-encoded in the response. |
| `list.v2.empty` | required | ListObjectsV2 | ListObjectsV2: 200, KeyCount 0, no Contents, IsTruncated false. |
| `list.v1.delimiter` | required | ListObjects | ListObjects: 200; Contents and CommonPrefixes as for v2; Marker echoed. |
| `list.v1.pagination` | required | ListObjects | ListObjects: IsTruncated; NextMarker only with a delimiter, otherwise the last key is the next Marker. |
| `list.v1.encoding-url` | informational | ListObjects | ListObjects: EncodingType url; keys URL-encoded. |
| `tagging.object.empty` | required | PutObject, GetObjectTagging | GetObjectTagging: 200 with an empty TagSet (not 404). |
| `tagging.object.crud` | required | PutObject, PutObjectTagging, GetObjectTagging, HeadObject, DeleteObjectTagging | PutObjectTagging: 200; GetObjectTagging returns the set; HeadObject x-amz-tagging-count; DeleteObjectTagging: 204. |
| `tagging.object.on-put` | required | PutObject, GetObjectTagging | PutObject Tagging query string is stored as the tag set. |
| `tagging.object.limit` | informational | PutObject, PutObjectTagging | PutObjectTagging with 11 tags: 400 BadRequest (AWS documents the 10-tag limit). |
| `acl.object.get` | required | PutObject, GetObjectAcl | GetObjectAcl: 200; Owner.ID present; a grant of FULL_CONTROL to the owner. |
| `acl.object.put-private` | informational | PutObjectAcl | PutObjectAcl ACL=private: 200, or 400 AccessControlListNotSupported when Object Ownership is BucketOwnerEnforced. |
| `acl.bucket.get` | required | GetBucketAcl | GetBucketAcl: 200; Owner.ID present; a grant of FULL_CONTROL to the owner. |
| `acl.bucket.put-private` | informational | PutBucketAcl | PutBucketAcl ACL=private: 200, or 400 AccessControlListNotSupported when ACLs are disabled. |
| `multipart.create` | required | CreateMultipartUpload | CreateMultipartUpload: 200 with Bucket, Key and UploadId. |
| `multipart.upload-part` | required | UploadPart | UploadPart: 200 with an ETag per part (the MD5 of the part for unencrypted uploads). |
| `multipart.list-parts` | required | ListParts | ListParts: 200 with PartNumber, ETag and Size per part; MaxParts=1 sets IsTruncated and NextPartNumberMarker. |
| `multipart.list-uploads` | required | ListMultipartUploads | ListMultipartUploads: 200; Uploads contains the Key and UploadId. |
| `multipart.complete` | required | CompleteMultipartUpload, HeadObject, GetObject | CompleteMultipartUpload: 200 with an ETag ending in "-2"; the object has the concatenated bytes, Content-Type and metadata. |
| `multipart.part-number-read` | informational | GetObject, GetObjectAttributes | GetObject partNumber=1: 206 with Content-Length of part 1 and x-amz-mp-parts-count: 2. |
| `multipart.upload-part-copy` | required | PutObject, CreateMultipartUpload, UploadPartCopy, UploadPart, CompleteMultipartUpload, GetObject | UploadPartCopy with x-amz-copy-source-range: 200 with CopyPartResult.ETag; the completed object holds the copied range. |
| `multipart.abort` | required | CreateMultipartUpload, UploadPart, AbortMultipartUpload, ListParts, ListMultipartUploads, HeadObject | AbortMultipartUpload: 204; afterwards ListParts returns 404 NoSuchUpload and the upload is no longer listed. |
| `multipart.entity-too-small` | required | CreateMultipartUpload, UploadPart, CompleteMultipartUpload, HeadObject | CompleteMultipartUpload with a 1 KiB first part: 400 EntityTooSmall. |
| `multipart.invalid-part` | required | CreateMultipartUpload, UploadPart, CompleteMultipartUpload, HeadObject | CompleteMultipartUpload with a wrong ETag: 400 InvalidPart. |
| `multipart.invalid-part-order` | required | CreateMultipartUpload, UploadPart, CompleteMultipartUpload, HeadObject | CompleteMultipartUpload with descending part numbers: 400 InvalidPartOrder. |
| `multipart.list-uploads.pagination` | required | CreateMultipartUpload, ListMultipartUploads | ListMultipartUploads MaxUploads=1: IsTruncated with NextKeyMarker and NextUploadIdMarker; the next page lists the other upload. |
| `presign.get` | required | PutObject, PresignedRequest | A SigV4 query-signed GET (X-Amz-Algorithm, X-Amz-Credential, X-Amz-Date, X-Amz-Expires, X-Amz-SignedHeaders, X-Amz-Signature): 200 with the payload. |
| `presign.put` | required | PresignedRequest, GetObject | A presigned PUT with a signed Content-Type: 200 with an ETag; the object then reads back unchanged. |
| `presign.get-missing` | required | PresignedRequest | Presigned GET: 404 NoSuchKey. |
| `presign.expired` | informational | PutObject, PresignedRequest | Presigned GET used after X-Amz-Expires: 403 AccessDenied (Request has expired). |
| `sse.s3` | required | PutObject, HeadObject, GetObject | PutObject x-amz-server-side-encryption: AES256 — 200; PutObject, HeadObject and GetObject report AES256. |
| `sse.kms` | informational | PutObject, GetObject | PutObject x-amz-server-side-encryption: aws:kms (with the configured key, if any): 200; responses report aws:kms. Endpoints without KMS return an error. |
| `sse.c` | informational | PutObject, HeadObject, GetObject | PutObject/HeadObject/GetObject with x-amz-server-side-encryption-customer-*: 200 and AES256 reported; reading without the key: 400; with another key: 403; CopyObject re-encrypts with copy-source keys. |
| `sse.c.copy` | informational | CopyObject | CopyObject with x-amz-copy-source-server-side-encryption-customer-* (source key) and x-amz-server-side-encryption-customer-* (new key): 200; the copy reads back only with the new key. |
| `bucket.tagging` | required | GetBucketTagging, PutBucketTagging, DeleteBucketTagging | GetBucketTagging without tags: 404 NoSuchTagSet; PutBucketTagging: 204; GetBucketTagging: 200 with the set; DeleteBucketTagging: 204. |
| `bucket.cors` | required | GetBucketCors, PutBucketCors, DeleteBucketCors | GetBucketCors without rules: 404 NoSuchCORSConfiguration; PutBucketCors: 200; GetBucketCors returns the rule; DeleteBucketCors: 204. |
| `bucket.lifecycle` | required | GetBucketLifecycleConfiguration, PutBucketLifecycleConfiguration, DeleteBucketLifecycle | GetBucketLifecycleConfiguration without rules: 404 NoSuchLifecycleConfiguration; Put: 200; Get returns the rule; DeleteBucketLifecycle: 204. |
| `bucket.policy` | required | GetBucketPolicy, PutBucketPolicy, GetBucketPolicyStatus, DeleteBucketPolicy | GetBucketPolicy without a policy: 404 NoSuchBucketPolicy; PutBucketPolicy: 204; GetBucketPolicy returns it; GetBucketPolicyStatus IsPublic=false; DeleteBucketPolicy: 204. |
| `bucket.encryption` | required | GetBucketEncryption, PutBucketEncryption, DeleteBucketEncryption | PutBucketEncryption AES256: 200; GetBucketEncryption returns the rule; DeleteBucketEncryption: 204. AWS buckets keep SSE-S3 as the default afterwards. |
| `bucket.public-access-block` | required | PutPublicAccessBlock, GetPublicAccessBlock, DeletePublicAccessBlock | PutPublicAccessBlock: 200; GetPublicAccessBlock returns all four flags; DeletePublicAccessBlock: 204; then 404 NoSuchPublicAccessBlockConfiguration. |
| `bucket.ownership-controls` | required | GetBucketOwnershipControls, PutBucketOwnershipControls, DeleteBucketOwnershipControls | PutBucketOwnershipControls: 200; GetBucketOwnershipControls returns the rule; DeleteBucketOwnershipControls: 204; then 404 OwnershipControlsNotFoundError. |
| `bucket.accelerate` | informational | GetBucketAccelerateConfiguration, PutBucketAccelerateConfiguration | GetBucketAccelerateConfiguration: 200 without Status; PutBucketAccelerateConfiguration Suspended: 200; Get reports Suspended. |
| `bucket.request-payment` | informational | GetBucketRequestPayment, PutBucketRequestPayment | GetBucketRequestPayment: 200 Payer=BucketOwner; PutBucketRequestPayment BucketOwner: 200. |
| `bucket.logging` | informational | GetBucketLogging | GetBucketLogging: 200 with no LoggingEnabled element for a new bucket. |
| `bucket.website` | informational | GetBucketWebsite, PutBucketWebsite, DeleteBucketWebsite | GetBucketWebsite without configuration: 404 NoSuchWebsiteConfiguration; PutBucketWebsite: 200; Get returns index and error documents; DeleteBucketWebsite: 204. |
| `bucket.notification` | informational | GetBucketNotificationConfiguration, PutBucketNotificationConfiguration | GetBucketNotificationConfiguration: 200 and empty for a new bucket; PutBucketNotificationConfiguration with an empty configuration: 200. |
| `bucket.replication` | informational | GetBucketReplication, DeleteBucketReplication | GetBucketReplication without configuration: 404 ReplicationConfigurationNotFoundError; DeleteBucketReplication: 204. Positive replication needs an IAM role and is not exercised. |
| `bucket.analytics` | informational | ListBucketAnalyticsConfigurations, PutBucketAnalyticsConfiguration, GetBucketAnalyticsConfiguration, DeleteBucketAnalyticsConfiguration | ListBucketAnalyticsConfigurations: 200 and empty; PutBucketAnalyticsConfiguration: 200; GetBucketAnalyticsConfiguration returns Id conformance; DeleteBucketAnalyticsConfiguration: 204. |
| `bucket.metrics` | informational | ListBucketMetricsConfigurations, PutBucketMetricsConfiguration, GetBucketMetricsConfiguration, DeleteBucketMetricsConfiguration | ListBucketMetricsConfigurations: 200 and empty; PutBucketMetricsConfiguration: 200; GetBucketMetricsConfiguration returns Id conformance; DeleteBucketMetricsConfiguration: 204. |
| `bucket.inventory` | informational | ListBucketInventoryConfigurations, PutBucketInventoryConfiguration, GetBucketInventoryConfiguration, DeleteBucketInventoryConfiguration | ListBucketInventoryConfigurations: 200 and empty; PutBucketInventoryConfiguration: 200; GetBucketInventoryConfiguration returns Id conformance; DeleteBucketInventoryConfiguration: 204. |
| `bucket.intelligent-tiering` | informational | ListBucketIntelligentTieringConfigurations, PutBucketIntelligentTieringConfiguration, GetBucketIntelligentTieringConfiguration, DeleteBucketIntelligentTieringConfiguration | ListBucketIntelligentTieringConfigurations: 200 and empty; PutBucketIntelligentTieringConfiguration: 200; GetBucketIntelligentTieringConfiguration returns Id conformance; DeleteBucketIntelligentTieringConfiguration: 204. |
| `error.no-such-bucket` | required | GetObject, ListObjectsV2, HeadBucket | GetObject/ListObjectsV2: 404 NoSuchBucket; HeadBucket: 404 without a body. |
| `error.no-such-key` | required | GetObject, HeadObject, GetObjectTagging | GetObject: 404 NoSuchKey; HeadObject: 404 without a body. |
| `error.bucket-not-empty` | required | PutObject, DeleteBucket | DeleteBucket: 409 BucketNotEmpty. |
| `error.invalid-bucket-name` | informational | CreateBucket | CreateBucket: 400 InvalidBucketName. An SDK may refuse the name before sending. |
| `error.no-such-upload` | required | ListParts, UploadPart, AbortMultipartUpload | ListParts/UploadPart/AbortMultipartUpload: 404 NoSuchUpload. |

### Phase 2 — bucket 1 after PutBucketVersioning(Enabled)

| Check | Severity | Operations | AWS specification expectation |
| --- | --- | --- | --- |
| `versioning.gate` | informational | — | Every required phase-1 check passes before PutBucketVersioning(Enabled). Phase 2 runs either way so versioning stays diagnosable. |
| `versioning.enable` | required | PutBucketVersioning, GetBucketVersioning | PutBucketVersioning Status=Enabled: 200; GetBucketVersioning: Status Enabled. |
| `versioning.ready` | informational | PutObject, GetObject | After PutBucketVersioning(Enabled), PutObject returns a non-"null" x-amz-version-id that GetObject accepts. AWS allows a propagation delay; the suite waits up to 60 s. |
| `versioning.put.distinct-ids` | required | PutObject | PutObject in an Enabled bucket: 200 with a distinct, non-"null" x-amz-version-id per write. |
| `versioning.get.by-id` | required | GetObject, HeadObject | GetObject/HeadObject versionId=<id>: 200 with that version and x-amz-version-id; without versionId the latest version. |
| `versioning.list` | required | ListObjectVersions | ListObjectVersions: 200; versions of a key newest first; only the newest has IsLatest=true. |
| `versioning.list.pagination` | required | PutObject, ListObjectVersions | ListObjectVersions MaxKeys=1: IsTruncated with NextKeyMarker and NextVersionIdMarker; pages cover all versions exactly once. |
| `versioning.delete-marker.create` | required | DeleteObject | DeleteObject: 204 with x-amz-delete-marker: true and the marker's x-amz-version-id. |
| `versioning.delete-marker.current` | required | GetObject, HeadObject | GetObject/HeadObject without versionId: 404 with x-amz-delete-marker: true (GetObject code NoSuchKey). |
| `versioning.delete-marker.by-id` | required | GetObject, HeadObject | GetObject/HeadObject with the delete marker's versionId: 405 MethodNotAllowed with x-amz-delete-marker: true. |
| `versioning.delete-marker.list` | required | ListObjectVersions | ListObjectVersions: DeleteMarkers contains the marker with IsLatest=true; no version of the key is latest. |
| `versioning.delete-marker.remove` | required | DeleteObject, GetObject | DeleteObject versionId=<marker>: 204 with x-amz-delete-marker: true; GetObject then returns the newest version. |
| `versioning.copy.source-version` | required | CopyObject, GetObject | CopyObject with x-amz-copy-source versionId: 200; x-amz-copy-source-version-id echoes it; the destination holds that version. |
| `versioning.tagging.by-version` | required | PutObjectTagging, GetObjectTagging, DeleteObjectTagging | PutObjectTagging/GetObjectTagging/DeleteObjectTagging with versionId act on that version; other versions keep their tags. |
| `versioning.delete.permanent` | required | DeleteObject, GetObject | DeleteObject versionId=<id>: 204 with x-amz-version-id; GetObject of that version: 404 NoSuchVersion; other versions remain. |
| `versioning.get.invalid-version` | informational | GetObject | GetObject versionId=<malformed>: 400 InvalidArgument. |
| `versioning.delete-objects.versions` | required | PutObject, DeleteObjects, GetObject, ListObjectVersions | DeleteObjects: entries with VersionId delete that version (Deleted echoes VersionId); entries without VersionId create delete markers (DeleteMarker=true, DeleteMarkerVersionId). |
| `versioning.suspend` | required | PutBucketVersioning, GetBucketVersioning | PutBucketVersioning Status=Suspended: 200; GetBucketVersioning: Status Suspended. |
| `versioning.suspended.null-version` | required | PutObject, ListObjectVersions, GetObject | After suspension, PutObject stores version "null"; a second write replaces it; earlier numbered versions remain. |
| `versioning.suspended.overwrite-numbered` | required | PutObject, ListObjectVersions | In a suspended bucket PutObject on a key with numbered versions adds a "null" version and keeps the numbered ones. |
| `versioning.suspended.delete` | required | DeleteObject, ListObjectVersions, GetObject | DeleteObject without versionId: 204, x-amz-delete-marker: true, version "null"; deleting that marker restores the latest numbered version. |

### Phase 3 — Object Lock (bucket 2, plus negatives on bucket 1)

| Check | Severity | Operations | AWS specification expectation |
| --- | --- | --- | --- |
| `lock.standard-bucket.config-absent` | required | GetObjectLockConfiguration | GetObjectLockConfiguration: 404 ObjectLockConfigurationNotFoundError. |
| `lock.standard-bucket.object-calls-rejected` | required | PutObject, PutObjectRetention, PutObjectLegalHold, GetObjectRetention, HeadObject | PutObjectRetention, PutObjectLegalHold, GetObjectRetention and PutObject with lock headers on a bucket without Object Lock: 400 InvalidRequest. |
| `lock.bucket.create` | required | CreateBucket | CreateBucket x-amz-bucket-object-lock-enabled: true: 200. Endpoints without Object Lock reject it (recorded as unsupported). |
| `lock.versioning.auto` | required | GetBucketVersioning | GetBucketVersioning on an Object Lock bucket: Status Enabled without PutBucketVersioning. |
| `lock.config.get` | required | GetObjectLockConfiguration | GetObjectLockConfiguration: 200, ObjectLockEnabled Enabled, no default rule. |
| `lock.config.default-retention` | required | PutObjectLockConfiguration, GetObjectLockConfiguration | PutObjectLockConfiguration with Rule.DefaultRetention {GOVERNANCE, Days 1}: 200; Get returns it; putting ObjectLockEnabled alone clears the rule. |
| `lock.put.requires-integrity` | required | PutObject, HeadObject | PutObject with Object Lock headers and no Content-MD5/x-amz-checksum (engines send checksums only on request): 400 InvalidRequest; nothing is stored. |
| `lock.put.governance-and-hold` | required | PutObject, HeadObject | PutObject with x-amz-object-lock-mode GOVERNANCE, retain-until date and legal hold ON (plus Content-MD5): 200 with a version ID; HeadObject reports all three. |
| `lock.retention.get` | required | GetObjectRetention | GetObjectRetention: 200 with Retention.Mode GOVERNANCE and RetainUntilDate. |
| `lock.retention.extend` | required | PutObjectRetention, GetObjectRetention | PutObjectRetention with a later RetainUntilDate: 200; GetObjectRetention reports the new date. |
| `lock.retention.shorten-denied` | required | PutObjectRetention, GetObjectRetention | PutObjectRetention with an earlier date and no x-amz-bypass-governance-retention: 403 AccessDenied; the date is unchanged. |
| `lock.retention.shorten-bypass` | required | PutObjectRetention, GetObjectRetention | PutObjectRetention with x-amz-bypass-governance-retention: true: 200; the earlier date applies. |
| `lock.legal-hold.blocks-delete` | required | GetObjectLegalHold, DeleteObject, HeadObject | GetObjectLegalHold: Status ON; DeleteObject versionId with x-amz-bypass-governance-retention: 403 AccessDenied. |
| `lock.delete.marker-allowed` | required | DeleteObject, GetObject | DeleteObject without versionId: 204 with x-amz-delete-marker: true; the locked version remains readable by ID. |
| `lock.legal-hold.off` | required | PutObjectLegalHold, GetObjectLegalHold | PutObjectLegalHold Status OFF: 200; GetObjectLegalHold reports OFF. |
| `lock.governance.delete-denied` | required | DeleteObject | DeleteObject versionId without x-amz-bypass-governance-retention while retained: 403 AccessDenied. |
| `lock.governance.delete-bypass` | required | DeleteObject, HeadObject | DeleteObject versionId with x-amz-bypass-governance-retention: true: 204; the version is gone. |
| `lock.legal-hold.only` | required | PutObject, PutObjectLegalHold, DeleteObject | PutObject then PutObjectLegalHold ON: 200; deletion by version: 403 AccessDenied; after OFF: 204. |
| `lock.compliance.short` | required | PutObject, GetObjectRetention, DeleteObject, PutObjectRetention, HeadObject | PutObject COMPLIANCE: 200 with a version ID; GetObjectRetention reports COMPLIANCE and the date; DeleteObject with governance bypass, PutObjectRetention with an earlier date and PutObjectRetention to GOVERNANCE: 403 AccessDenied; after the date passes the version can be deleted. |

### Teardown

| Check | Severity | Operations | AWS specification expectation |
| --- | --- | --- | --- |
| `teardown.complete` | informational | — | Abort uploads, clear legal holds, delete every version and delete marker (bypassing GOVERNANCE), then DeleteBucket: 204. |

## Reference run: AWS emulator on the N100

Run on 2026-11-22 against the AWS emulator 1.0.504 on the N100 host (HTTPS with a self-signed CA trusted through `caBundlePath`, path-style addressing, region `us-east-1`, SigV4 authentication on), with every option enabled. Each engine created and deleted its own buckets.

| Engine | SDK | Pass | Fail | Deviation | Unsupported | Skipped | Error | Calls | Mean ms | p50 ms | p95 ms | Wall time | Phase 1 gate | Teardown |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| python | boto3 1.43.89 (botocore 1.43.89) | 162 | 1 | 5 | 2 | 0 | 0 | 425 | 8.9 | 6.3 | 13.8 | 19 s | incomplete | clean: 2 buckets, 68 versions |
| go | aws-sdk-go-v2 1.96.4 | 164 | 1 | 4 | 1 | 0 | 0 | 428 | 7.2 | 5.5 | 9.4 | 19 s | coverage met | clean: 2 buckets, 69 versions |
| rust | aws-sdk-s3 1.125.0 | 164 | 1 | 4 | 1 | 0 | 0 | 428 | 7.6 | 5.3 | 9.5 | 19 s | coverage met | clean: 2 buckets, 69 versions |
| java | aws-sdk-java-v2 2.41.29 | 161 | 1 | 7 | 1 | 0 | 0 | 428 | 11.4 | 8.4 | 17.7 | 21 s | coverage met | clean: 2 buckets, 69 versions |

170 checks ran on every engine. The checks that did not pass on every engine:

| Check | python | go | rust | java |
| --- | --- | --- | --- | --- |
| `checksum.crc32c.valid` | Unsupported | Pass | Pass | Pass |
| `list.v2.encoding-url` | Pass | Pass | Pass | Deviation |
| `list.v2.encoding-url-fields` | Pass | Pass | Pass | Deviation |
| `list.v1.encoding-url` | Pass | Pass | Pass | Deviation |
| `sse.c.copy` | Unsupported | Unsupported | Unsupported | Unsupported |
| `bucket.analytics` | Deviation | Deviation | Deviation | Deviation |
| `bucket.metrics` | Deviation | Deviation | Deviation | Deviation |
| `bucket.inventory` | Deviation | Deviation | Deviation | Deviation |
| `bucket.intelligent-tiering` | Deviation | Deviation | Deviation | Deviation |
| `versioning.gate` | Deviation | Pass | Pass | Pass |
| `lock.put.requires-integrity` | Fail | Fail | Fail | Fail |

Mean latency per operation in ms (call count in parentheses), for the most frequent operations:

| Operation | python | go | rust | java |
| --- | ---: | ---: | ---: | ---: |
| PutObject | 12.3 (80) | 7.4 (81) | 7.3 (81) | 13.9 (81) |
| GetObject | 10.4 (65) | 9.6 (66) | 12.4 (66) | 13.8 (66) |
| HeadObject | 5.9 (43) | 5.7 (44) | 5.4 (44) | 7.0 (44) |
| ListObjectsV2 | 6.2 (20) | 5.4 (20) | 5.4 (20) | 8.6 (20) |
| DeleteObject | 5.9 (16) | 5.7 (16) | 6.1 (16) | 6.6 (16) |
| CopyObject | 7.5 (13) | 5.6 (13) | 5.0 (13) | 8.1 (13) |
| GetObjectTagging | 4.8 (10) | 5.4 (10) | 5.7 (10) | 7.1 (10) |
| UploadPart | 36.6 (10) | 26.1 (10) | 29.1 (10) | 34.6 (10) |
| ListObjectVersions | 5.6 (10) | 5.3 (10) | 5.6 (10) | 8.8 (10) |
| CreateMultipartUpload | 6.5 (8) | 5.0 (8) | 6.0 (8) | 7.4 (8) |
| GetObjectRetention | 7.1 (7) | 5.3 (7) | 5.0 (7) | 6.1 (7) |
| PutObjectRetention | 7.1 (6) | 6.0 (6) | 6.0 (6) | 13.9 (6) |
| CreateBucket | 5.8 (5) | 5.5 (5) | 4.6 (5) | 8.5 (5) |
| ListObjects | 5.3 (5) | 4.4 (5) | 6.2 (5) | 7.9 (5) |

### Findings

**Endpoint (AWS emulator 1.0.504).** One required check fails on every
engine, so it is an endpoint deviation, not an SDK one:

- `lock.put.requires-integrity`: PutObject with Object Lock headers but neither
  Content-MD5 nor an `x-amz-checksum-*` header is accepted (`200`) and stored.
  AWS rejects it with `400 InvalidRequest`.

The remaining deviations are informational:

- `sse.c.copy`: CopyObject with copy-source SSE-C headers returns
  `501 NotImplemented`. SSE-C PutObject, HeadObject and GetObject (including
  the `400` without a key and `403` with the wrong key) conform.
- `bucket.analytics`, `bucket.metrics`, `bucket.inventory`,
  `bucket.intelligent-tiering`: the Put…Configuration calls return `204`;
  AWS documents `200`.
- ListBucketAnalyticsConfigurations answers with the root element
  `ListBucketAnalyticsConfigurationsResult`; AWS uses
  `ListBucketAnalyticsConfigurationResult`. ListBucketIntelligentTieringConfigurations
  answers with `ListIntelligentTieringConfigurationsResult`; AWS uses
  `ListBucketIntelligentTieringConfigurationsOutput`. boto3, Go and Java
  accept any root element; the Rust SDK rejects both responses (`sdk_decode`),
  so on Rust these two checks deviate on the list call as well.

Versioning took effect immediately (`versioning.ready` passed on the first
probe), every conditional, range, listing (including encoded Prefix and
StartAfter), multipart, presigned, versioning and Object Lock check passed, and
every teardown was clean.

**SDK differences.**

- boto3 without `awscrt` cannot compute CRC32C, so `checksum.crc32c.valid` is
  unsupported for the Python engine only, and Python's phase-1 gate is
  reported as incomplete rather than passed. The endpoint accepts and returns
  CRC32C correctly through the other three SDKs.
- AWS SDK for Java v2 decodes `EncodingType=url` listings itself, so the
  endpoint's URL encoding is not observable through Java (three listing checks
  deviate); the other SDKs show it is correct (`%2B`, `%C3%BC`, `+` for a
  space, encoded Prefix and StartAfter).
- The Rust SDK is the only one that validates XML root element names, which
  exposed the two list-configuration deviations above.
- Latency is comparable across SDKs (see the p50 column above); UploadPart
  calls are dominated by the 5 MiB payload.

**Suite defects found by the live runs and the council review** (all fixed
before this run): the Python engine's error mapping referenced a botocore
exception that is not exported; the SSE-C round trip and copy were one check,
so one `501` hid four conforming results; the URL-encoding checks decoded
Java's already-decoded keys a second time; an endpoint accepting an invalid
bucket name would not have been cleaned up; teardown could have purged a bucket
that collided with an existing one, or reported a bucket as gone when HeadBucket
failed; the phase-1 gate counted unsupported checks as covered; Go and Rust
measured the presigned-URL delay as latency; and short emulator credentials
were substring-redacted out of S3 data in the Go and Rust engines.
