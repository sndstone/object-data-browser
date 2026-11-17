## Summary

The repository supports two protocol families through three profile types, but Azure was added through conditional dispatch rather than a reusable provider interface. The highest-value expansion is a qualified S3 preset catalog, backed by more precise capability reporting; native GCS should follow after separating preview reads, credentials, versions, and transfer constraints from S3 assumptions. ADLS already has useful Python HNS functionality and should be extended rather than implemented again. Azure parity includes gaps within Go as well as the explicit Rust/Java exclusions. This was a read-only review: no files changed, builds/tests/installations/network requests ran, or remote state changed; no disposable artifacts were created, so cleanup freed approximately 0 bytes.

## Abstraction assessment

**1. Introduce a small provider interface before adding a third protocol — severity high, effort L, confidence confirmed**

Where:

| Layer | Verified seam a new provider must touch |
|---|---|
| Profile types, labels, decoding | `apps/flutter_app/lib/models/domain_models.dart:50`, `:65`, `:189`, `:322` |
| Profile normalization and engine eligibility | `apps/flutter_app/lib/controllers/app_controller.dart:114`, `:2656` |
| Profile editor/auth/default endpoint | `apps/flutter_app/lib/settings/settings_workspace.dart:1306`, `:1360`, `:1412`, `:1571` |
| Mobile dispatch and transport | `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:25`, `:88`; `apps/flutter_app/lib/services/storage_http_client.dart:30` |
| Mobile advanced actions | `apps/flutter_app/lib/services/mobile_storage_admin.dart:175`; `apps/flutter_app/lib/services/mobile_azure_storage.dart:34` |
| Python parsing/client/provider dispatch | `engines/python/src/main.py:315`, `:394`, `:708`, `:2120`, `:5955` |
| Python cross-provider copy | `engines/python/src/main.py:5698` |
| Go parsing/client/provider dispatch | `engines/go/src/main.go:205`, `:317`, `:368`; `engines/go/src/azure.go:39`, `:464` |
| Rust dispatch/profile/client | `engines/rust/src/main.rs:243`, `:2462`, `:2549` |
| Java dispatch/profile/client | `engines/java/src/main/java/com/example/s3browser/Main.java:303`, `:1944`, `:2065` |
| Contract | `contracts/engine_contract.json:16`, `:64`, `:69`; `contracts/transport_contract.md:18` |

What happens now: shared code predominantly distinguishes Azure from everything else. For example, `supportsProfile` accepts every non-Azure endpoint type, while unknown serialized endpoint types decode as `s3Compatible`. Python and Go intercept Azure requests ahead of their ordinary S3 dispatch; mobile branches on a Boolean `azure`.

Why it matters: copying this pattern for GCS, B2, Swift, and file protocols multiplies provider conditionals and risks routing an unfamiliar provider into S3.

Proposed change: retain the existing transport and core method names, but introduce:

- `ProviderAdapter`: profile validation, capabilities, containers, paged listing, object read/write/delete/copy, and optional administration.
- `ProviderDescriptor`: auth modes, namespace semantics, version semantics, transfer constraints, sharing modes, metadata/tag support.
- Provider-specific implementations of request construction, signing, pagination, error normalization, and upload sessions.
- A strict provider registry: unknown provider values fail explicitly rather than becoming S3.

Following the Azure pattern remains adequate for **S3 connection presets and narrow Azure extensions**. A limited extraction is justified before another native protocol; a complete rewrite of all engines is unnecessary.

**2. Decouple authenticated preview reads from public sharing URLs — severity high, effort M, confidence confirmed**

Where: `apps/flutter_app/lib/controllers/app_controller.dart:3875`; `apps/flutter_app/lib/services/storage_http_client.dart:532`; `contracts/engine_contract.json:48`.

What happens now: `_loadObjectPreview` first calls `generatePresignedUrl`, then fetches preview content through that URL. The mobile S3 implementation constructs an AWS SigV4 URL and clamps expiry to seven days.

Why it matters: a provider can support authenticated reads without supporting an independently usable URL. SFTP, SMB, many WebDAV deployments, and OAuth-backed services would otherwise lose previews or require unsafe credential-bearing URLs.

Proposed change: add a bounded `readObjectRange` or `readPreview` operation returning bytes plus content metadata, validators, and truncation information. Separate `object.readRange` from `object.shareLink`; sharing results should describe expiry, audience, required headers, and revocation where applicable. Preserve existing text/image limits and static HTML rendering.

**3. Model operation semantics and limits explicitly — severity medium, effort L, confidence confirmed**

