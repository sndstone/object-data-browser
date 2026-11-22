# Transport Contract

## Desktop

- Request/response: UTF-8 line-delimited JSON on stdin/stdout, independent of the host locale
- Progress/events: line-delimited JSON on stdout with `event`
- Transfer progress events use `{"event":"transferProgress","job":{...}}` with the same transfer job shape returned by the final response
- Fatal diagnostics: stderr
- Process contract: exit code `0` on graceful shutdown, non-zero on engine failure

## Request limits (desktop)

- One input frame (one request line) is at most 64 MiB in every engine. An
  oversized frame is discarded up to its newline and answered with a structured
  `invalid_request` error whose `requestId` is `null`; the engine keeps serving
  later requests.
- Each engine runs a bounded number of requests at once and holds a bounded
  number waiting to start. A request beyond that bound is answered immediately
  with a structured `overloaded` error correlated by its `requestId`. It was not
  started, so the host may retry it later. The Flutter host sends one ordinary
  request per engine process at a time and never reaches the bound in normal use.
- Transfer and benchmark control or status requests (`pauseTransfer`,
  `resumeTransfer`, `cancelTransfer`, `cancelToolExecution`,
  `getBenchmarkStatus`, `pauseBenchmark`, `resumeBenchmark`, `stopBenchmark`)
  bypass the waiting bound in engines that support them, so a saturated engine
  can still be controlled.

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

Engines advertising interactive transfer controls must register a job before
emitting its first `transferProgress` event, so that the event's job ID is
immediately usable by pause, resume, and cancel requests. A cancelled download's
terminal response follows response-body closure and staged-file cleanup.

The Flutter host owns per-action cancellation scopes. Read cancellation stops
only the owning request and discards late results. Desktop mutation cancellation
may terminate its exclusively owned sidecar; it then records `unknown` because
remote writes already accepted cannot be rolled back or presumed absent. Native
bridges use request IDs and cancellation tokens/tasks. Completed output remains
visible. An unknown mutation must not be automatically retried.

## Object encryption (optional)

Every field in this section is optional and additive. A request that omits them
behaves exactly as before: no encryption header is sent and the bucket, account
or container default applies. The host sends a mode only after the engine has
advertised its capability key. Nothing here is enabled by default.

### The `encryption` object

```json
{
  "mode": "bucketDefault | sse-s3 | sse-kms | dsse-kms | sse-c | azure-scope | azure-cpk",
  "kmsKeyId": "optional; sse-kms and dsse-kms; key ID, ARN or alias",
  "kmsEncryptionContext": {"optional": "sse-kms and dsse-kms; string map"},
  "bucketKeyEnabled": "optional boolean; sse-kms only",
  "customerKey": "sse-c and azure-cpk; base64 of exactly 32 bytes",
  "encryptionScope": "azure-scope; scope name"
}
```

- `bucketDefault`, or an absent or null object, sends no encryption header.
- `sse-s3` sends `x-amz-server-side-encryption: AES256`.
- `sse-kms` sends `aws:kms` plus the optional key ID, the encryption context
  (base64 of the UTF-8 JSON map) and the bucket-key flag. `dsse-kms` sends
  `aws:kms:dsse`; it never sends the bucket-key flag.
- `sse-c` sends the three `x-amz-server-side-encryption-customer-*` headers
  (algorithm `AES256`, key, key MD5) on every request that touches the object,
  including each `UploadPart`.
- `azure-scope` sends `x-ms-encryption-scope`. `azure-cpk` sends
  `x-ms-encryption-key`, `x-ms-encryption-key-sha256` and
  `x-ms-encryption-algorithm: AES256`.
- S3 modes are valid only for S3 profiles and Azure modes only for Azure
  profiles. Any other combination, an unknown mode, a field that does not belong
  to the mode, or a customer key that does not decode to exactly 32 bytes is
  `invalid_config`.
- `sse-c` and `azure-cpk` require an HTTPS endpoint. Engines reject them with
  `invalid_config` on plain HTTP unless the endpoint host is loopback
  (`localhost`, `127.0.0.0/8`, `::1`), which exists for local test fixtures.

### Where it is accepted

| Method | Field | Effect |
| --- | --- | --- |
| `startUpload` | `encryption` | Applied to every file in the request: single PUT, multipart create, and each part where the mode requires it. Azure: Put Blob, Put Block and Put Block List. |
| `createFolder` | `encryption` | Applied to the folder-marker PUT. |
| `runPutTestData` | `encryption` | Applied to every generated object. |
| `copyObject`, `moveObject` | `encryption` | Encryption of the destination object. Absent keeps each engine's existing copy behaviour. |
| `copyObject`, `moveObject` | `sourceEncryption` | `sse-c` or `azure-cpk` only: the key needed to read the source. S3 sends the `x-amz-copy-source-server-side-encryption-customer-*` headers, including on `UploadPartCopy`. Azure customer-provided-key sources cannot use asynchronous Copy Blob and must use the engine's relay path or fail with `unsupported_feature`. |
| `startDownload`, `getObjectDetails` | `encryption` | `sse-c` or `azure-cpk` only: the key needed to read the object. Other modes are ignored for reads. |
| `generatePresignedUrl` | `encryption` | `sse-c` and `azure-cpk` return `unsupported_feature`: a link that needs secret request headers is not a shareable link. Other modes are ignored. |

Benchmarks do not take `encryption` in contract version 1.0.

### `getObjectDetails` response

The response gains an optional `encryption` object, omitted when the provider
reports nothing:

