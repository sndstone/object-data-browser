# Rust Raw HTTP Engine

Select **Rust Raw HTTP Engine** in the desktop engine picker. **Rust AWS SDK
Engine** is a separate entry. The raw engine ID is `rust-raw` and the packaged
binary is `s3-browser-rust-raw-engine`. It supports
S3-compatible and AWS S3 profiles with an access key, secret key and optional
session token. AWS credential providers such as SSO, shared AWS profiles and
role assumption are available through SDK engines. The raw binary is staged
for macOS, Windows and Linux and has no Android or iOS counterpart.

## Requests on the wire

The sidecar uses Tokio, Hyper 1, a pooled HTTP/1.1 client, and rustls with the
ring crypto provider. The dependency graph contains zero AWS SDK or Smithy
crates. The profile controls the connect timeout, response inactivity timeout,
connection limit and maximum attempts. TLS verifies the endpoint against
platform roots by default. A profile can add a PEM CA bundle or explicitly
disable certificate and name verification. The client reads the configured
bundle before selecting a connection pool and uses the bundle's SHA-256
digest in the pool key. Replacing the bundle changes the trust configuration
for new sidecar operations. The client does not follow HTTP redirects.
Configure the region and endpoint for the bucket being accessed.

| Behavior | Raw engine |
| --- | --- |
| Key path | Encodes UTF-8 bytes per RFC 3986 and keeps slash separators, repeated slashes and dot segments. The signed path is the path sent to S3. |
| Listings | Requests `encoding-type=url` and form-decodes keys and key markers once when the response declares URL encoding. Continuation tokens and version IDs stay opaque. |
| Copy source | Encodes the source bucket and key and adds a separately encoded `versionId` when selected or resolved. |
| Addressing | Supports path style and DNS-compatible virtual-hosted buckets. IP addresses, localhost and dotted HTTPS bucket names use path style. The Host header keeps nondefault ports. |
| Authentication | Signs the canonical query, applicable headers and SHA-256 payload hash. A session token participates in signing. Presigned GETs use query authentication and `UNSIGNED-PAYLOAD`. |
| Retries | Retries transient errors on replay-safe operations and confirmed throttling rejections where enabled. It sends potentially ambiguous version-creating mutations once. |
| HTTP errors | Parses XML error codes and handles errors embedded in HTTP 200 copy and multipart completion responses. API logs include method, path, query parameter names, status and timing. |

Signer tests use the published AWS S3 GET with Range, PUT, lifecycle, bucket
listing and presigned GET vectors. Loopback tests cover duplicate query
parameters, nondefault ports, temporary credentials, exact request targets and
connection reuse. [AWS header signing examples](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html) · [AWS presigning example](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html)

## Capabilities

| Area | Operations |
| --- | --- |
| Buckets | List, create, delete, known-bucket connection checks, and versioning enable/suspend. |
| Bucket administration | Read and write lifecycle, policy, CORS, encryption configuration and tags. Reads report the result of each section separately. |
| Objects and versions | List current objects, versions and delete markers with cursors. Inspect metadata and tags, create folder markers, copy, move, delete, and presign a current object or specific version. |
| Object Lock | Create locked buckets, read and write default retention, and read and write version retention and legal holds. The RPC accepts an explicit governance bypass for retention updates and version deletes. |
| Transfers | Stream single PUTs and multipart uploads. Bind downloads to the HEAD ETag where available, verify ranges and lengths, and publish staged files with `keepBoth` or `replace`. |
| Tools | Generate test data, drain a bucket with version-aware deletion and verify emptiness, and cancel an identified tool job. |
| Benchmarks | Start, inspect, pause, resume, stop and export the shared Rust benchmark workloads and metrics. |

The raw engine supports explicit SSE-S3 object writes. SSE-KMS, DSSE-KMS,
SSE-C and client-side encryption requests return `unsupported_feature`.
Uploads without an explicit object encryption mode leave encryption selection
to the bucket. Bucket-level encryption configuration remains independently
available for inspection or administration.

The browser applies interactive version filters to loaded rows. Direct RPC
calls also accept version filters and can specify a page size and delimiter.
For bucket-wide version browsing, a prefix filter also narrows the S3 listing.
Protection reads and writes, exact-version details, deletion and presigning use
the raw sidecar when it is selected. Other extended administration workflows
continue through the application's provider-aware adapter.

File uploads verify the source snapshot around hashing and streaming. Multipart
workers use at most 10,000 ordered parts and abort a failed upload after workers
settle. Downloads batch staging writes with 64 KiB per stream, discard staging
on errors, and publish only after the complete stream validates. Object moves
verify the destination before deleting the source. A compatible endpoint
whose unversioned conditional delete support is unproven retains the source,
and the operation reports that outcome. Delete-all uses bounded deletion
without overwriting objects to repair stale metadata.
An unconfirmed upload or copy prompts the caller to reconcile the destination
before a retry.