Where: `apps/flutter_app/lib/services/multipart_sizing.dart:3`; `apps/flutter_app/lib/controllers/app_controller.dart:1674`; `apps/flutter_app/lib/models/domain_models.dart:418`, `:462`; `engines/python/src/main.py:1003`; `contracts/engine_contract.json:64`.

What happens now:

- Flutter selects upload chunks using S3 limits before dispatch.
- Azure already has a separate Python block-sizing policy.
- Bucket administration contains S3-shaped fields such as versioning status, delete-marker cleanup, Object Lock, and lifecycle JSON.
- The contract mostly leaves parameters untyped; `storageAction.action` is an unconstrained string.

Why it matters: resumable GCS sessions, B2 large files, Swift segments, and file writes have different constraints. Object generations, snapshots, revision IDs, and delete markers are not interchangeable.

Proposed change: add typed, additive descriptors for:

- Upload mode: `single`, `multipart`, `block`, `resumable`, `segmented`, `stream`.
- Minimum/alignment/maximum chunk size, maximum parts/object size, and parallelism.
- Version kind, opaque revision identifier, delete-marker support, and restore semantics.
- Hierarchical directories, atomic rename, conditional copy/delete, metadata, tags, retention, and sharing.

Keep `MultipartSizing` and its mandated S3 bounds intact for S3. Dispatch other providers to their own policies while preserving sequential parent uploads, bounded workers, cleanup, and uncertain-outcome handling.

**4. Extend the consolidated credential schema before adding native auth — severity high, effort M, confidence confirmed**

Where: `apps/flutter_app/lib/models/connection_options.dart:3`; `apps/flutter_app/lib/services/app_state_repository.dart:53`, `:223`, `:368`, `:412`, `:460`; `apps/flutter_app/lib/services/profile_secret_store.dart:42`.

What happens now: secure persistence retains only `accessKey`, `secretKey`, and `sessionToken`. `_credentialFields` explicitly selects those fields. `EndpointProfile.toJson` includes credentials for runtime serialization, while the repository separately strips them from exports and writes metadata-only state.

Why it matters: simply adding `serviceAccountJson`, `refreshToken`, or `privateKey` to a profile model would not make it survive secure hydration. Putting these fields in `ConnectionOptions` would violate its nonsecret purpose.

Proposed change: introduce a typed credential payload stored **inside the existing `profiles.credentials.v2` item**, with backward-compatible record decoding. Extend hydration, encoding, validation, import merging, export stripping, explicit Save recovery, and unchanged-bundle detection together. Keep project IDs, tenant IDs, client IDs, scopes, root folders, and endpoint settings in metadata; keep private keys, service-account JSON, passwords, application keys, refresh tokens, and confidential-client secrets in `ProfileSecretStore`. No per-provider Keychain items or ordinary OAuth token files.

## S3-compatible presets

**5. Add connection presets separately from administration presets — severity medium, effort M, confidence confirmed**

Where: `apps/flutter_app/lib/settings/settings_workspace.dart:1571`, `:1595`; `apps/flutter_app/lib/browser/storage_preset_dialog.dart:159`; `apps/flutter_app/lib/models/storage_presets.dart:75`, `:92`, `:162`.

What happens now: the profile editor offers generic S3-compatible, AWS, and Azure types. `storage_preset_dialog.dart` generates access policies/ACLs and lifecycle rules; it does not configure provider endpoints. Its access generator uses S3 ARNs and validates AWS IAM principal ARNs. Lifecycle generation already rejects AWS tier presets on compatible endpoints and permits configured custom classes.

Why it matters: entering an endpoint successfully does not establish support for AWS policies, principals, lifecycle transitions, or administration.

Proposed change: introduce a profile-level `S3ProviderPreset` catalog containing endpoint templates, signing region, addressing preference, known-bucket guidance, storage classes, and conservative capability hints. Keep all these profiles as `endpointType=s3Compatible`; add a nonsecret `providerPresetId`. Feed verified dialect information into administration presets rather than assuming AWS policy compatibility.

The following is an **offline qualification backlog**, not a verified deployment recipe. **Every external provider fact below is unverified — check current docs.** Source inspection confirms the application seams above, not current cloud behavior.

Notation: **P** = path style; **V** = virtual hosted. Addressing entries are candidate defaults, not claims that every alternative is unsupported.