```json
{
  "mode": "sse-s3 | sse-kms | dsse-kms | sse-c | azure-scope | azure-cpk | provider",
  "kmsKeyId": "when reported",
  "bucketKeyEnabled": "when reported",
  "customerKeyMd5": "sse-c: base64 MD5 reported by S3",
  "customerKeySha256": "azure-cpk: base64 SHA-256 reported by Azure",
  "encryptionScope": "azure-scope",
  "serverEncrypted": "Azure x-ms-server-encrypted, when reported"
}
```

`provider` means the provider reports encryption at rest with its own managed
key and no per-object setting (Azure without a scope or customer key).

### Capabilities

`getCapabilities` reports one item per mode the engine implements:
`object.encryption.sse-s3`, `object.encryption.sse-kms`,
`object.encryption.dsse-kms`, `object.encryption.sse-c`,
`object.encryption.azure-scope` and `object.encryption.azure-cpk`. An engine
without Azure support reports the Azure keys as `unsupported`. `supported` means
the engine sends the headers; whether an endpoint honours them is learned from
its responses.

### Errors

Failures keep their existing codes. Where the provider response makes the cause
clear, `details.encryptionHint` is one of `sse_c_key_required`,
`sse_c_key_mismatch`, `sse_c_blocked`, `kms_access_denied`,
`kms_key_unavailable`, `encryption_required_by_policy` or
`unsupported_by_endpoint`. The hint is best effort and may be absent. An engine
never retries a denied write with a different encryption mode.

### Secrets

`customerKey` is a secret for the lifetime of one request. Engines must redact
it, and the request headers that carry it
(`x-amz-server-side-encryption-customer-key`,
`x-amz-copy-source-server-side-encryption-customer-key`, `x-ms-encryption-key`),
from every log, trace, diagnostic and error. They must never write it to a
recovery manifest, checkpoint, benchmark file or response. Resumable workflows
store at most the key's fingerprint and receive the key again on resume.

### Bucket default encryption

`putBucketEncryption` and `getBucketAdminState` must round-trip every rule
field, including `BlockedEncryptionTypes`, so saving an unrelated change never
alters whether the bucket blocks SSE-C.

## Client-side encryption (optional)

