# Encryption for Object Data Browser 2.3.5: design scope for provider-side (Track A) and client-side (Track B)

Design scope only; no code was changed. Claims that could not be confirmed in source or on the web are tagged **[unverified]**.

## Summary

- **Track A is mostly plumbing, with a little existing support.** Encryption headers are sent today only on self-copy "object properties" edits (Python engine and mobile adapter). No engine sends them on ordinary uploads, and the inspector does not show per-object encryption.
- **AWS SSE-C is confirmed as blocked by default.** Since April 2026, new general purpose buckets, and existing buckets in accounts that had no SSE-C objects, reject SSE-C writes with 403 `AccessDenied`. The switch is `BlockedEncryptionTypes` on `PutBucketEncryption`. Treat SSE-C as an advanced, opt-in mode.
- **Track B recommendation: adopt the age v1 file format unchanged.** Encrypt each object to a per-vault X25519 key; keep keys, headers and the passphrase KDF in Dart only. Engines implement only the roughly 50-line chunk cipher, so any object can be recovered with the stock `age` CLI.
- **Fix four existing defects first** (phase A0); they become security or data-loss bugs once keys exist:
  1. Log sanitisers would print SSE-C and Azure customer keys in API logs.
  2. Rust and Java drop `BlockedEncryptionTypes` when reading and saving bucket encryption.
  3. The resumable-upload manifest writes request `options` to disk and writes the plaintext SHA-256 into object metadata.
  4. The Keychain bundle decoder strips unknown fields, so an older build would silently delete keys on its next write.

Effort scale used below: S is up to 2 days, M is 3–5 days, L is 1–2 weeks, XL is more than 2 weeks, per component.

## 0. What exists today (verified in source)

Short file names in the rest of the report refer to these absolute paths.

| Short name | Absolute path |
|---|---|
| `main.py` | `/Users/sndstone/Documents/Object-browser/engines/python/src/main.py` |
| `main.go`, `advanced.go`, `azure.go` | `/Users/sndstone/Documents/Object-browser/engines/go/src/` |
| `main.rs`, `server_copy.rs` | `/Users/sndstone/Documents/Object-browser/engines/rust/src/` |
| `Main.java`, `ServerCopy.java` | `/Users/sndstone/Documents/Object-browser/engines/java/src/main/java/com/example/s3browser/` |
| `app_controller.dart`, `upload_batch.dart` | `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/` |
| `domain_models.dart`, `connection_options.dart` | `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/models/` |
| `engine_service.dart`, `desktop_sidecar_engine_service.dart`, `app_state_repository.dart`, `profile_secret_store.dart`, `multipart_sizing.dart`, `mobile_storage_*.dart`, `mobile_azure_storage.dart`, `storage_http_client.dart`, `preview_image_loader.dart`, `diagnostic_safety.dart` | `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/services/` |
| `browser_workspace.dart`, `storage_admin_dialog.dart`, `object_preview_dialog.dart`, `object_table.dart`, `object_panel.dart` | `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/` |
| `settings_workspace.dart` | `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/settings/settings_workspace.dart` |
| contract files | `/Users/sndstone/Documents/Object-browser/contracts/engine_contract.json`, `/Users/sndstone/Documents/Object-browser/contracts/transport_contract.md` |

| Area | Current state | Evidence |
|---|---|---|
| Bucket default encryption | Read and write as raw JSON, capability-gated | `main.py:2441`, `2619`; `main.go:1155`; `main.rs:603`; `Main.java:604`; `mobile_storage_dispatch.dart:188-229`; UI `browser_workspace.dart:1178`, `1231`, `1259` |
| `BlockedEncryptionTypes` | Python passes the JSON through to boto3. Go unmarshals into the SDK type, which has the field. Rust and Java drop it on both read and write. | `main.rs:2782-2824`, `2855-2866`; `Main.java:2247-2268`, `2321-2339` |
| Upload (single and multipart) | No encryption parameter in any engine or in the service interface; no `metadata` or `contentType` parameter either | `engine_service.dart:241-250`; `main.py:3208`, `3238`, `3329`; `main.go:1606`, `1646`, `1713`; `main.rs:1430`, `1472`, `1702`; `Main.java:1268`, `1280`, `1295`; `mobile_storage_transfers.dart:620-672` |
| Download, HEAD, presign | No way to pass an SSE-C key, so SSE-C objects cannot be inspected, downloaded, previewed or copied | `main.py:2790`, `2855`, `3400`, `3476`; `main.go:1340`, `1878`, `2002`; `main.rs:1040`, `1997`, `2116`; `Main.java:977`, `1460`, `1586` |
| Object details | Python returns `ServerSideEncryption`, `SSEKMSKeyId`, `BucketKeyEnabled`; mobile returns one string; Go and Java return none, and I found none in Rust (keyword scan only). The Dart `ObjectDetails` model has no encryption field, so the inspector never shows it. Only the raw JSON in "Manage object" does. | `main.py:2829`, `1302`; `mobile_storage_admin.dart:711`; `domain_models.dart:712-733`; `browser_workspace.dart:1393-1405`; `storage_admin_dialog.dart:476` |
| Re-encrypt in place | Exists as a self-copy with `AES256` or `aws:kms` and an optional key ARN. Desktop uses Python only; mobile also accepts `aws:kms:dsse`. No encryption context, bucket-key or SSE-C support. | `storage_admin_dialog.dart:485-518`; `main.py:5591-5595`, `5603-5614`; `mobile_storage_transfers.dart:109-124` |
| Copy, move, rename | Behaviour differs by engine. Python preserves source SSE only on self-copy (`main.py:5747-5748`). Rust and Java preserve it only on the multipart path above 5 GiB (`server_copy.rs:86-88`, `ServerCopy.java:77-79`). Go never does (`advanced.go:396`, `418`). Below 5 GiB the destination bucket default applies everywhere. | as cited |
| Listing | No encryption information | `main.py:2396-2413`; `domain_models.dart:560-579` |
| Log redaction | Sanitisers match `authorization`, `security-token`, `access-key`, `secret`, `token`. `x-amz-server-side-encryption-customer-key` and `x-ms-encryption-key` match none of them. I did not locate the Java sanitiser. | `main.py:504-513`; `main.go:555-570`; `main.rs:4405-4417`; `diagnostic_safety.dart:6-9` |
| Recovery manifests | `options` are persisted to `~/.object-data-browser/transfers/*.json`; plaintext SHA-256 is written to object metadata | `main.py:5213`, `5270-5271` |
| Error mapping | `AccessDenied` maps to `auth_failed`, shown as "Authentication failed", which is wrong for a policy or KMS denial | `main.py:664-665`; `domain_models.dart:10` |
| Secret bundle | Hard-coded to `version: 2`; the decoder keeps only `accessKey`, `secretKey`, `sessionToken` | `app_state_repository.dart:400-437`, `459-465` |
| Desktop routing precedent | `storageAction` always goes to the Python engine, whatever engine is selected | `desktop_sidecar_engine_service.dart:56-65` |