| Provider | Candidate HTTPS endpoint and signing region | Addressing/signature | Divergences to establish before enabling capabilities |
|---|---|---|---|
| Cloudflare R2 | `<account>.r2.cloudflarestorage.com`; `auto`; jurisdiction-specific authority may apply | P candidate; SigV4 | Historically lacks S3 versioning, ACLs, and object tagging; qualify lifecycle, retention/Object Lock, current checksum support, multipart ceiling, and presigning on API versus custom domains. |
| Backblaze B2, S3 API | `s3.<region>.backblazeb2.com`; exact bucket region, e.g. `us-west-004` | P/V; SigV4; application-key ID/key | Version/hide-marker semantics, restricted keys and bucket discovery, limited ACL/policy model, lifecycle and Object Lock mapping, tagging support. Do not equate all B2 native actions with S3 operations. |
| Wasabi | `s3.<region>.wasabisys.com`; regional signing value | P/V; SigV4 | Qualify versioning, lifecycle, ACLs, tags, and Object Lock; distinguish retention settings from billing/minimum-storage rules. Test SDK checksum and streaming-body behavior. |
| DigitalOcean Spaces | `<region>.digitaloceanspaces.com`; regional value | V preferred, P to qualify; SigV4 | Versioning availability/control, lifecycle subset, canned ACLs, tagging/Object Lock and policy support. Use origin API endpoint rather than CDN for signing. |
| GCS XML/HMAC | `storage.googleapis.com`; candidate `auto`/documented interoperability region | P/V; qualify AWS SigV4 HMAC dialect | Generations are not S3 delete-marker history; IAM/uniform bucket access affects ACLs; lifecycle, labels/tags, retention and multipart management differ. Verify HMAC key creation and XML operation coverage. |
| Oracle OCI | `<namespace>.compat.objectstorage.<region>.oraclecloud.com`; OCI region | P preferred; SigV4 with customer secret keys | Namespace-aware endpoint; versioning/delete-marker mapping, lifecycle/retention, ACL/policy/tag coverage and region behavior require qualification. |
| IBM COS | `s3.<location>.cloud-object-storage.appdomain.cloud`; endpoint-associated location | P/V; HMAC SigV4 | IAM API keys are not HMAC credentials. Qualify regional/cross-region signing, lifecycle tiers, versioning, ACLs, tags, retention/Object Lock dialect. |
| Alibaba OSS | `oss-<region>.aliyuncs.com`; region/dialect needs confirmation | V candidate; AWS-S3 versus OSS signing compatibility must be proved | Do not promise generic S3 compatibility from an OSS endpoint alone. Qualify signer, policy/ACL syntax, versioning, lifecycle, WORM, tags, multipart and listing dialects first. |
| Tencent COS | `cos.<region>.myqcloud.com`, bucket often includes `-<APPID>` | V candidate; qualify AWS SigV4 compatibility versus COS signing | Account-qualified bucket names; verify ACL/policy dialect, versioning, lifecycle, tags, Object Lock/retention and compatibility SDK settings. |
| Scaleway | `s3.<region>.scw.cloud`; e.g. `fr-par` | P/V; SigV4 | Qualify versioning, supported storage classes/lifecycle transitions, ACLs, tags and retention/Object Lock by region/product. |
| Hetzner | `<location>.your-objectstorage.com`; e.g. `fsn1` | P/V to qualify; SigV4 | Establish versioning, lifecycle, ACL, policy, tagging and Object Lock coverage; verify multipart and checksum interoperability. |
| Linode/Akamai | Account-provided cluster endpoint; historical pattern `<cluster>.linodeobjects.com` | P/V to qualify; endpoint-specific region | Do not infer newer endpoint generations from historical names. Qualify versioning, lifecycle, ACL/policy, tags and Object Lock per endpoint generation. |
| OVH | `s3.<region>.io.cloud.ovh.net`; product-region value | P/V to qualify; SigV4 | Separate S3 product from Swift offerings. Verify archive/lifecycle behavior, versioning, ACLs, tags, retention and regional differences. |
| Storj | `gateway.storjshare.io` or supplied gateway; commonly `us-east-1` candidate | P candidate; SigV4 gateway credentials | Gateway capability subset: qualify versioning, lifecycle, ACL/policy, tagging, Object Lock and multipart behavior. Do not substitute native access grants for S3 keys. |
| IDrive e2 | Account-provided regional endpoint, historically `<region>.idrivee2-*.com` | P/V and signing region from account/docs | Avoid inventing endpoint suffixes. Qualify versioning, lifecycle, ACLs, tags, Object Lock, multipart and signed URLs against the selected region. |
| Ceph RGW | Operator URL; configured zonegroup/API region | P; V requires operator DNS/TLS; SigV4 | Release/configuration-dependent versioning, lifecycle, ACL/policy, tags, Object Lock, listing and checksum behavior. Detect deployed features, not brand alone. |
| MinIO | Operator URL; configured region, often `us-east-1` | P; V requires configured domain/DNS; SigV4 | Deployment/release-dependent lifecycle tiers, versioning, tags and Object Lock; qualify ACL behavior and checksum headers. Existing generic endpoint configuration is usable. |
| Garage | Operator URL and configured region | P; V requires configured root domain; SigV4 | Partial S3 implementation: establish versioning, lifecycle, ACL/policy, tagging, Object Lock, multipart and ListObjectsV2 coverage for the installed release. |
| SeaweedFS | Operator S3 gateway URL, often port `8333`; configured region | P; V requires gateway/domain configuration; SigV4 | Gateway/configuration-dependent bucket administration, versioning, lifecycle, tags, ACLs and Object Lock. Verify listing and multipart compatibility against the deployed version. |