Client-side encryption stores only ciphertext with the provider. Objects use the
age v1 file format (https://age-encryption.org/v1) unmodified, so any object can
be decrypted with the stock `age` tool and the vault identity. The host owns
identities, recipients, the age header and the wrapped file key. An engine
implements only the payload cipher, and only when the request carries
`clientEncryption`. Nothing here is enabled by default.

### The `clientEncryption` object

Upload (`startUpload`, exactly one file in the request):

```json
{
  "format": "age-v1",
  "header": "base64 of the complete age header, through the newline after the MAC line",
  "payloadNonce": "base64 of 16 random bytes chosen by the host for this upload",
  "fileKey": "base64 of the 16-byte age file key"
}
```

Download (`startDownload`, exactly one key in the request):

```json
{
  "format": "age-v1",
  "headerLength": 200,
  "fileKey": "base64 of the 16-byte age file key the host unwrapped from the header",
  "fileName": "optional: the name to publish the file under"
}
```

`fileName` is optional. The host sends it when the object's name is encrypted
(see "Name encryption"), because the stored base name is then meaningless. It
is one file name, never a path: an empty value, `.`, `..`, or a value containing
`/`, `\` or a NUL character is `invalid_config`. When present it replaces the
object's base name as the published file name, and the engine applies the same
platform sanitising and collision handling it applies to a name taken from a
key. `fileName` is a name the user chose to hide from the bucket. It never
appears in a storage request or a URL, and the `fileName` field is redacted
wherever the engine records or echoes its request (traces, manifests,
checkpoints, resume records), like `fileKey`. Its value is not scrubbed from
text: the published destination path in the job output names the file.

A request with more than one file or key, an unknown format, a file key that is
not 16 bytes, a nonce that is not 16 bytes, or a header longer than 65,536 bytes
is `invalid_config`. `clientEncryption` may be combined with `encryption`
(provider-side); the provider then encrypts the ciphertext again.

### Stored object layout

`object = header || payloadNonce || chunk[0] || chunk[1] || …`

- Payload key: `HKDF-SHA-256(ikm = fileKey, salt = payloadNonce, info = "payload")`, 32 bytes.
- The plaintext is split into 65,536-byte chunks. Chunk `i` is sealed with
  ChaCha20-Poly1305 under the payload key, with no associated data and the
  12-byte nonce `i` as an 11-byte big-endian counter followed by one flag byte:
  `0x01` on the final chunk, `0x00` otherwise. Each sealed chunk is its plaintext
  plus a 16-byte tag.
- The final chunk may be shorter than 65,536 bytes. It is empty only when the
  plaintext is empty, in which case the payload is a single sealed empty chunk.
- With header length `H` and plaintext length `P`, the object length is
  `C = H + 16 + P + 16 × max(1, ceil(P / 65536))`.

`contracts/vectors/age-stream.json` holds vectors (header, file key, nonce,
plaintext rule, object length and SHA-256). Every engine that advertises the
capability must reproduce each object byte for byte and decrypt it back.

### Upload rules

- The multipart threshold, part size and part count apply to the ciphertext
  length `C`, not to `P`. Parts are uniform ranges of the ciphertext, so every
  S3 limit holds unchanged. The host computes `multipartChunkMiB` from `C`.
- A part worker maps its ciphertext range to the chunks it overlaps, reads only
  those plaintext chunks from the source, and seals them. Workers stay bounded
  and never hold more than a few chunks in memory.
- A retried part must seal identical plaintext, because a chunk nonce is reused
  on retry. Engines keep their source-identity checks and fail the upload,
  aborting the multipart upload, if the source changed.
- The engine never reuses a file key or nonce for a different file, never logs
  or persists `fileKey`, and never writes it to a manifest or checkpoint.

### Download rules

- The engine reads the object length `C` from HEAD, derives `P`, and rejects a
  length that no plaintext can produce.
- It reads `payloadNonce` from bytes `[H, H + 16)`, then fetches ciphertext in
  ranges aligned to sealed-chunk boundaries (`65,552` bytes each from offset
  `H + 16`).
- Every chunk is authenticated with its index and final flag before its
  plaintext is written to the staged file. The last chunk must carry the final
  flag and no chunk before it may.
- A chunk that fails authentication fails the download with code
  `decryption_failed` and `details.chunk`. The staged file is discarded and
  nothing is published. An engine never publishes unauthenticated plaintext.
- Existing range validation, `If-Match` binding and atomic publication apply to
  the ciphertext requests unchanged. The published file holds the plaintext.
- The published file name is `clientEncryption.fileName` when the host sent
  one. Otherwise it is the object's base name with one trailing `.age` removed,
  when it has one and the remainder is not empty. Collision handling
  (`keepBoth`, `replace`) applies to that name.

### Capability

`getCapabilities` reports `object.clientEncryption` with `formats: ["age-v1"]`
when the engine implements this section. The host routes a client-encrypted
transfer only to an engine that reports it.

### Name encryption

Optional, per vault rule, and off by default. It is done entirely by the host:
an engine only ever sees stored keys, plus `fileName` on a download. With it
off, stored keys are exactly as before (`<name>.age`).

A vault rule has a `policy` (`default` or `strict`) and, under `default`, an
`encryptNames` switch:

| Rule | New uploads are stored as |
| --- | --- |
| `default`, names off | `<prefix><path>.age` (unchanged) |
| `default`, names on | every path segment below the destination prefix replaced by its deterministic token; the last one followed by `.age` |
| `strict` | one random token for the whole relative path, followed by `.age`, directly in the destination prefix |

The destination prefix is the stored prefix the user is uploading into, or the
rule prefix when that is longer. It is kept byte for byte; only the segments
below it are encoded. A rule prefix is never encrypted.

Keys. Let `s` be the 32 secret bytes of the rule's age X25519 identity (the
data part of `AGE-SECRET-KEY-1…`):

- `K_det = HKDF-SHA-256(ikm = s, salt = none, info = "object-data-browser/vault-names/v1/deterministic")`, 32 bytes.
- `K_rnd = HKDF-SHA-256(ikm = s, salt = none, info = "object-data-browser/vault-names/v1/random")`, 32 bytes.

Both are secrets with the same handling rules as the identity. They are derived
while the key file is unlocked and wiped when it locks.

Deterministic token, for one path segment `p` (UTF-8, not empty, no `/`, not
`.` or `..`):

`token = base64url-nopad( 0x01 || AES-SIV(K_det, plaintext = p, no associated data) )`

AES-SIV is RFC 5297 with a 256-bit key (the form its own test vectors use:
AES-128 for S2V and AES-128 for CTR); its output is the 16-byte synthetic IV
followed by the ciphertext. The same segment always gives the same token, so
`ListObjectsV2` with a prefix and a delimiter keeps working: `photos/2024/` is
always `token(photos)/token(2024)/`.

Random token, for one relative path `r` (UTF-8, segments separated by `/`, no
empty, `.` or `..` segment, no leading or trailing `/`):

- `salt` = 24 fresh random bytes for this upload. A retry draws a new salt.
- `K = HKDF-SHA-256(ikm = K_rnd, salt = salt, info = "name")`, 32 bytes. This
  key is used for exactly one name.
- `padded = r || 0x80 || 0x00…`, the shortest length that is a multiple of 16.
- `token = base64url-nopad( 0x02 || salt || ChaCha20-Poly1305(K, nonce = 12 zero bytes, padded, no associated data) )`

Reading. For a stored key under a vault rule, the host takes each segment below
the rule prefix (the last one without its `.age`) and tries to open it: version
`0x01` with `K_det`, version `0x02` with `K_rnd`, with the key of the rule's
identity first and then every other identity in the unlocked key file. A segment
that does not decode, does not authenticate, or decodes to a name that breaks
the rules above is shown as it is stored. This is independent of the rule's
current settings, so a bucket may hold plaintext names, `.age` names and both
kinds of token side by side. A random token below a deterministic folder shows
its whole relative path as the name.

Limits. A stored key longer than 1,024 UTF-8 bytes is refused before upload.
A deterministic token is `ceil((17 + n) × 4 / 3)` characters for an `n`-byte
segment; a random token is `ceil((41 + 16 × ceil((n + 1) / 16)) × 4 / 3)`.
Segments of at most 170 bytes and strict paths of at most 143 bytes stay within
the 255-character segment limit some S3-compatible servers apply.

What is still visible to someone who can list the bucket: object sizes, counts
and timestamps in both modes. Deterministic names also reveal the folder
structure, the approximate length of each name, and which names are equal.
Random names reveal the path length rounded up to 16 bytes and nothing else.
Under `strict` an upload never replaces an earlier object with the same name;
both are kept.

`contracts/vectors/vault-names.json` holds vectors produced with an independent
implementation (`generate_vault_names.py`): tokens that must be reproduced byte
for byte, random tokens that must open to the given path, and tokens that must
be rejected. Names can be recovered without this app from the identity alone:

```python
from base64 import urlsafe_b64decode
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESSIV, ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

def hkdf(ikm, salt, info, length):
    return HKDF(hashes.SHA256(), length, salt, info).derive(ikm)

def open_name(secret: bytes, token: str) -> str:   # secret: the 32 identity bytes
    raw = urlsafe_b64decode(token + "=" * (-len(token) % 4))
    if raw[0] == 1:
        key = hkdf(secret, None, b"object-data-browser/vault-names/v1/deterministic", 32)
        return AESSIV(key).decrypt(raw[1:], None).decode()
    key = hkdf(hkdf(secret, None, b"object-data-browser/vault-names/v1/random", 32), raw[1:25], b"name", 32)
    padded = ChaCha20Poly1305(key).decrypt(bytes(12), raw[25:], None)
    return padded.rstrip(b"\x00")[:-1].decode()
```

## Google Cloud Storage profiles (native JSON API)

A profile with `endpointType: "googleCloudStorage"` uses the Cloud Storage JSON
API, not the S3-compatible XML API. Python and Go implement it. Rust and Java
return `unsupported_feature` for the profile, as they do for Azure. Google
Cloud Storage reached through HMAC keys remains an ordinary `s3Compatible`
profile.

### Profile fields

- `secretKey` holds the complete service-account key file (the JSON document
  with `client_email`, `private_key`, `project_id` and `token_uri`). It is a
  credential and is stored only through `ProfileSecretStore`.
- `accessKey` holds the service-account email for display. Engines read the
  email from the key file and ignore a mismatch.
- `endpointUrl` empty means `https://storage.googleapis.com`. A custom URL is
  for emulators and private endpoints.
- `region` is used only as the location for new buckets and may be empty.
- The project for bucket listing and creation is the key file's `project_id`.

### Authentication

Engines mint an OAuth 2.0 access token with the JWT bearer grant: an RS256 JWT
(`iss` = service-account email, `scope` =
`https://www.googleapis.com/auth/devstorage.read_write`, `aud` = the key file's
`token_uri`, lifetime at most one hour) posted to `token_uri`. Tokens are cached
in memory until shortly before expiry and never written to disk, logs or
responses. The private key, tokens, resumable session URIs and signed URLs are
secrets for redaction purposes.

### Mapping to contract methods

| Method | Cloud Storage behaviour |
| --- | --- |
| `testProfile`, `listBuckets` | `buckets.list` for the key file's project; `knownBucket` limits the check to one bucket. |
| `createBucket`, `deleteBucket` | `buckets.insert` (location from `region`), `buckets.delete`. |
| `setBucketVersioning`, `getBucketAdminState` | `versioning.enabled` on the bucket. Lifecycle, policy, CORS, default encryption and tagging methods return `unsupported_feature`. |
| `listObjects` | `objects.list` with `prefix`, `delimiter` and `pageToken`; at most 1,000 per page; a page may be empty while a cursor remains. |
| `listObjectVersions` | `objects.list` with `versions=true`. The version ID is the generation number as a string. Cloud Storage has no delete markers; a noncurrent generation is reported as a non-latest version. |
| `getObjectDetails` | `objects.get`; `versionId` selects a generation. Custom metadata maps to `metadata`. |
| `startUpload` | Simple media upload below the multipart threshold. Above it, one resumable session with sequential chunks whose size is the configured part size rounded up to a multiple of 256 KiB. An interrupted chunk is resumed from the offset the service reports. A failed upload cancels its session. |
| `startDownload` | `alt=media` with `Range`, pinned to the generation read from metadata, using the engine's existing ranged workers, validation and atomic publication. |
| `deleteObjects`, `deleteObjectVersions` | `objects.delete`, with `generation` for an exact version. |
| `copyObject`, `moveObject` | `objects.rewrite`, repeated with `rewriteToken` until done. A move deletes the source generation that was copied, conditioned on that generation. `conflictPolicy` `fail` or `skip` checks the destination first and adds `ifGenerationMatch=0` to the rewrite, so an existing object is never overwritten; `replace` is the default. |
| `createFolder` | A zero-byte object whose name ends with `/`. |
| `generatePresignedUrl` | A V4 signed URL (`GOOG4-RSA-SHA256`) signed with the key file's private key; expiry is capped at seven days. |
| Tools, benchmarks, `storageAction` | `unsupported_feature` unless the engine states otherwise in its capabilities. |

Provider errors map to the existing codes: 401 and 403 to `auth_failed`, 404 to
the engine's existing not-found handling, 409 and 412 to `object_conflict`, 429
to `throttled`, and timeouts to `timeout`. `details` carries `provider:
"gcs"`, the HTTP status and the service's reason string.

Object encryption for Cloud Storage profiles is not part of contract version
1.0; the `encryption` object is rejected with `invalid_config` on these
profiles. Client-side encryption applies unchanged, because it operates on the
bytes the engine uploads and downloads.

## S3 API conformance (desktop only)

The desktop host can verify how an S3 endpoint and an SDK behave against the
AWS S3 API specification. The test catalog, bucket staging, expectations,
cross-engine comparison and teardown live once in the Flutter host
(`apps/flutter_app/lib/conformance/`). An engine contributes exactly one
primitive, `s3ConformanceOp`, which performs **one** S3 API operation through
its real SDK and reports what the service returned. Any desktop engine,
including a future raw-HTTP engine, joins the suite by implementing this
primitive and advertising its capability. Mobile adapters do not implement it
and the mobile UI never offers the feature.

### Capability

`getCapabilities` for an `s3Compatible` or `awsS3` profile reports:

```json
{
  "key": "conformance.s3",
  "label": "S3 API conformance",
  "state": "supported",
  "version": 1,
  "sdk": "boto3 1.43.89",
  "client": {"maxAttempts": 1, "requestChecksumCalculation": "when_required",
             "responseChecksumValidation": "when_required"},
  "ops": ["CreateBucket", "HeadBucket", "..."]
}
```

`ops` lists every operation from the table below that the engine implements.
An engine whose SDK URL-decodes `EncodingType=url` listing responses before
returning them (AWS SDK for Java v2) adds `"urlEncodedListings": "decodedBySdk"`
to `client`; the host then cannot inspect the wire encoding and reports that
instead of decoding twice.
Azure Blob and Google Cloud Storage profiles report the key as `unsupported`.

### Request

```json
{
  "method": "s3ConformanceOp",
  "params": {
    "profile": {"...": "endpoint profile, as for every other method"},
    "op": "PutObject",
    "input": {"Bucket": "b", "Key": "k", "ContentType": "text/plain"},
    "body": {"generate": {"size": 1024, "seed": 7}},
    "encryption": {"mode": "sse-c", "customerKey": "<base64 32 bytes>"},
    "sourceEncryption": {"mode": "sse-c", "customerKey": "<base64 32 bytes>"}
  }
}
```

- `op` is an AWS S3 API operation name, or the pseudo-operation
  `PresignedRequest`. An operation outside the engine's allowlist is an RPC
  error `unsupported_feature`; the host records it as *unsupported by this
  engine*, never as an endpoint failure.
- `input` uses AWS API shape member names (`Bucket`, `Key`, `VersionId`,
  `IfMatch`, `Metadata`, `Tagging`, `CreateBucketConfiguration`, ...) with JSON
  types: strings, numbers, booleans, objects for structures, arrays for lists,
  objects of strings for maps. Timestamps are ISO-8601 UTC strings; each SDK
  serialises them in the operation's wire format (HTTP date for
  `If-Modified-Since`, ISO-8601 for `RetainUntilDate`).