## Verification

```sh
cargo test --locked --manifest-path engines/rust-raw/Cargo.toml
cargo tree --locked --manifest-path engines/rust-raw/Cargo.toml --prefix none
ENGINE_CMD_JSON='["engines/rust-raw/target/debug/s3-browser-rust-raw-engine"]' \
  REQUIRE_ENGINE=1 python -m pytest tests/contract -q
```

The authenticated N100 AWS Emulator 1.0.504 run used a dedicated HTTPS listener
with its own CA. It exercised bucket CRUD, versioning suspension, versioned
reads, copies, moves and deletions, delete markers, Object Lock defaults,
governance and compliance retention, legal holds and governance bypass. Keys containing spaces, `+`,
`%` and UTF-8 text survived listing, copying and presigned reads. A 12,583,831
byte upload and ranged download matched by SHA-256. The run also verified bucket
configuration updates, folder creation, test-data generation, and version-aware
delete-all. A separate run paused a benchmark, inspected its credential-free
checkpoint, resumed in a fresh sidecar, stopped and exported CSV.

### Live HTTP and HTTPS acceptance

Run the opt-in emulator tests with `ENGINE_CMD_JSON` pointing at the raw binary
and `ODB_S3_EMULATOR_URL` pointing at a disposable, authenticated AWS Emulator.
Supply its CA certificate path through `ODB_S3_EMULATOR_CA` and its generated
credentials through `ODB_S3_EMULATOR_ACCESS_KEY` and
`ODB_S3_EMULATOR_SECRET_KEY`.

```sh
REQUIRE_ENGINE=1 python -m pytest tests/contract/test_rust_raw_emulator.py -q
```

The emulator listens on HTTPS. The tests run the same S3 workflows directly
over HTTPS and with Rust Raw sending plain HTTP to a loopback forwarder. The
forwarder keeps the signed Host and raw request target and verifies the TLS
certificate on the emulator hop. Each workflow creates its own buckets.
Coverage includes bucket settings, version and delete marker pagination, Object
Lock, conditional multipart copy, upload and download, and presigned reads.
One fault-injection case verifies that the emulator accepts an abort after
an upload part is rejected.

The same file runs loopback fault tests without emulator configuration. These
cover invalid profiles and version delete batches, refused connections, malformed
XML, bounded timeouts and retries, range and ETag mismatches, and interrupted
uploads. A rejected range yields `object_conflict`. An upload that loses its
response after sending the body yields `unknown_outcome` without replay.

## Benchmark on N100

Both optimized builds targeted the same authenticated HTTPS emulator.
Three runs per engine alternated execution order. Each run used 16 workers,
a pool setting of 16, 32 KiB objects, SHA-256 read validation, reduced logging
and multi-object delete. The configured 40/40/20 custom mix produced the same
732 PUTs, 960 GETs and 708 deleted objects per run. The throughput metric
counts deleted objects in a batch, so it measures operations per second.

| Engine | Median operations/s | Median p95 | Throughput range |
| --- | ---: | ---: | ---: |
| Rust Raw HTTP | 1,155.0 | 22.4 ms | 1,137.7–1,316.9 |
| Rust AWS SDK | 914.1 | 39.8 ms | 873.1–1,054.4 |

On this workload the raw engine delivered 26% higher median throughput and
44% lower median p95 latency. All 960 reads in each run passed SHA-256
validation. Both engines completed all runs with zero errors or retries and
produced CSV and JSON exports. The numbers characterize this endpoint,
connection and workload.

### Browser and transfer performance

Four interleaved release-build runs per variant compared the optimizations
with the previous raw engine. Values are medians across runs.

| Workload | Metric | Previous | Optimized |
| --- | --- | ---: | ---: |
| N100 HTTPS, 120 sequential listings using a custom CA | Listing p50 | 23.4 ms | 5.8 ms |
| Same HTTPS workload | Listing p95 | 31.7 ms | 10.6 ms |
| Loopback, 120 listings with 1,000 entries per page | Listing p50 | 3.06 ms | 2.88 ms |
| Loopback, one ranged and one single-stream 128 MiB download per run | Raw sidecar CPU time per run | 0.305 s | 0.205 s |
| Same loopback transfer workload | Ranged throughput | 807 MiB/s | 893 MiB/s |

Every transfer was verified by SHA-256. The 64 KiB write buffer used less
memory than the 256 KiB candidate in the loopback test. Median peak resident
memory was about 14 MiB for both the previous and optimized builds. N100 transfer
rates varied between runs. The separate 3,600-operation N100 mixed workload
showed similar throughput and latency, with 1,440 verified reads and zero
errors or retries in each run.