For **every row**, qualification must cover the remaining requested dimensions:

- **Multipart:** actual minimum/maximum part sizes, part count, object ceiling, abort/list-parts behavior, empty objects, and completion ambiguity. The app’s S3 limits are implementation constraints, not proof of each service’s limits.
- **Checksums:** required MD5/checksum headers, supported algorithms, `aws-chunked`/trailers, streaming SigV4, and SDK integrity defaults.
- **ListObjectsV2:** delimiter/common prefixes, opaque continuation, URL encoding, unusual keys, empty advancing pages, and whether V1 fallback is necessary.
- **Presign:** accepted signature dialect, maximum expiry, credential-expiry cap, version targeting, required headers, and API/custom-domain restrictions. Do not assume seven days merely because the client permits it.
- **Administration:** separately establish versioning, lifecycle, ACL/policy, Object Lock, bucket tags and object tags. Unknown remains unknown; permission denial is not evidence of missing implementation.

**6. Make capability reporting consistent and evidence-based — severity high, effort M, confidence confirmed**

Where:

- `engines/python/src/main.py:2222`
- `engines/go/src/main.go:221`
- `engines/rust/src/main.rs:253`
- `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:34`
- `apps/flutter_app/lib/services/mobile_storage_admin.dart:185`
- `apps/flutter_app/lib/models/domain_models.dart:404`
- `apps/flutter_app/lib/services/mobile_storage_admin.dart:656`

What happens now: Python and Rust advertise broad supported capability sets; Go marks compatible-endpoint operations unknown and distinguishes implementation availability. Mobile broadly reports support except selected Azure cases, while mobile `providerInfo` separately calls compatible-provider support unknown and can list AWS storage classes by default. Mobile object listing specifically uses ListObjectsV2 and URL encoding.

Why it matters: provider hints, engine implementation, endpoint support, bucket configuration, and caller permissions are distinct. Current descriptors can disagree and do not express the provider limits needed by the catalog.

Proposed change: extend descriptors with implementation state, endpoint state, permission state, evidence/source, scope, and limits. Add explicit flags for object/bucket tags, ACLs, Object Lock, versions/delete markers, multipart inspection, checksum modes, listing dialect, and sharing. Use safe reads and observed operation results; never mutate cloud state merely to detect capability. Preserve denied/unknown rather than converting them to supported or unsupported.

**7. Retain the checksum compatibility fix; add qualification, not another blanket workaround — severity low, effort S, confidence confirmed**

Where: `engines/python/src/main.py:394`; `engines/go/src/main.go:414`; `engines/rust/src/main.rs:2516`; `engines/java/src/main/java/com/example/s3browser/Main.java:2065`.

What happens now: all four desktop clients use checksum calculation/validation “when required” for compatible endpoints, while AWS retains “when supported” behavior.

Why it matters: the newer AWS SDK default-integrity-checksum behavior is already addressed in current source. Reporting it as an outstanding blanket defect would duplicate a shipped fix.

Proposed change: keep these defaults and qualify provider-specific required headers, streaming payloads and algorithms. Only add a narrowly scoped override when a fixture and current provider documentation justify it.

## Native providers

**8. GCS is the strongest next native object provider; scope semantics before SDK integration — severity medium, effort L, confidence likely**

Where: `contracts/engine_contract.json:20`, `:36`, `:48`; `apps/flutter_app/lib/models/domain_models.dart:189`; `apps/flutter_app/lib/services/app_state_repository.dart:368`; `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:56`.

What happens now: there is no native GCS/B2/Swift/Azure Files profile type. The existing methods provide reusable browser operations, while credentials and advanced administration remain tied to existing provider shapes.

Why it matters: these providers can reuse much of the browser but cannot truthfully implement every S3 administration or sharing method.

Proposed change: use the following mapping as design scope. **All external API/auth descriptions and SDK candidates in this section are unverified — check current docs.** Effort and bundle impacts are estimates, not measurements.