- `CopySource` is always the structure `{"Bucket", "Key", "VersionId"?}` and the
  engine lets its SDK encode it exactly once (`UploadPartCopy` too). The key may
  contain spaces, `+`, `%`, Unicode and `/`.
- `body` (only `PutObject`, `UploadPart`, `PresignedRequest` with `PUT`) is one of
  `{"generate": {"size": n, "seed": s}}` (n ≤ 16 MiB, 0 ≤ s ≤ 65535),
  `{"base64": "..."}` (decoded ≤ 1 MiB) or `{"text": "..."}` (UTF-8, ≤ 64 KiB).
  Generated byte *i* (0-based, 64-bit arithmetic) is
  `(s * 131 + i * 7 + (i >> 10)) & 0xFF`. Absent body means zero bytes.
- SSE-C keys travel only in `encryption` / `sourceEncryption` with mode `sse-c`,
  reusing the redaction paths of "Object encryption". The engine applies the
  algorithm, key and key MD5 to the operation (`sourceEncryption` to the
  copy-source headers of `CopyObject` and `UploadPartCopy`). The HTTPS-or-
  loopback rule applies and violations are `invalid_config`.
  `SSECustomer*` and `CopySourceSSECustomer*` members inside `input` are
  rejected with `invalid_request`. Other encryption (`ServerSideEncryption`,
  `SSEKMSKeyId`, `BucketKeyEnabled`) is ordinary `input`.