Dependencies already present: Python bundles `cryptography==50.0.2`; Go has `golang.org/x/crypto` as an indirect module; Java runs on JDK 21; Dart has only `crypto` (hashes).

---

# Track A: provider-specification encryption

## 1. Option set and header mapping

Abbreviations:
- `SSE` is `x-amz-server-side-encryption`.
- `KID` is `…-aws-kms-key-id`.
- `CTX` is `…-context` (base64 of a UTF-8 JSON map).
- `BK` is `…-bucket-key-enabled`.
- `C3` is the three `x-amz-server-side-encryption-customer-{algorithm,key,key-MD5}` headers.
- `SRC-C3` is the three `x-amz-copy-source-server-side-encryption-customer-*` headers.

| Operation | SSE-S3 | SSE-KMS | DSSE-KMS | SSE-C |
|---|---|---|---|---|
| PutObject, CreateMultipartUpload | `SSE: AES256` | `SSE: aws:kms`, optional `KID`, `CTX`, `BK` | `SSE: aws:kms:dsse`, optional `KID`, `CTX`; no `BK` | `C3` |
| UploadPart | none | none | none | identical `C3` on every part |
| CompleteMultipartUpload | none | none | none | not needed, unless a bucket policy requires the customer-algorithm header on all multipart calls |
| GetObject, HeadObject | none; caller needs `kms:Decrypt` for KMS modes | none | none | `C3` required |
| CopyObject | destination headers as for PutObject; the source mode is not inherited, the destination bucket default applies | same; source needs `kms:Decrypt` | same | destination `C3`; source `SRC-C3` |
| UploadPartCopy | none | none | none | destination `C3` and source `SRC-C3` on every part |
| Presigned GET | ordinary URL, works in a browser | same | same | algorithm header must be in the signature and the caller must send all three headers, so links are programmatic only |
| Response fields | `SSE` | `SSE`, `KID`, `BK` | `SSE`, `KID` | customer algorithm and key MD5 |
| ETag | MD5 of the data for a single PUT | not an MD5 | not an MD5 | not an MD5 |

Notes:
- **KMS key ID:** prefer a full ARN. AWS warns that an alias is resolved in the requester's account, which can encrypt under the wrong owner's key.
- **Bucket Keys:** not supported for DSSE-KMS (confirmed).
- **Directory buckets:** support neither SSE-C nor DSSE-KMS (confirmed).
- **Encryption context on HEAD/GET:** not returned **[unverified]**.
- **ETags:** the app already treats them as validators only (`transport_contract.md:33-34`), so the ETag differences are harmless.
- **HTTPS:** SSE-C requires it; AWS rejects HTTP. The app should refuse client-side on `http://` profiles.
- **Wrong or missing SSE-C key:** GET without a key returns 400, HEAD returns a bare 400, a wrong key returns 403 **[unverified exact codes]**.

**SSE-C on AWS (confirmed in AWS docs):**
- **Scope:** deployed in 37 regions in April 2026, for all new general purpose buckets and for existing buckets in accounts with no SSE-C objects. AWS's FAQ excludes Middle East (Bahrain) and Middle East (UAE).
- **Effect:** `PutObject`, `CopyObject`, `PostObject`, multipart and replication requests that specify SSE-C get 403 `AccessDenied`. Existing SSE-C objects stay readable with their key.
- **Control:** `ServerSideEncryptionRule.BlockedEncryptionTypes.EncryptionType` set to `["SSE-C"]` or `["NONE"]` through `PutBucketEncryption`. It needs `s3:PutEncryptionConfiguration`, and is read back through `GetBucketEncryption` with `s3:GetEncryptionConfiguration`.
- **Open question:** whether a `PutBucketEncryption` that omits the element keeps or resets the block is not stated in the pages I read **[unverified]**. That is why the Rust and Java round-trip loss matters.
- **Mobile:** whether the mobile XML builder serialises the nested list correctly is **[unverified]** and needs a test.

**Bucket-level handling:**
- **Policy lint (Dart, engine-independent):** scan the existing `policyJson` for Deny statements conditioned on `s3:x-amz-server-side-encryption`, `s3:x-amz-server-side-encryption-aws-kms-key-id` or `s3:x-amz-server-side-encryption-customer-algorithm`. Derive the required mode and pre-fill the bucket's upload rule.
- **On a denied upload:**
  - Introduce a typed `access_denied` code. Python already raises that string ad hoc at `main.py:5655`.
  - Add `details.encryptionHint` with one of: `encryption_required_by_policy`, `kms_access_denied`, `kms_key_unavailable`, `sse_c_blocked`, `sse_c_key_required`, `sse_c_key_mismatch`, `unsupported_by_endpoint`.
  - Show "This bucket's policy requires X. Retry with X?" Never retry automatically.