| Provider | Auth and secure fields | Mapping to existing contract | Methods/semantics requiring gates or additions |
|---|---|---|---|
| **GCS JSON API** | Service-account JSON/private key; OAuth access/refresh tokens. Metadata: project, client ID, scopes, billing project. Secrets in consolidated bundle. | Buckets remain buckets; object names/prefixes; generation as opaque version; resumable upload session; rewrite/copy; custom metadata. | No S3 delete-marker equivalence; separate generation/metageneration preconditions. Labels/resource tags differ from S3 tags. Signed URLs require a signing identity or signing service, not merely any OAuth token. IAM, lifecycle and retention need native schemas. |
| **B2 native** | Application-key ID/key; authorization token and returned service endpoints managed in memory. Persist long-lived key material securely. | Buckets, file names/prefixes; file ID as version; large-file start/upload-part/finish; native copy; `fileInfo` metadata. | Hide markers differ from S3 delete markers. Download authorization is not general S3 presigning. Separate key restrictions, retention/legal hold and lifecycle rules. Native multipart listing/cleanup needs native session identifiers. |
| **OpenStack Swift** | Keystone application credential ID/secret or supported username/password/project/domain; refreshable scoped token. Metadata includes auth URL, region/interface, project and container. | Account containers as buckets; object names/prefixes; COPY where available; metadata headers; segmented DLO/SLO uploads. | Versions/history depend on middleware; no universal S3 version IDs/delete markers. TempURL requires enabled middleware and secret management. ACLs, lifecycle expiration and tags differ; no generic S3 multipart/Object Lock equivalence. |
| **ADLS Gen2/HNS** | Reuse Azure Shared Key/SAS/Entra; tenant/client metadata and secure token material if interactive auth is added. | Filesystems as buckets; real directories; DFS append/flush; native directory rename; Blob interoperability where supported. | HNS must be observed. POSIX ACLs are not S3 ACLs; rename can be native rather than copy/delete. Versioning/snapshot availability must be qualified for HNS accounts. Separate Blob/DFS authorities and native directory actions. |
| **Azure Files** | Account key/SAS and supported Entra REST modes; secure secrets in bundle. Metadata: account/share and service endpoint. | Shares as buckets; actual directories; file create plus range writes; share snapshots as distinct revision scope; copy and SAS where supported. | Share snapshots are not object-version history. No S3 multipart, lifecycle JSON, object tags or Object Lock equivalence. File properties, SMB ACLs, leases and quotas require provider-specific models. |

Native upload-session URLs and authorization-bearing URLs must be treated as credentials. Persist only nonsecret recovery metadata unless a session secret is explicitly stored through `ProfileSecretStore`; do not put bearer URLs into ordinary checkpoints or logs.

Suggested SDK scope and effort, **Python / Go / Rust / Java / Dart mobile**:

| Provider | SDK candidates and maturity assessment, all unverified | Effort P/G/R/J/D | Expected incremental bundle pressure; release scope |
|---|---|---|---|
| GCS JSON | Python `google-cloud-storage`, Go `cloud.google.com/go/storage`, Java `google-cloud-storage`: established official candidates. Rust official/community client and feature maturity need checking. Dart Google API/auth clients plus streaming REST. | L/L/XL/L/L | Potentially substantial Python/Java dependency graphs; Go/Rust growth unmeasured. Ship Python + Go first; mobile after OAuth and bounded streaming qualification. |
| B2 native | Python `b2sdk`: established candidate. Go/Rust/Java community SDKs or direct REST; verify maintenance and coverage. Dart direct REST. | M/L/L/L/L | Moderate Python SDK risk; a focused REST adapter may be smaller elsewhere. Python first; Go only if native-only value justifies overlap with S3. |
| Swift | Python `python-swiftclient`/Keystone auth; Go Gophercloud; Rust/Java community clients need maintenance review; Dart REST. | L/L/XL/L/L | Identity stacks can dominate Python/Java growth. Python + Go for demonstrated OpenStack demand. |
| ADLS Gen2 | Official Python/Go/Java Data Lake clients are candidates; Rust support needs checking; existing Dart Azure transport can be extended. | M/L/L/L/L | Lowest incremental Python/Go path may reuse current REST/auth instead of adding storage SDKs. Python + Go first. |
| Azure Files | Official Python/Go/Java Azure Files clients are candidates; Rust maturity uncertain; Dart REST. | L/L/XL/L/XL | Additional Azure SDK modules/transitives. Python + Go first, demand-led; defer mobile initially. |

Effort includes meaningful browser integration and qualification, not only constructing an SDK client. It excludes packaging certification and live-provider testing.