- The engine uses a dedicated client for these calls: the profile's endpoint,
  region, addressing style, TLS settings and credentials, **one attempt** (no
  SDK retries), and `when_required` request checksum calculation and response
  checksum validation for every endpoint type, so checksums are present only
  when the test asks for them. Redirects are not followed.

### Result

Every response from the service, including 3xx, 4xx and 5xx, is a successful RPC
result. RPC errors are reserved for an operation the engine does not implement
(`unsupported_feature`), an invalid profile or request (`invalid_config`,
`invalid_request`) and engine failures.

```json
{
  "op": "GetObject",
  "outcome": "service",
  "httpStatus": 206,
  "errorCode": null,
  "errorMessage": null,
  "headers": {"etag": "\"...\"", "content-range": "bytes 2-5/16"},
  "output": {"Body": {"length": 4, "sha256": "<hex>"}},
  "latencyMs": 3.41,
  "attempts": 1,
  "requestId": "..."
}
```

- `outcome` is `service` when an HTTP response was received,
  `sdk_validation` when the SDK refused the input before sending,
  `sdk_decode` when a response arrived but the SDK could not parse it
  (`httpStatus` is set when known), and `transport` for connection, TLS or
  timeout failures. Only `service` outcomes are compared with the specification.
- `errorCode` is the S3 error code the SDK parsed, or `null`. HEAD and `304`
  responses have no body; the code an SDK synthesises for them (`404`,
  `NotFound`, `NotModified`) is reported but the host compares only the status.
  `errorMessage` is at most 256 characters, redacted like every engine error.
- `headers` holds response headers with lower-case names; repeated values are
  joined with `, `. Only these names are reported: `etag`, `content-type`,
  `content-length`, `content-range`, `content-encoding`, `content-disposition`,
  `content-language`, `cache-control`, `expires`, `last-modified`, `date`,
  `accept-ranges`, `location`, `x-amz-request-id`, `x-amz-version-id`,
  `x-amz-delete-marker`, `x-amz-tagging-count`, `x-amz-mp-parts-count`,
  `x-amz-storage-class`, `x-amz-expiration`, `x-amz-replication-status`,
  `x-amz-copy-source-version-id`, `x-amz-bucket-region`,
  `x-amz-website-redirect-location`, `x-amz-missing-meta`, `x-amz-restore`,
  `x-amz-abort-date`, `x-amz-abort-rule-id`, `x-amz-server-side-encryption`,
  `x-amz-server-side-encryption-aws-kms-key-id`,
  `x-amz-server-side-encryption-bucket-key-enabled`,
  `x-amz-server-side-encryption-customer-algorithm`,
  `x-amz-object-lock-mode`, `x-amz-object-lock-retain-until-date`,
  `x-amz-object-lock-legal-hold`, `access-control-allow-origin`,
  `access-control-allow-methods`, `access-control-expose-headers`, plus every
  name starting with `x-amz-meta-` (at most 16) or `x-amz-checksum-`. At most 48
  headers; each value is truncated to 512 characters. `Authorization`,
  `x-amz-security-token`, cookies and SSE-C key material are never reported.