- **Bare PUTs elsewhere:** these fail under deny-unencrypted policies and need the same option: `createFolder` (`main.py:2872`), put-test-data (`main.py:3690`), benchmark writes (`main.py:4707`) and delete-recovery empty PUTs (`main.py:3762`).

## 2. Azure Blob equivalents

| Mechanism | Level | Request surface | Limits |
|---|---|---|---|
| Microsoft-managed or customer-managed keys | Storage account, management plane | None per request. Responses carry `x-ms-server-encrypted` (already read at `main.py:1302`, `mobile_azure_storage.dart:468`). | Display only; changing it needs ARM and Entra. |
| Encryption scopes | Blob or container default | `x-ms-encryption-scope` on writes. Container creation takes `x-ms-default-encryption-scope` and `x-ms-deny-encryption-scope-override` **[header names from memory, unverified]**. | Reads are transparent. A disabled scope gives 403. Scopes cannot be deleted. The access tier of a scoped blob cannot be changed, and it cannot go to archive. Minimum 30-day billing. |
| Customer-provided keys (CPK) | Per request | `x-ms-encryption-key`, `x-ms-encryption-key-sha256`, `x-ms-encryption-algorithm: AES256` | HTTPS only. Supported on Put Blob, Put Block, Put Block List, Put Block/Page from URL, Put Page, Append Block, Set Blob Metadata, Get Blob, Get Blob Properties, Get Blob Metadata, Snapshot Blob. Missing key gives 409. No object replication. The portal cannot read these blobs. Rotation means download and re-upload. |

Consequences for the app:
- Async Copy Blob is not on the CPK list, so the app's Azure copy (`main.py:1377`, `azure.go:862`) must fall back to the existing relay path for CPK blobs.
- The pinned API version `2021-12-02` (`main.py:687`) already covers both features.
- Azure listings can return per-blob encryption properties without a HEAD **[unverified]**.
- Rust and Java have no Azure support, so Azure work is Python, Go and mobile only.

## 3. S3-compatible stores

| Store | SSE-S3 header | SSE-KMS | SSE-C | Bucket default API | Confidence |
|---|---|---|---|---|---|
| MinIO | Needs a configured KMS, otherwise an error | Needs KMS (KES) | Yes, TLS required | Yes, with KMS | Secondary sources |
| Ceph RGW | Vault only | Vault, Barbican, KMIP | Yes, HTTPS required | Yes, including `BlockedEncryptionTypes` and `rgw_s3_block_sse_c_by_default` | Ceph docs |
| Cloudflare R2 | Not implemented (always encrypted at rest) | Not implemented | Yes, including copy-source and multipart | Put: no. Get: yes. | R2 docs |
| Backblaze B2 | SSE-B2; mapping from the S3 `AES256` header is **[unverified]** | Not mentioned | Yes; wrong key gives 403 | Yes | B2 docs (native API only) |
| Wasabi | Yes | Not listed | Yes | **[unverified]** | Wasabi docs |
| GCS XML interop | **[unverified]** | Via `x-goog-encryption-kms-key-name` | Via `x-goog-encryption-*` with SHA-256, not MD5; acceptance of `x-amz-*` SSE-C headers is **[unverified]** | Not applicable | Google docs, partial |

DSSE-KMS is AWS-only **[unverified for the others]**.

**Capability detection** should never mutate on connect:
1. **Host hints:** recognise R2, B2, Wasabi and GCS endpoints.
2. **Passive read:** use `GetBucketEncryption`, including the block state, which the admin state already fetches.
3. **Learn on first use:** on a rejection, cache "unsupported" per profile and mode.
4. **Explicit probe:** a "Test encryption support" button writes, HEADs and deletes a tiny probe object per mode with consent.
   - The HEAD must echo the expected header.
   - A store that accepts and ignores the header is reported as "accepted but not confirmed".

New capability keys: `object.encryption.{sse-s3,sse-kms,dsse-kms,sse-c,azure-scope,azure-cpk}`. For `s3Compatible` profiles they start as `unknown`, matching the existing Go pattern at `main.go:222-227`.

## 4. Product design

**Where the user chooses.** Resolution order is per-upload override, then bucket or prefix rule, then profile default, then "Bucket default (send no header)", which stays the default.
- **Storage:** rules are non-secret metadata on the profile, next to `ConnectionOptions`, so they may live in state JSON and exports.
- **Upload sheet:** an "Encryption" row appears in the upload flow only when a rule or a policy requirement exists, or under "Advanced".
- **Bucket panel:** one "Bucket encryption" panel replaces the raw JSON as the primary surface. It shows the provider default, SSE-C allowed or blocked with an explicit "Allow SSE-C on this bucket" action, detected policy requirements, the upload rule, and the Track B vault state. The JSON editor stays as "Advanced".