**9. Treat file protocols and personal-cloud drives as a separate expansion track — severity medium, effort L, confidence likely**

Where: `contracts/engine_contract.json:20`, `:23`, `:36`, `:48`; `apps/flutter_app/lib/controllers/app_controller.dart:3878`; `apps/flutter_app/lib/services/mobile_storage_dispatch.dart:243`; `apps/flutter_app/lib/services/multipart_sizing.dart:3`.

What happens now: the contract assumes buckets, object keys, synthetic folder markers, object-version operations, and presigned URLs.

Why it matters: file trees and ID-based drives need navigation, identity and permission models that an object-key façade cannot always preserve.

Proposed change: require stable item IDs distinct from display paths, explicit root/namespace types, real-directory support, provider-aware conflict preconditions, and authenticated preview reads before these backends.

All external details below are **unverified — check current docs**.

| Backend | Auth/secrets | Contract mapping and missing equivalents | SDK candidates; effort P/G/R/J/D; bundle/scope |
|---|---|---|---|
| **SFTP** | Password or private key/passphrase; store securely. Host-key fingerprint/trust policy is metadata; never auto-accept changed keys. | Configured roots as namespaces; real directories; seek/write and rename. No portable server copy, tags, versions, lifecycle, Object Lock or presigned URLs. “Resume” is verified offset/source reconciliation, not multipart completion. | Paramiko; `pkg/sftp` + SSH; Rust `ssh2`/`russh`; Java SSHJ; Dart `dartssh2`, maintenance unverified. **L/L/L/L/XL**. Crypto/native-library pressure varies. Python + Go initially. |
| **WebDAV** | Basic/digest or deployment-specific OAuth; password/tokens secure. | Roots/collections; PROPFIND, GET/PUT, COPY/MOVE; properties as metadata. Versioning only with applicable extensions; chunk upload is server-specific. No universal tags, lifecycle, retention or signed sharing. | Python WebDAV client/HTTP; Go WebDAV client/HTTP; Rust HTTP/community; Java Sardine/HTTP; Dart HTTP/XML. **M/M/L/M/L**. Focused HTTP implementation has comparatively modest potential overhead. Python + Go first. |
| **SMB** | Domain/user/password or Kerberos integration; credentials secure, no auth-setting changes. | Shares as namespaces; real files/directories; range I/O, rename, permissions. Snapshots are server-specific; no universal object tags, lifecycle, S3 multipart or sharing URL. Copy depends on server/client facilities. | Python `smbprotocol`; Go SMB client; Rust client maturity uncertain; Java SMBJ; Dart likely native bridge. **L/L/XL/L/XL**. Kerberos/native stacks may be substantial. Desktop-only, demand-led. |
| **Google Drive** | OAuth PKCE; refresh tokens secure; service accounts only where applicable. Client ID/scopes/root IDs in metadata. | Drives/root folders as namespaces; stable file IDs; revisions, resumable upload, copy, custom properties. Duplicate names and non-tree relationships require IDs. Native document exports need MIME negotiation. | Official Google clients in Python/Go/Java; Rust community/generated clients; Dart Google APIs/auth. **XL/XL/XL/XL/XL**. Cloud SDK/auth growth; defer to separate file-browser scope. |
| **Dropbox** | OAuth PKCE and refresh token; app metadata separate from secrets. | Root namespaces/team spaces; paths plus IDs; revisions; upload sessions; copy/move; sharing APIs. Properties are not S3 tags; links have permission/revocation semantics. | Official Python/Java candidates; Go/Rust/Dart maintenance needs checking or REST. **L/L/XL/L/L**. Moderate SDK/auth pressure; Python + Go pilot only after file model. |
| **OneDrive** | Microsoft identity OAuth PKCE; secure refresh tokens; tenant/client/scopes/drive IDs in metadata. | Drives/items; item IDs and versions; upload sessions; asynchronous copy; sharing links. Provider facets, permissions and deleted-item recovery differ from S3. | Microsoft Graph Python/Go/Java candidates; Rust/Dart REST or generated clients, maturity unverified. **XL/XL/XL/XL/XL**. Generated Graph clients may be large; focused REST may reduce dependencies. Defer. |

None should emulate absent lifecycle/policy/encryption/Object Lock methods with successful no-ops. Unsupported operations must stay explicit. A “share link” must not silently make a private item public.

Bundle context is already improved: `docs/resource-review-2026-11-04/implementation.md:82` records approximately 378 MiB for its development sample, with Python 181,608 KiB and Java 143,320 KiB. These replace the older review’s larger baseline; they are not measurements of proposed SDK additions. Current dependency entry points are `engines/python/requirements.txt:2`, `engines/go/go.mod:5`, `engines/rust/Cargo.toml:6`, and `engines/java/build.gradle.kts:9`. Measure installed and compressed deltas before accepting any new dependency family.