- `output` holds the SDK's parsed output under AWS member names, with absent
  members omitted (`null` is never sent). An empty list and an absent list are
  equivalent. Timestamps are ISO-8601 UTC strings. A literal version ID `"null"`
  is preserved as the string `"null"`. A streaming body is replaced by
  `{"length": n, "sha256": "<hex>"}`; engines read at most 32 MiB and add
  `"truncated": true` beyond that. Engines may report more members than the
  minimum projection below, and the host reads only that projection. Values that
  S3 returns in headers (ETag, VersionId, checksums, lock headers) are read from
  `headers`.
- `latencyMs` is monotonic wall time from the SDK invocation until the response,
  including a streamed body, was consumed and closed. For `PresignedRequest` it
  covers only the HTTP request sent after `DelayMs`; signing time is
  `Presign.PresignMs`. `attempts` is the number of HTTP sends observed (1 when
  the SDK honoured the single-attempt setting).
- Engines never return or log request URLs with query strings, presigned URLs,
  `Authorization`, session tokens or customer keys, including inside transport
  error text. Pagination cursors (`ContinuationToken`,
  `NextContinuationToken`, markers, upload IDs) are opaque data, not secrets,
  and are returned unchanged.

### Minimum output projection

| Operation | `output` members the host reads |
| --- | --- |
| `ListBuckets` | `Buckets[{Name, CreationDate}]`, `ContinuationToken` |
| `GetBucketLocation` | `LocationConstraint` |
| `GetBucketVersioning` | `Status`, `MFADelete` |
| `GetBucketTagging`, `GetObjectTagging` | `TagSet[{Key, Value}]` |
| `GetBucketCors` | `CORSRules[{ID, AllowedHeaders[], AllowedMethods[], AllowedOrigins[], ExposeHeaders[], MaxAgeSeconds}]` |
| `GetBucketLifecycleConfiguration` | `Rules[{ID, Status, Filter{Prefix}, Expiration{Days}, AbortIncompleteMultipartUpload{DaysAfterInitiation}}]` |
| `GetBucketPolicy` | `Policy` |
| `GetBucketPolicyStatus` | `PolicyStatus{IsPublic}` |
| `GetBucketEncryption` | `ServerSideEncryptionConfiguration{Rules[{ApplyServerSideEncryptionByDefault{SSEAlgorithm, KMSMasterKeyID}, BucketKeyEnabled}]}` |
| `GetPublicAccessBlock` | `PublicAccessBlockConfiguration{BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets}` |
| `GetBucketOwnershipControls` | `OwnershipControls{Rules[{ObjectOwnership}]}` |
| `GetBucketAcl`, `GetObjectAcl` | `Owner{ID, DisplayName}`, `Grants[{Grantee{Type, ID, DisplayName, URI}, Permission}]` |
| `GetBucketAccelerateConfiguration` | `Status` |
| `GetBucketRequestPayment` | `Payer` |
| `GetBucketLogging` | `LoggingEnabled{TargetBucket, TargetPrefix}` |
| `GetBucketWebsite` | `IndexDocument{Suffix}`, `ErrorDocument{Key}` |
| `GetBucketNotificationConfiguration` | `TopicConfigurations[{Id}]`, `QueueConfigurations[{Id}]`, `LambdaFunctionConfigurations[{Id}]` |
| `GetBucketReplication` | `ReplicationConfiguration{Role, Rules[{ID, Status}]}` |
| `ListBucketAnalyticsConfigurations`, `ListBucketMetricsConfigurations`, `ListBucketInventoryConfigurations`, `ListBucketIntelligentTieringConfigurations` | `IsTruncated`, `NextContinuationToken`, and `AnalyticsConfigurationList`, `MetricsConfigurationList`, `InventoryConfigurationList` or `IntelligentTieringConfigurationList` as `[{Id}]` |
| `GetBucketAnalyticsConfiguration`, `GetBucketMetricsConfiguration`, `GetBucketInventoryConfiguration`, `GetBucketIntelligentTieringConfiguration` | `AnalyticsConfiguration{Id}`, `MetricsConfiguration{Id}`, `InventoryConfiguration{Id, IsEnabled}`, `IntelligentTieringConfiguration{Id, Status}` |
| `GetObjectLockConfiguration` | `ObjectLockConfiguration{ObjectLockEnabled, Rule{DefaultRetention{Mode, Days, Years}}}` |
| `GetObjectRetention` | `Retention{Mode, RetainUntilDate}` |
| `GetObjectLegalHold` | `LegalHold{Status}` |
| `GetObject` | `Body{length, sha256}` |
| `CopyObject` | `CopyObjectResult{ETag, LastModified}` |
| `UploadPartCopy` | `CopyPartResult{ETag, LastModified}` |
| `GetObjectAttributes` | `ETag`, `ObjectSize`, `StorageClass`, `Checksum{ChecksumCRC32, ChecksumCRC32C, ChecksumSHA1, ChecksumSHA256, ChecksumType}`, `ObjectParts{TotalPartsCount}` |
| `ListObjects` | `IsTruncated`, `Marker`, `NextMarker`, `Prefix`, `Delimiter`, `MaxKeys`, `EncodingType`, `Contents[{Key, ETag, Size, LastModified, StorageClass}]`, `CommonPrefixes[{Prefix}]` |
| `ListObjectsV2` | `IsTruncated`, `KeyCount`, `MaxKeys`, `Prefix`, `Delimiter`, `StartAfter`, `EncodingType`, `ContinuationToken`, `NextContinuationToken`, `Contents[{Key, ETag, Size, LastModified, StorageClass}]`, `CommonPrefixes[{Prefix}]` |
| `ListObjectVersions` | `IsTruncated`, `KeyMarker`, `VersionIdMarker`, `NextKeyMarker`, `NextVersionIdMarker`, `Prefix`, `Delimiter`, `MaxKeys`, `EncodingType`, `Versions[{Key, VersionId, IsLatest, ETag, Size, LastModified}]`, `DeleteMarkers[{Key, VersionId, IsLatest, LastModified}]`, `CommonPrefixes[{Prefix}]` |
| `DeleteObjects` | `Deleted[{Key, VersionId, DeleteMarker, DeleteMarkerVersionId}]`, `Errors[{Key, VersionId, Code, Message}]` |
| `CreateMultipartUpload` | `Bucket`, `Key`, `UploadId` |
| `ListParts` | `UploadId`, `PartNumberMarker`, `NextPartNumberMarker`, `MaxParts`, `IsTruncated`, `Parts[{PartNumber, ETag, Size}]` |
| `ListMultipartUploads` | `KeyMarker`, `UploadIdMarker`, `NextKeyMarker`, `NextUploadIdMarker`, `Prefix`, `MaxUploads`, `IsTruncated`, `Uploads[{Key, UploadId, Initiated}]` |
| `CompleteMultipartUpload` | `Location`, `Bucket`, `Key`, `ETag` |
| `PresignedRequest` | `Body{length, sha256}`, `Presign{Method, Scheme, Host, QueryKeys[], PresignMs}` |