**SSE-C and CPK keys.**
- **Generation and import:** 32 bytes from the OS CSPRNG, or import from base64, hex or a file. Each key has an ID, label, creation date and a fingerprint (SHA-256 of the key, which is also Azure's key hash).
- **Storage:** inside the single `profiles.credentials.v2` Keychain item as a top-level `keys` map beside `profiles`.
  - Keys are not nested per profile, so two profiles can share one and deleting a profile never deletes keys.
  - The delete-profile text at `settings_workspace.dart:2004` must say so.
- **Non-secret index:** key IDs, labels and fingerprints go in state JSON. Exports stay metadata-only, as AGENTS.md requires.
- **Bundle version:** keep writing byte-identical `version: 2` while `keys` is empty. Write `version: 3` only once keys exist, so older builds fail closed at `app_state_repository.dart:414` instead of silently stripping at `:459-465`.
- **Recovery Save guard:** after a hydration failure, an explicit profile Save may recreate the Keychain item. With keys in that item, a denied Keychain prompt followed by Save would destroy them.
  - The Save must retry the read and merge.
  - If the state-JSON index shows keys existed, it must block behind a destructive confirmation that points to recovery-kit import.
- **Backup:** a mandatory "recovery kit" export before the first SSE-C write. It is a passphrase-encrypted file; I recommend an age scrypt file so it opens with stock tools. It is separate from profile export. Importing it follows the credential-bearing import rule in AGENTS.md.
- **Lifetime:** keys are never auto-deleted. Old keys stay, because versioned buckets can hold a different key per version.

**Inspector and listing.**
- **Inspector:** an "Encryption" row shows the mode, the KMS key (shortened ARN), bucket key, the SSE-C key fingerprint matched to a keyring label, and the Azure scope.
- **SSE-C without a key:** the inspector shows "Encrypted with a customer key: choose key", not a generic failure.
- **Listing:** S3 listings carry no encryption data, so there is no column; the lock badge is for Track B only.

**Copy, move, rename.**
- **Default:** "preserve source encryption" on all engines, which fixes today's inconsistency. Explicit alternatives are "Use destination bucket default" and "Set…".
- **SSE-C sources:** need `sourceEncryption`.
- **Re-encrypt in place:** extends the existing `objectProperties` self-copy with DSSE, context, bucket key and SSE-C in either direction.
  - It creates a new version in versioned buckets, and older versions keep their old encryption.
  - Add a bulk "change encryption for prefix" job later.

**Contract additions.** All are optional, so no version bump under `transport_contract.md:19`.

| Method | New request fields | New response fields |
|---|---|---|
| `startUpload`, `createFolder`, `runPutTestData`, `startBenchmark` | `encryption` (shape below); `startUpload` also gains `metadata`, `contentType` | Echoed effective mode in job output |
| `startDownload`, `getObjectDetails`, `generatePresignedUrl` | `encryption` with `mode: "sse-c"` or `"azure-cpk"` and `customerKey` | `getObjectDetails.encryption` normalised: `mode`, `kmsKeyId`, `bucketKeyEnabled`, `customerKeyMd5` or `customerKeySha256`, `azureScope`, `serverEncrypted`. Presign adds `requiredHeaders` (names only). |
| `copyObject`, `moveObject`, `storageAction` (`copyObject`, `objectProperties`, resumable and version actions) | `options.encryption` extended to the full shape; `sourceEncryption`; `options.encryptionPolicy: "preserve" \| "bucketDefault" \| "set"` | `encryption` of the destination |
| errors | none | `code: "access_denied"`, `details.encryptionHint` |

`encryption` shape: `{mode, kmsKeyId?, kmsEncryptionContext?, bucketKeyEnabled?, customerKey?, encryptionScope?}`. Modes are `bucketDefault`, `sse-s3`, `sse-kms`, `dsse-kms`, `sse-c`, `azure-scope`, `azure-cpk`.

Rules for keys in the contract:
- Keys travel per request, as profile secrets already do.
- Keys are never in the profile JSON, never logged, and never written to recovery manifests.
- Manifests store only the fingerprint, and the key is resupplied on resume. This matches the existing "credentials are resupplied on resume" capability text at `main.py:2230`.

**Per-component effort.**

| Component | A0 hardening | A1 SSE-S3, KMS, DSSE | A2 SSE-C and Azure |
|---|---|---|---|
| Python | S | M | L |
| Go | S | M | L (includes Azure) |
| Rust | S | M | M |
| Java | S | M | M |
| Mobile Dart adapter | S | S–M | M–L |
| Flutter models, controller, UI | M | L | L–XL |

---

# Track B: client-side encryption

## 5. Threat model, in user terms

**Protects against:**
- The storage provider and anyone who compels or breaches it.
- Leaked or over-shared bucket credentials: the holder can list, delete and overwrite, but cannot read contents.
- A bucket accidentally made public, and presigned links that escape: the reader gets ciphertext.
- Undetected modification of file contents: tampering fails authentication.

**Does not protect against:**
- A compromised or unlocked device, or malware on it.
- A weak passphrase, when the wrapped vault key is stored in the bucket: the provider can guess offline.
- Metadata: object names, folder structure, sizes (to within 0.03%), timestamps, access patterns, and which objects belong to which vault.
- Deletion, rollback to an older version, or swapping two encrypted objects' contents. The format does not bind ciphertext to the object name.
- A future quantum computer against data captured today, while the vault key is X25519.
- Plaintext written before encryption was turned on, including old versions in versioned buckets.

Losing the key and the recovery kit loses the data permanently.

## 6. Format comparison and recommendation

| Criterion | AWS S3 Encryption Client v3/v4 | rclone crypt | age v1 | Cryptomator | Tink streaming AEAD | Custom container |
|---|---|---|---|---|---|---|
| Recover without this app | AWS SDKs only, no CLI | `rclone` everywhere | `age`, `rage` and others everywhere | Cryptomator apps | A small program, no end-user tool | Only what we ship |
| Libraries across Python, Go, Rust, Java, Dart | Java, Go, .NET, C++, Ruby, PHP, Python. None for Rust or Dart. Go and Python 3.x keyrings are KMS-only. | Needs XSalsa20-Poly1305 in all five; missing from Python `cryptography` and from JCA | Go reference, Rust `age` crate, Java Jagged, Python via `cryptography` primitives or `pyrage`; Dart must be implemented on `package:cryptography` | Official Java and Swift only **[unverified]** | Java, Go, C++, Python (native wrapper); no Rust or Dart **[unverified]** | Primitives exist everywhere |
| Authenticated random access | No: one GCM tag per object; ranged reads use an unauthenticated mode **[unverified]** | Yes, 64 KiB chunks | Yes, 64 KiB chunks; the spec defines seeking | Yes, 32 KiB chunks **[unverified]** | Yes | Yes |
| Parallel, out-of-order multipart | No, sequential only **[unverified]** | Yes, positional | Yes, positional counter nonces | Yes | Yes | Yes |
| Per-object key, re-wrap, sharing | Yes (envelope) | No: one key for everything, no recipients | Yes: per-file key, multiple recipients, public-key upload | Per-file header key, single master key | Keyset-level | Whatever we design |
| Truncation protection | Tag at end | No final-chunk marker **[unverified]** | Final-chunk flag, mandated by spec | Yes | Yes | Must design |
| Specification and vectors | AWS docs | Documented in rclone source and docs | C2SP spec plus the CCTV suite of over 100 vectors | Documented | Documented | None |
| Forces filename encryption | No | Optional | No | Yes; breaks prefix listing | No | No |

**Recommendation: age v1, unmodified.** It is the only candidate that meets all of these together: stock-tool recovery on every operating system, chunked authenticated random access, positional encryption that fits parallel multipart, a per-object key under a public-key envelope, a small formal specification, and a shared vector suite.

I recommend against a custom container: five implementations of a format nobody else can review or decrypt is the wrong risk to take.

What is custom in the recommended design is non-cryptographic only: a vault descriptor JSON object, three metadata keys, a `.age` key suffix, and byte-offset arithmetic for parts and ranges.

Costs to accept:
- **Cipher:** ChaCha20-Poly1305 rather than hardware AES.
- **Key size:** a 128-bit file key, expanded to a 256-bit payload key.
- **Passphrase KDF:** scrypt rather than Argon2id.
- **Audit:** I found no formal third-party audit of the age implementations **[unverified]**.

## 7. Recommended design

**Container (exactly the age spec).**
- **Header:** a text header with the version line, one stanza per recipient, and an HMAC-SHA-256 over the header keyed from the file key.
- **Payload:** a 16-byte random payload nonce, then 64 KiB plaintext chunks, each sealed with ChaCha20-Poly1305 under `HKDF-SHA-256(file key, salt = nonce, info = "payload")`.
- **Chunk nonce:** an 11-byte big-endian counter plus one final-chunk flag byte.
- **Final chunk:** may be short, but must not be empty unless the whole payload is empty. This gives truncation and reordering protection.
- **No AAD:** the format has none, so ciphertext is not bound to bucket or key.
  - Consequence: server-side copy, move, rename and the bucket-copy tool work on ciphertext unchanged.
  - Price: the swap and rollback exposure listed in section 5.
  - I recommend accepting this; binding the name would turn every rename into download and re-encrypt.

**Key hierarchy.**
- **Per-object key:** the age file key, random and never reused.
- **Vault key:** an X25519 identity. Objects are encrypted to its public recipient.
- **User secret, any of:**
  1. A passphrase that unlocks `identity.age`, the identity stored as a standard age scrypt-encrypted file.
  2. The identity cached in the Keychain bundle `keys` map ("remember on this device").
  3. The recovery kit.
- **Later options:**
  - Additional recipients for teammates.
  - Hybrid post-quantum recipients (`age1pq…`, ML-KEM-768 plus X25519, in age 1.3 and later). These cannot be mixed with classic recipients in one file.
  - Hardware-backed and KMS-wrapped identities **[unverified feasibility across platforms]**.

**Passphrase KDF.**
- **Recommended:** age's scrypt stanza with work factor 2^18, r=8, p=1, about 256 MiB. This is age's default **[unverified]**. Accept 2^15 to 2^20 on read to bound denial of service.
- **Where it runs:** only in Dart, once per unlock. Engines never see passphrases. Pure-Dart scrypt at that size may be slow on phones **[unverified, measure in the spike]**; the Keychain cache avoids repeating it.
- **If the owner insists on Argon2id:** use m = 64 MiB, t = 3, p = 4 (the second recommended RFC 9106 set).
  - On mobile, p = 1 is acceptable. Never go below m = 19 MiB, t = 2.
  - Use a 16-byte salt and store the parameters in the descriptor.
  - This would be the one custom cryptographic wrapper, and it would break passphrase recovery with stock `age`. I do not recommend it.

**What is stored where.**

| Item | Location |
|---|---|
| Vault identity (secret) | Keychain bundle `keys[vaultId]` if remembered; otherwise session memory only. Never state JSON, exports or logs. |
| Vault ID, pinned recipient fingerprint, scope (bucket or prefix), label | Profile metadata in state JSON; exportable |
| `.odb-vault/vault.json` in the bucket | Plaintext, non-secret: format version, vault ID, recipients, name mode `plain` |
| `.odb-vault/identity.age` in the bucket | Passphrase-wrapped identity; optional (decision 5) |
| Object | Key gets a `.age` suffix. Metadata `odb-enc: age1`, `odb-vault: <id>`, `odb-plain-size: <n>` (a hint only). Content-Type `application/octet-stream`. |

- **Trust:** the in-bucket recipient list is advisory. The app encrypts to the locally pinned recipient and warns if the descriptor lists keys it does not recognise; otherwise anyone with bucket write access could add their own key.
- **Why `.age`:** it lets listings detect encrypted objects without a HEAD per object, and makes a plain `aws s3 cp` download self-describing. The authoritative check is the 21-byte magic at access time.
- **Display:** the UI shows the name without the suffix, with a lock icon.

**Backup, rotation, re-wrap.**
- **Recovery kit:** mandatory at vault creation. It holds the identity as `AGE-SECRET-KEY-1…`, printable, optionally passphrase-wrapped. The app proves it by decrypting a canary object with the kit before enabling uploads.
- **Changing the passphrase:** rewrites only `identity.age`.
- **Changing the vault key or removing a recipient:** needs a new header per object, and S3 objects are immutable.
  - Small objects are rewritten as ciphertext, with no payload decryption.
  - Large objects rebuild with a multipart upload: part one is the new header plus the first 5 MiB or more, re-uploaded; the rest uses `UploadPartCopy`.
  - Old versions and anything the provider retained keep the old header, so rotation limits future exposure only.

**Filename encryption.**
- **Recommendation:** not in v1, and I recommend not building it.
- **Cost:** it breaks prefix navigation, server-side search, sort, folder markers, presigned sharing and every external tool, and it needs a per-prefix encrypted index or deterministic name encryption.
- **Forward compatibility:** keep `nameMode` in the descriptor so a later opaque-name mode is possible.

**Sizes and integrity.**
- **Listing:** shows the stored (ciphertext) size, which is what is billed.
- **Inspector:** shows both sizes.
- **Provider checksums:** checksums, SigV4 payload hashes and ETags cover ciphertext and keep doing transport integrity.
- **End-to-end integrity:** comes from the chunk tags.
- **Plaintext hashes:** do not store them in metadata. They reveal when two objects are identical. The recovery workflow's `object-browser-source-sha256` (`main.py:5270`) must switch to a ciphertext digest for encrypted uploads.

## 8. Impact on existing features

**Multipart sizing.** With header length H, plaintext size P and chunk size 65,536:

- `C(P) = H + 16 + P + 16 × max(1, ceil(P / 65536))`
- Inverse: `B = C − H − 16`, `n = ceil(B / 65552)`, `P = B − 16n`

For one X25519 recipient, H is about 168 bytes **[my calculation, not measured]**. Overhead is 0.0244% plus about 184 bytes.

Rules:
- Run `MultipartSizing` (`multipart_sizing.dart:16-56`) and the threshold test on `C(P)`, not P.
- Keep **uniform ciphertext parts**: part j is ciphertext bytes `[(j−1)·S, j·S)`. This preserves every existing limit, and R2 requires equal part sizes **[unverified]**.
- A worker maps its range to chunks `floor((a − H − 16)/65552)` through `floor((b − 1 − H − 16)/65552)` and encrypts them from its own file handle. The pattern at `main.py:3231-3246` stays. Boundary chunks are computed twice, with identical output.
- Worker memory drops to one chunk.
- Maximum plaintext is about 49,988 GiB instead of 50,000. Add boundary tests, as AGENTS.md requires.

**Nonce safety.** Retrying a part re-encrypts the same chunk under the same key and nonce. That is safe only if the plaintext is identical.
- Keep `_verify_source` (`main.py:3234`, `3245`).
- Add a per-chunk plaintext digest guard, 32 bytes per chunk held in memory. It fails the upload if a re-read chunk differs.
- Never reuse a file key across upload attempts.

**Range download and resume.**
- **Range mapping:** plaintext range `[a, b]` maps to ciphertext `[H+16+floor(a/65536)·65552, H+16+(floor(b/65536)+1)·65552 − 1]`.
- **Header fetch:** read the first 8 KiB once per object to parse the header; reject headers over 64 KiB.
- **Staging:** workers decrypt into the existing staged `.odb-*.part` file.
- **Publication:** happens only after every chunk authenticates, the last chunk carries the final flag, and the chunk count matches the HEAD size. Existing Content-Range and If-Match rules apply in ciphertext space.
- **Resumable uploads:** the manifest stores the age header bytes, which are ciphertext, never the file key. Resume unwraps it with the unlocked identity. The existing SHA-256 source identity guarantees identical plaintext.

**Copy, move, rename.**
- Ciphertext is copied server-side unchanged.
- The copy must carry metadata and the `.age` suffix; the rename dialog enforces the suffix.
- Nothing breaks, because no AAD binds the name.

**Previews.** A presigned URL returns ciphertext, so Dart fetches a bounded ciphertext range through the presigned URL and decrypts in an isolate.
- **Text:** fetch the header plus `ceil(limit/65536)` chunks and decrypt; the byte limit is unchanged (`app_controller.dart:3940-3999`).
- **Images:** only when the size is within the existing image limit. Fetch all, decrypt in memory, and hand bytes to the loader. `preview_image_loader.dart` needs a bytes entry point beside the URL one at `:27`.
- **HTML:** rendered statically from the decrypted text with `baseUrl` null, because sibling resources are ciphertext (`object_preview_dialog.dart:356`).
- **Video:** "Download to view".
- **Lock:** clear the decrypted preview cache (`preview_image_loader.dart:20`) on vault lock.
- **SSE-C previews** use the same path, minus decryption, plus the three request headers.

**Sharing.**
- **MVP:** the Share tab explains that the link returns ciphertext.
- **Later:** "Share a decrypted copy" re-encrypts to a one-off passphrase (an age scrypt file) under a short-lived prefix and presigns it; the recipient runs `age -d`. Public-key recipients follow for teams.

**Versioning, mixed buckets, missing key.**
- **Versions:** each version is detected independently.
- **Mixed buckets:** plaintext and encrypted objects coexist. `a.txt` and `a.txt.age` are shown as two rows.
- **Encrypt existing object:** writes the `.age` object, verifies it, and only then offers to delete the original. It warns that prior plaintext versions remain.
- **Vault locked or key missing:** listing still works. Download offers "Unlock" or "Download ciphertext".
- **Authentication failure:** discards the staged file and reports the chunk. It never falls back to writing unauthenticated bytes.

**Bucket copy and benchmark.**
- **Bucket copy (`app_controller.dart:4742`):** ciphertext and the descriptor are copied verbatim, so the destination is a clone of the vault.
- **Benchmark:** stays plaintext by default, with an optional overhead toggle later.

**Mobile.**
- **Background:** transfers run in-process in the Dart adapter. I saw no OS background-session code **[unverified]**, so encryption does not change background behaviour.
- **Isolates:** run the cipher in a worker isolate, as the hash worker does at `mobile_storage_hash.dart:42`.
- **Double pass:** S3 parts above 8 MiB are streamed twice for SigV4 hashing (`mobile_storage_transfers.dart:373`). Encryption would also run twice unless parts are buffered.

**Performance.**
- **Native engines:** ChaCha20-Poly1305 should run at roughly 1 GB/s per core or better in OpenSSL (Python), Go, Rust and the JDK **[unverified estimates]**, above typical network speed.
- **Dart:** pure Dart is reported at about 30 MB/s (a figure from a fork's README), so mobile needs platform acceleration through `cryptography_flutter`. This must be measured.
- **Placement:** run encryption inside each part worker.
- **Hardware AES:** irrelevant to this cipher.

## 9. Where the cryptography lives

**Recommendation: a split.**
- **Dart owns:** vault and key management, the scrypt KDF, header writing and parsing, file-key wrap and unwrap, preview decryption, and all mobile transfers.
- **Engines are chunk-cipher workers:** they receive, per file, `clientEncryption: {format: "age-v1", header, fileKey}`. They implement only the HKDF and the chunk loop, about 50 lines with standard primitives.
- **Long-term secrets:** the vault identity never leaves the Dart process.
- **One file per request:** AGENTS.md already says each dispatched upload contains one file; engines reject the parameter otherwise.

| Option | Implementations | Throughput and memory | Test burden | Verdict |
|---|---|---|---|---|
| All five implement full age | 5 full | Best | Highest: header, KDF and X25519 five times | No |
| Dart only, engines move temp ciphertext files | 1 | Double disk I/O, temp space equal to file size, slow on Windows and Linux | Lowest | Fallback only |
| Python only, plus Dart for mobile | 2 full | Good | Medium | Close second |
| **Split: Dart keys and headers, engines chunk cipher** | 1 full, plus a small worker per engine | Best; streaming, parallel | Low per engine | **Recommended** |

**MVP engines** are Python (desktop) and Dart (mobile and previews).
- When the selected engine lacks the capability, the host routes encrypted transfers to Python and labels the job "reference engine". This follows the `storageAction` precedent.
- Go, Rust and Java are S-sized follow-ups each.
- Capability key: `object.clientEncryption` with `formats: ["age-v1"]`.

**Conformance.**
- **Vectors:** `contracts/vectors/age-stream/` holds file key, nonce, plaintext pattern and expected ciphertext digest for sizes 0, 1, 65535, 65536, 65537, 131072 and part-straddling ranges.
- **Negative vectors:** bit flip, truncation at a chunk boundary, missing final flag, trailing empty chunk, swapped chunks. All must fail.
- **Dart header code:** runs the C2SP CCTV age vectors.
- **Contract test:** a new `tests/contract/test_client_encryption.py` per `ENGINE_CMD` against the existing loopback storage fixture. It captures uploaded bytes, compares them to the vectors, delivers parts out of order, retries a part, and changes the source mid-upload.
- **CI interop:** each implementation's output is decrypted by the reference `age` and `rage` binaries, and the reverse.

---

# Both tracks

## 10. Phased delivery

| Phase | User-visible scope | Contract and model | Components and effort | Tests | Deliberately excluded |
|---|---|---|---|---|---|
| **A0 Hardening** | Inspector shows encryption; bucket panel shows SSE-C blocked or allowed | `ObjectDetails.encryption`; `access_denied` | All four engines S each; mobile S; Flutter M | Redaction unit tests in every sanitiser; `BlockedEncryptionTypes` round-trip in Rust and Java; mobile XML shape | New upload options |
| **A1 SSE-S3, KMS, DSSE** | Encryption on upload, folder marker, copy, move, rename and re-encrypt; bucket and profile rules; policy lint and denial prompts | `encryption` on upload, `createFolder` and copy; capability keys | Engines M each; mobile S–M; Flutter L | Header assertions against the loopback fixture per engine; MinIO with KMS; live AWS for KMS, bucket keys, DSSE and a deny-policy bucket | SSE-C, Azure, benchmark options |
| **A2 SSE-C and Azure** | Keyring, recovery kit, SSE-C read, write, copy and preview, unblock action; Azure scopes and CPK | Bundle v3 `keys`; `sourceEncryption`; presign `requiredHeaders` | Python L; Go L; Rust M; Java M; mobile M–L; Flutter L–XL | Keychain v2/v3 migration, downgrade and recovery-Save guard tests; MinIO over TLS; live AWS (blocked and unblocked buckets); Azurite plus live Azure for scopes | Bulk re-encrypt job, probe UI |
| **A3 Completion** | Bulk "change encryption", probe button, benchmark and tool options, provider hints | Benchmark and tool config fields | Engines S–M each; Flutter M | Compatibility matrix runs against R2, B2, Wasabi where available | none |
| **B0 Spike and spec** | None | Format note and vectors in `contracts/` | Dart M | Dart cipher throughput and scrypt time on real phones; go or no-go | Product UI |
| **B1 MVP** | Create and unlock a vault (bucket or prefix); upload, download, ranges; lock badge; decrypted bounded previews; recovery kit; verify after upload; mixed buckets; ciphertext copy, move, rename | `clientEncryption` on upload and download; `metadata` on upload; `object.clientEncryption` | Python M–L; Dart L–XL; Flutter XL | Vectors, CCTV, reference-CLI interop; multipart sizing boundaries; controller and widget tests; MinIO and Azurite end to end | Mobile transfers, resumable workflow, sharing, rotation, other engines, name encryption |
| **B2** | Mobile transfers; resumable transfers; encrypt or decrypt existing objects in bulk; extra recipients; share a decrypted copy | Recovery manifest stores header; recipients in rules | Dart L; Python M; Flutter L | Device tests on iOS and Android per AGENTS.md; kill-and-resume | Rotation, post-quantum |
| **B3** | Go, Rust, Java workers; vault re-key job; post-quantum recipients; hardware or KMS key sources | Capability on remaining engines | S each for engines; M–L for the rest | Same vector suite per engine | Filename encryption |

Every phase runs `flutter analyze` and the full Flutter suite, as AGENTS.md requires.

## 11. Decisions for the owner, and main risks

| # | Decision | Recommended answer |
|---|---|---|
| 1 | Client-side format | age v1 unmodified; no custom container |
| 2 | Offer SSE-C at all, given AWS's default block | Yes, but under "Advanced", HTTPS-only, with a mandatory key backup first; steer users to SSE-KMS or a vault |
| 3 | Keychain layout for keys | Same single item, top-level `keys`; `version: 3` only when keys exist; guarded recovery Save |
| 4 | Passphrase KDF | age scrypt for stock-tool recovery; not Argon2id |
| 5 | Store the passphrase-wrapped identity in the bucket | Yes by default with an enforced strong passphrase, because loss of device plus kit is otherwise total; offer "device-only" as an advanced choice |
| 6 | Bind ciphertext to object name | No; keep server-side copy and rename working, and document the swap and rollback limit |
| 7 | Filename encryption | No |
| 8 | `.age` suffix on keys | Yes; free detection in listings and self-describing downloads |
| 9 | Where transfers encrypt on desktop for MVP | Python engine, routed like `storageAction`; other engines later |
| 10 | Post-quantum vault keys | Classic X25519 for MVP with the limit stated to users; add `age1pq` recipients in B3 |
| 11 | Default copy behaviour for provider encryption | Preserve the source mode on every engine |

**Main risks and mitigations.**

- **Lost keys (irreversible).**
  - Mandatory recovery kit, proven by decrypting a canary before uploads are enabled.
  - Keys survive profile deletion.
  - No automatic key deletion; typed confirmation for manual deletion.
- **Keychain overwrite after a denied prompt, or after a downgrade (irreversible for SSE-C).**
  - Fail-closed bundle version 3.
  - Non-secret key index in state JSON.
  - Destructive-confirmation guard on recovery Save.
- **Format or implementation bug producing unreadable data.**
  - Standard format with external vectors and reference-CLI interop in CI.
  - Verify after upload: HEAD size equals `C(P)`, then decrypt the header, first and last chunk using the vault identity rather than the cached file key. Optional full read-back.
  - Never delete the local source.
  - In-place conversion deletes the original only after verification and explicit confirmation.
- **Keystream reuse if a source file changes during a retried part.** Source snapshot checks, the per-chunk digest guard, and one file key per attempt.
- **Secret leakage outside the Keychain.**
  - Extend all log sanitisers.
  - Keep keys out of profile JSON, recovery manifests and exports.
  - Replace the plaintext SHA-256 metadata.
  - Clear decrypted preview caches on lock.
- **Provider drift.** SSE-C defaults, compatible-store behaviour and age library APIs all changed within the last year. Keep capability states `unknown` until proven, and re-check the tagged items at implementation time.
- **Misplaced confidence.** The lock badge must never imply names, sizes or deletion are protected; the vault creation screen states the section 5 limits.

## Sources

- [AWS: Default SSE-C setting for new buckets FAQ](https://docs.aws.amazon.com/AmazonS3/latest/userguide/default-s3-c-encryption-setting-faq.html)
- [AWS: Blocking or unblocking SSE-C for a general purpose bucket](https://docs.aws.amazon.com/AmazonS3/latest/userguide/blocking-unblocking-s3-c-encryption-gpb.html)
- [AWS: Using SSE-C](https://docs.aws.amazon.com/AmazonS3/latest/userguide/ServerSideEncryptionCustomerKeys.html) and [Specifying SSE-C](https://docs.aws.amazon.com/AmazonS3/latest/userguide/specifying-s3-c-encryption.html)
- [AWS API: ServerSideEncryptionRule](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ServerSideEncryptionRule.html)
- [AWS: Specifying DSSE-KMS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/specifying-dsse-encryption.html) and [Using DSSE-KMS](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingDSSEncryption.html)
- [AWS Storage Blog: advance notice on disabling SSE-C by default](https://aws.amazon.com/blogs/storage/advanced-notice-amazon-s3-to-disable-the-use-of-sse-c-encryption-by-default-for-all-new-buckets-and-select-existing-buckets-in-april-2026)
- [Amazon S3 Encryption Client: overview](https://docs.aws.amazon.com/amazon-s3-encryption-client/latest/developerguide/what-is-s3-encryption-client.html) and [concepts](https://docs.aws.amazon.com/amazon-s3-encryption-client/latest/developerguide/concepts.html)
- [Microsoft: customer-provided keys for Blob storage](https://learn.microsoft.com/en-us/azure/storage/blobs/encryption-customer-provided-keys)
- [Microsoft: encryption scopes for Blob storage](https://learn.microsoft.com/en-us/azure/storage/blobs/encryption-scope-overview)
- [Cloudflare R2: S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/)
- [Backblaze B2: server-side encryption](https://www.backblaze.com/docs/cloud-storage-server-side-encryption)
- [Ceph RGW: encryption](https://docs.ceph.com/en/latest/radosgw/encryption/)
- [MinIO: server-side encryption](https://docs.min.io/community/minio-object-store/administration/server-side-encryption.html)
- [Wasabi: SSE-C](https://docs.wasabi.com/docs/how-does-sse-c-encryption-work-with-wasabi.md)
- [Google Cloud Storage: customer-supplied encryption keys](https://docs.cloud.google.com/storage/docs/encryption/customer-supplied-keys) and [simple migration from S3](https://docs.cloud.google.com/storage/docs/aws-simple-migration)
- [C2SP age specification](https://raw.githubusercontent.com/C2SP/C2SP/main/age.md)
- [filippo.io/age Go package](https://pkg.go.dev/filippo.io/age)
- [age v1.3.0 write-up (third party)](https://www.x-cmd.com/blog/251230)
- [str4d/rage](https://github.com/str4d/rage)
- [Dart cryptography package](https://pub.dev/documentation/cryptography/latest/cryptography/) and [cryptography_plus fork (throughput figure)](https://pub.dev/documentation/cryptography_plus/latest/)
- [rclone crypt forum thread on chunk size](https://forum.rclone.org/t/crypt-documentation-error/35386)

### Critical Files for Implementation

- `/Users/sndstone/Documents/Object-browser/engines/python/src/main.py`
- `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart`
- `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/services/app_state_repository.dart`
- `/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/services/mobile_storage_transfers.dart`
- `/Users/sndstone/Documents/Object-browser/contracts/engine_contract.json`