## Parity debt

**10. Azure parity means more than removing Rust/Java guards — severity medium, effort L, confidence confirmed**

Where:

- Rust exclusion: `engines/rust/src/main.rs:2550`
- Rust advertised providers: `engines/rust/src/main.rs:251`
- Java exclusion: `engines/java/src/main/java/com/example/s3browser/Main.java:1945`
- Flutter eligibility: `apps/flutter_app/lib/controllers/app_controller.dart:2661`
- Go Azure exclusions: `engines/go/src/azure.go:480`, `:521`
- Go Entra copy restriction: `engines/go/src/azure.go:472`
- Reference-adapter routing: `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:62`

What happens now: Rust and Java reject Azure during profile parsing. Go implements core Azure operations, but explicitly rejects tools, version operations, signed URL generation and S3-shaped administration methods. Advanced desktop operations deliberately use Python regardless of the selected transfer engine.

Why it matters: the feature matrix’s “Azure supported” shorthand does not mean ordinary methods have identical coverage. Removing a parser guard would still leave S3 clients and semantics underneath.

Proposed change:

- Rust: Azure adapter, Shared Key/SAS/refreshable Entra auth, paging, conditional copy/delete, blocks/ranges, metadata/tags, provider error mapping, progress, benchmark primitives, and capability descriptors.
- Java: equivalent adapter while retaining its existing interactive transfer-control guarantees.
- Both: retain existing download validation/publication and multipart cleanup boundaries.
- Go: decide whether versions, signed links, tools and delegated-source copy belong in native parity or remain explicitly Python-reference features.

Estimate: **L per Rust/Java for core Azure browsing/transfers; XL per engine for full reference-workflow parity**. Retaining Python-only advanced administration is reasonable; all-engine duplication is not a prerequisite for new providers.

Error normalization also needs provider ownership: Python’s generic mapper handles botocore (`engines/python/src/main.py:642`), Go handles Smithy API errors (`engines/go/src/main.go:3458`), Rust requires conversion into AWS S3 errors (`engines/rust/src/main.rs:4577`), and Java checks `S3Exception` (`engines/java/src/main/java/com/example/s3browser/Main.java:3353`). Preserve common error codes while adding `provider`, `serviceCode`, HTTP status and outcome certainty; do not label new-provider errors `awsCode`.

**11. Mobile Entra requires an auth lifecycle, not a bearer-header field — severity medium, effort L, confidence confirmed**

Where: `apps/flutter_app/lib/controllers/app_controller.dart:2657`; `apps/flutter_app/lib/services/mobile_azure_storage.dart:37`, `:403`; `apps/flutter_app/lib/services/storage_http_client.dart:30`; `engines/python/src/main.py:731`; `engines/go/src/azure.go:104`.

What happens now: Flutter rejects non-static/non-SAS mobile auth. The Azure mobile adapter explicitly reports identity and management-plane authentication unavailable. Desktop Python/Go obtain refreshable Azure credentials. Mobile Shared Key can mint scoped SAS; an existing SAS cannot mint a narrower grant.

Why it matters: allowing `azureDefault` in the UI would not supply interactive mobile authentication, refresh, scopes, or user-delegation signing.

Proposed change: add explicit mobile interactive Entra auth using a maintained platform library or PKCE flow—**library availability/configuration unverified — check current docs**. Add tenant/client/scopes metadata, secure refresh material in the consolidated bundle, token refresh and cancellation, account-selection/sign-out semantics, and distinct storage/management scopes. Do not enable a library’s ordinary token-file persistence alongside `ProfileSecretStore`. Add user-delegation SAS only when supported and authorized; retain explicit SAS attenuation restrictions.

Physical-device Keychain/local-network and identity qualification remains required before release; no such qualification occurred in this review.

ADLS is partly implemented already: `engines/python/src/advanced_workflows.py:761` observes HNS before directory actions, and `:775` restricts endpoint pairing to recognized public-cloud Blob/DFS authorities. A first-class ADLS type should reuse this implementation and deliberately address sovereign/private endpoint support rather than bypassing its proof requirement.

## Recommendation

**12. Deliver breadth through presets, then add native protocols selectively — severity medium, effort L, confidence likely**

Where: `apps/flutter_app/lib/models/domain_models.dart:50`; `apps/flutter_app/lib/models/connection_options.dart:5`; `contracts/engine_contract.json:64`; `contracts/transport_contract.md:18`; `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:62`.