### Operations and input members

The host sends only these members. An engine with typed bindings maps exactly
these; a generic engine may accept more.

| Operation | Input members |
| --- | --- |
| `CreateBucket` | `Bucket`, `CreateBucketConfiguration{LocationConstraint}`, `ObjectLockEnabledForBucket`, `ObjectOwnership` |
| `HeadBucket`, `DeleteBucket`, `GetBucketLocation`, `GetBucketVersioning`, `GetBucketTagging`, `DeleteBucketTagging`, `GetBucketCors`, `DeleteBucketCors`, `GetBucketLifecycleConfiguration`, `DeleteBucketLifecycle`, `GetBucketPolicy`, `DeleteBucketPolicy`, `GetBucketPolicyStatus`, `GetBucketEncryption`, `DeleteBucketEncryption`, `GetPublicAccessBlock`, `DeletePublicAccessBlock`, `GetBucketOwnershipControls`, `DeleteBucketOwnershipControls`, `GetBucketAcl`, `GetBucketAccelerateConfiguration`, `GetBucketRequestPayment`, `GetBucketLogging`, `GetBucketWebsite`, `DeleteBucketWebsite`, `GetBucketNotificationConfiguration`, `GetBucketReplication`, `DeleteBucketReplication`, `GetObjectLockConfiguration` | `Bucket` |
| `ListBuckets` | `MaxBuckets`, `ContinuationToken`, `Prefix` |
| `PutBucketVersioning` | `Bucket`, `VersioningConfiguration{Status}` |
| `PutBucketTagging` | `Bucket`, `Tagging{TagSet[{Key, Value}]}` |
| `PutBucketCors` | `Bucket`, `CORSConfiguration{CORSRules[{ID, AllowedHeaders[], AllowedMethods[], AllowedOrigins[], ExposeHeaders[], MaxAgeSeconds}]}` |
| `PutBucketLifecycleConfiguration` | `Bucket`, `LifecycleConfiguration{Rules[{ID, Status, Filter{Prefix}, Expiration{Days}, AbortIncompleteMultipartUpload{DaysAfterInitiation}}]}` |
| `PutBucketPolicy` | `Bucket`, `Policy` |
| `PutBucketEncryption` | `Bucket`, `ServerSideEncryptionConfiguration{Rules[{ApplyServerSideEncryptionByDefault{SSEAlgorithm, KMSMasterKeyID}, BucketKeyEnabled}]}` |
| `PutPublicAccessBlock` | `Bucket`, `PublicAccessBlockConfiguration{BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets}` |
| `PutBucketOwnershipControls` | `Bucket`, `OwnershipControls{Rules[{ObjectOwnership}]}` |
| `PutBucketAcl` | `Bucket`, `ACL` |
| `PutBucketAccelerateConfiguration` | `Bucket`, `AccelerateConfiguration{Status}` |
| `PutBucketRequestPayment` | `Bucket`, `RequestPaymentConfiguration{Payer}` |
| `PutBucketWebsite` | `Bucket`, `WebsiteConfiguration{IndexDocument{Suffix}, ErrorDocument{Key}}` |
| `PutBucketNotificationConfiguration` | `Bucket`, `NotificationConfiguration{}` (empty) |
| `ListBucketAnalyticsConfigurations`, `ListBucketMetricsConfigurations`, `ListBucketInventoryConfigurations`, `ListBucketIntelligentTieringConfigurations` | `Bucket`, `ContinuationToken` |
| `GetBucketAnalyticsConfiguration`, `DeleteBucketAnalyticsConfiguration`, `GetBucketMetricsConfiguration`, `DeleteBucketMetricsConfiguration`, `GetBucketInventoryConfiguration`, `DeleteBucketInventoryConfiguration`, `GetBucketIntelligentTieringConfiguration`, `DeleteBucketIntelligentTieringConfiguration` | `Bucket`, `Id` |
| `PutBucketAnalyticsConfiguration` | `Bucket`, `Id`, `AnalyticsConfiguration{Id, StorageClassAnalysis{}}` |
| `PutBucketMetricsConfiguration` | `Bucket`, `Id`, `MetricsConfiguration{Id}` |
| `PutBucketInventoryConfiguration` | `Bucket`, `Id`, `InventoryConfiguration{Id, IsEnabled, IncludedObjectVersions, Schedule{Frequency}, Destination{S3BucketDestination{Bucket, Format, Prefix}}}` |
| `PutBucketIntelligentTieringConfiguration` | `Bucket`, `Id`, `IntelligentTieringConfiguration{Id, Status, Tierings[{Days, AccessTier}]}` |
| `PutObjectLockConfiguration` | `Bucket`, `ObjectLockConfiguration{ObjectLockEnabled, Rule{DefaultRetention{Mode, Days}}}` (`Rule` optional) |
| `PutObject` | `Bucket`, `Key`, `ContentType`, `ContentDisposition`, `ContentEncoding`, `ContentLanguage`, `CacheControl`, `Metadata{}`, `ContentMD5`, `ChecksumAlgorithm`, `ChecksumCRC32`, `ChecksumCRC32C`, `ChecksumSHA1`, `ChecksumSHA256`, `IfMatch`, `IfNoneMatch`, `Tagging` (query string), `StorageClass`, `ServerSideEncryption`, `SSEKMSKeyId`, `ObjectLockMode`, `ObjectLockRetainUntilDate`, `ObjectLockLegalHoldStatus`; body |
| `GetObject`, `HeadObject` | `Bucket`, `Key`, `VersionId`, `Range`, `PartNumber`, `IfMatch`, `IfNoneMatch`, `IfModifiedSince`, `IfUnmodifiedSince`, `ChecksumMode` |
| `DeleteObject` | `Bucket`, `Key`, `VersionId`, `BypassGovernanceRetention` |
| `DeleteObjects` | `Bucket`, `Delete{Objects[{Key, VersionId}], Quiet}`, `BypassGovernanceRetention` |
| `CopyObject` | `Bucket`, `Key`, `CopySource{Bucket, Key, VersionId}`, `MetadataDirective`, `Metadata{}`, `ContentType`, `TaggingDirective`, `Tagging`, `CopySourceIfMatch`, `CopySourceIfNoneMatch`, `ServerSideEncryption` |
| `GetObjectAttributes` | `Bucket`, `Key`, `VersionId`, `ObjectAttributes[]` |
| `ListObjects` | `Bucket`, `Prefix`, `Delimiter`, `Marker`, `MaxKeys`, `EncodingType` |
| `ListObjectsV2` | `Bucket`, `Prefix`, `Delimiter`, `ContinuationToken`, `StartAfter`, `MaxKeys`, `EncodingType` |
| `ListObjectVersions` | `Bucket`, `Prefix`, `Delimiter`, `KeyMarker`, `VersionIdMarker`, `MaxKeys`, `EncodingType` |
| `GetObjectTagging`, `DeleteObjectTagging` | `Bucket`, `Key`, `VersionId` |
| `PutObjectTagging` | `Bucket`, `Key`, `VersionId`, `Tagging{TagSet[{Key, Value}]}` |
| `GetObjectAcl` | `Bucket`, `Key`, `VersionId` |
| `PutObjectAcl` | `Bucket`, `Key`, `VersionId`, `ACL` |
| `CreateMultipartUpload` | `Bucket`, `Key`, `ContentType`, `Metadata{}`, `ChecksumAlgorithm`, `ServerSideEncryption` |
| `UploadPart` | `Bucket`, `Key`, `UploadId`, `PartNumber`, `ContentMD5`, `ChecksumAlgorithm`; body |
| `UploadPartCopy` | `Bucket`, `Key`, `UploadId`, `PartNumber`, `CopySource{Bucket, Key, VersionId}`, `CopySourceRange` |
| `ListParts` | `Bucket`, `Key`, `UploadId`, `MaxParts`, `PartNumberMarker` |
| `ListMultipartUploads` | `Bucket`, `Prefix`, `KeyMarker`, `UploadIdMarker`, `MaxUploads` |
| `CompleteMultipartUpload` | `Bucket`, `Key`, `UploadId`, `MultipartUpload{Parts[{PartNumber, ETag}]}` |
| `AbortMultipartUpload` | `Bucket`, `Key`, `UploadId` |
| `GetObjectRetention`, `GetObjectLegalHold` | `Bucket`, `Key`, `VersionId` |
| `PutObjectRetention` | `Bucket`, `Key`, `VersionId`, `Retention{Mode, RetainUntilDate}`, `BypassGovernanceRetention` |
| `PutObjectLegalHold` | `Bucket`, `Key`, `VersionId`, `LegalHold{Status}` |
| `PresignedRequest` | `Method` (`GET` or `PUT`), `Bucket`, `Key`, `VersionId` (GET), `ContentType` (PUT, signed), `ExpiresIn` (seconds, 1–3600), `DelayMs` (0–5000, waited after signing and before sending); body for `PUT` |

`PresignedRequest` presigns with the SDK's presigner, sends the request with the
engine's own HTTP client (no redirects, no transparent decompression, the
signed headers only) and reports the response like any other operation. The URL
never leaves the engine; `Presign.QueryKeys` lists the query parameter names
only, sorted, so the host can check that a SigV4 query signature was produced.