The value ranking below is a product/engineering judgment; demand has not been measured.

| Rank / phase | Deliverable and value versus effort | Contract/model changes |
|---|---|---|
| **1 — Qualified S3 catalog** | Broadest provider coverage for least protocol work. Start qualification with R2, B2 S3, Wasabi, Spaces, MinIO/Ceph; stage remaining endpoints behind evidence. | Keep `s3Compatible`; add `providerPresetId`, endpoint templates, region/addressing hints and verified storage classes. Add granular capability evidence/limits. No new secret fields. |
| **2 — Provider foundation** | Prevents each native provider from recreating Azure conditionals. Required before GCS or file protocols. | Strict provider decoding; adapter registry; authenticated range reads; version/namespace descriptors; upload modes/limits; typed credentials within the existing consolidated item. Extend contract schemas. Bump contract version if shapes change incompatibly. |
| **3 — Azure completion and ADLS** | Builds on working implementations and closes visible inconsistencies. Prioritize Go versions/sharing and first-class HNS before full four-engine advanced parity. | Add `azureDataLakeGen2`; Blob/DFS endpoint metadata; `filesystem.hns`, `directory.rename`, `directory.acl`, and version restrictions. Reuse existing Azure secrets; add secure interactive tokens only with mobile Entra work. |
| **4 — Native GCS** | Highest-value new native object API: OAuth/service accounts, generations and native resumable uploads. Python + Go first. | Add `gcsJson`; project/billing/auth metadata; secure service-account JSON/private key and OAuth refresh token. Generation/metageneration conditions; resumable upload; native IAM/lifecycle/retention actions; signing capability separate from reading. |
| **5 — Demand-led B2 native or Swift** | B2 native provides incremental features beyond its cheaper S3 route; Swift unlocks a different installed base. Choose based on actual requests. | `b2Native` or `openStackSwift`; B2 key ID/application key and native file IDs, or Keystone metadata/application credentials. Native session/version/sharing descriptors and operation gates. |
| **6 — WebDAV/SFTP pilot** | Useful desktop breadth after the file identity model exists. Python + Go; avoid committing all engines/mobile at once. | `webDav`, `sftp`; root namespaces/item identity, real directories, authenticated previews; secure password/private key/passphrase; host-key trust metadata. Disable absent object-store administration. |
| **7 — Azure Files, SMB, personal drives** | Highest semantic and qualification cost; defer until demand warrants it. | `azureFiles`, `smb`, `googleDrive`, `dropbox`, `oneDrive`; share/drive/item IDs, snapshot/revision scopes, permissions, upload sessions and sharing policy. Provider-specific secure credentials/tokens. |

Rust/Java Azure **core** parity can run as an independent product priority after the adapter boundary is established. Requiring every native provider to ship simultaneously in four engines would substantially increase cost without following the project’s existing Python-reference model.

## Checked and fine

- Metadata-only exports and consolidated secure persistence are already separated: `apps/flutter_app/lib/services/app_state_repository.dart:237`, `:368`.
- Ordinary persistence remains blocked after failed secure hydration; unchanged credential bundles skip writes: `apps/flutter_app/lib/services/app_state_repository.dart:372`, `:385`.
- Compatible-endpoint checksum defaults are already present in all desktop engines; no repeat fix is proposed.
- Advanced desktop operations deliberately select Python and prohibit uncertain mutation replay: `apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart:62`.
- HNS is proven before ADLS directory actions: `engines/python/src/advanced_workflows.py:761`.
- Compatible lifecycle presets already avoid blindly applying AWS tiers: `apps/flutter_app/lib/models/storage_presets.dart:166`.
- Download validators and unknown-mutation boundaries are documented in `contracts/transport_contract.md:31`, `:48`; preserve them for every adapter.
- Existing unrelated untracked review directories were left untouched. No builds, tests, formatting, staging, credentials, authentication settings, or remote repositories were changed.

## Not covered

- Current provider documentation, live-cloud behavior, SDK maintenance status, exact provider multipart/presign limits, and region/product availability. These remain **unverified — check current docs**.
- Provider-specific installed-size measurements, throughput benchmarks, OAuth registration, tenant policy, and physical-device flows.
- Exhaustive audit of native Android/iOS bridges and every advanced administration action. Generic compatible `listBuckets`/`testProfile` can still route to native bridges (`apps/flutter_app/lib/services/mobile_storage_dispatch.dart:7`), so preset qualification must include those paths.
- Full executable provider conformance testing. No tests were run because this task explicitly required static, read-only review.
- No publication steps are required for this report. Future remote publication or third-party repository changes remain for the coordinator to obtain specific approval and execute.