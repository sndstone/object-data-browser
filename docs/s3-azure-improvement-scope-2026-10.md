# S3 and Azure improvement scope — October 2026

Reviewed 2 October 2026 against `9e668e5`, app `2.2.8+1`, including the current working tree. The user selected **advanced S3 administration and compatibility** as the main priority. Existing uncommitted UI work was preserved while integrating the additions below.

The recommended sequence is to remove credentials from benchmark state, preserve complex S3 configuration faithfully, establish trustworthy capability and permission reporting, and then deliver access/tiering presets, full-bucket copy across configured endpoints, version-aware operations, and Object Lock administration. The requested S3-compatible delete recovery is an explicit workstream, limited to confirmed non-versioned buckets. Azure transfer performance remains a follow-on workstream.

The expanded user requirements are part of this scope: selectable access presets that generate bucket/endpoint-aware configuration without manual JSON edits; bucket lifecycle tiering presets; full-bucket copy within or between configured endpoints; and normal delete retries followed, for eligible non-versioned S3-compatible buckets only, by individual DELETE and then zero-byte PUT → DELETE recovery. A different fallback for versioned buckets remains deferred pending research.

The original scope and estimates below are retained as the design record. Implementation status is recorded immediately below. [Real local S3 measurements](local-s3-performance.md) now cover all four desktop engines, including verified Go/Rust improvements; cloud throughput remains unmeasured. Estimates below are engineering effort for an experienced contributor, including focused tests and integration work; they are not calendar commitments. Shared mobile administration/benchmark work is included in 2.3.0. Provider-managed identity and account features remain platform/capability gated; public release certification is separate.

**Implementation follow-through — 2 October 2026**

The requested desktop workflows are implemented in the working tree. Advanced administration uses the bundled Python reference adapter; ordinary transfers continue to use the selected engine. An unavailable adapter produces an explicit error, with no replay of uncertain mutations on another engine.

| Area | Implemented behavior |
| --- | --- |
| Access presets | Principal read, read/write without delete, read/write/delete, public object read, HTTPS enforcement, and removal of app-managed grants. Bucket/partition/prefix-aware policy generation preserves custom statements. Private/public-read legacy bucket ACLs are separate selections, blocked by observed ownership/public-access restrictions. |
| Lifecycle presets | Infrequent access, multistage archive, Deep Archive, Intelligent-Tiering, endpoint-configured classes, version cleanup and incomplete-upload cleanup. Editable ages, prefix/tags/size predicates and optional expiration; validation, overlap warnings, stable rule IDs, disable without discarding a rule, preservation of unrelated rules and transition-size behavior, freshness checks and readback. |
| Full bucket copy | Any configured S3/Azure source and destination, optional destination creation, current live objects, exact keys/folder markers, metadata/content headers/tags where representable, skip/replace/fail handling, paged enumeration and bounded streaming. Metadata-only local checkpoints resume completed pages/objects; uncertain overwrite outcomes require inspection instead of automatic replay. S3 history mode additionally copies ordered content versions and delete markers into an empty versioned destination prefix, recording source/destination version mappings. Reviewed configuration plans copy selected lifecycle/CORS/tags/policy/public-access settings after content completes. ACLs, retention grants and original version IDs are not cloned. |
| Delete recovery | All four desktop engines perform bounded retries and individual deletes. Only confirmed never-versioned compatible buckets may use conditional zero-byte PUT then DELETE, with versioning/identity/protection checks, cancellation boundaries and explicit failures/empty objects left behind. AWS, enabled/suspended/unknown versioning and denied reads cannot enter overwrite recovery. The requested additional versioned-bucket fallback remains deferred. |
| Version/Object Lock administration | History pagination, exact-version details/download/share/restore-as-current/delete, marker deletion, bucket retention defaults with days/years, object retention/legal holds and archive retrieval. Python provides the advanced UI actions; Rust/Java also implement exact-version native operations. Governance bypass is not enabled implicitly. |
| Properties and multipart | Tags, metadata, permitted content headers, storage class/encryption edits, extended bucket configuration reads, paginated multipart/part inspection and explicit abort. Recoverable S3 uploads use source fingerprint + remote-part reconciliation and verify-only recovery of unknown completion. Ordinary transfer failures still abort incomplete uploads. |
| Authentication and transport | Nonsecret profile options with secure SAS persistence, named/default/assumed-role AWS providers, known-bucket access, Requester Pays/expected owner, and explicit support gates for TLS/CA options. Python Azure supports Shared Key, SAS and Entra; Go supports Shared Key/SAS and refreshable Entra credentials. Mobile data operations support static S3 credentials/session tokens and Azure Shared Key/SAS; desktop credential chains and Azure management identities are not fabricated on mobile. Azure Identity is included in staged Python dependencies. |
| Performance/correctness | Reusable clients, repeatable file-section upload bodies, bounded parallel Azure blocks/ranges, streaming download ranges, upload-unique block IDs, multipart large-object copy, conditional moves and credential-free continuous benchmarks. The host pins background benchmark processes and reserves their pool slots; current-object details load independently of version-list permission/latency. |

Initial verification before the 2.3.0 follow-through (retained as historical evidence; final checks are in [2.3.0 verification](2.3.0-verification.md)):

- Flutter analysis: no issues. Full Flutter suite: **224 passed, 2 existing skips**.
- Python full contract run: **84 passed, 22 engine-specific skips**.
- Go shared contract/download/failure run: **39 passed, 1 skipped**; native race suite passed (10 tests plus delete-recovery subcases).
- Rust shared/native contract run: **50 passed, 15 provider/control skips**; seven unit tests passed.
- Java shared/native contract run: **51 passed, 14 provider/control skips**; `installDist` succeeded.
- macOS arm64 release-mode development app built; staged adapters compiled and all four packaged health checks passed; the packaged Python source hash matches the working tree; ad-hoc deep/strict signature verification and effective-entitlement inspection succeeded. iOS simulator verification is blocked as described below.
- `git diff --check`: clean. Existing user work remains uncommitted; no deployment or public release was performed.

The initial verification above uses mocked SDKs and local HTTP fixtures, including fake-size >5 GiB objects. A subsequent real MinIO run is recorded below; neither establishes production MinIO/Ceph compatibility, real-cloud IAM/KMS/Object Lock or refreshable identity integration. Shared profile-secret persistence and existing Flutter UI tests remain in the full suite.

**Local S3 performance follow-through — 2 October 2026**

A source-built Go MinIO server and the actual Flutter desktop storage service ran isolated baseline and optimized matrices across Python, Go, Rust and Java. Each matrix passed 108 timed cases, verified 36,864 unique 64 KiB PUT objects, checked 24 SHA-256 round trips of 256 MiB files, and exercised 1,200-object paginated listings. Temporary servers/data were removed; no user profiles or Keychain state were loaded.

The measurements drove two bounded changes: Go checkpoints benchmark reports/state every 250 ms while flushing terminal/control outcomes, and Rust streams upload bodies with 256 KiB file buffers. Median Go single-worker PUT throughput rose from 197.9 to 1,110.4 ops/s; Rust four-worker upload throughput rose from 547.7 to 1,393.0 MiB/s. Workload-mode and Go capability/latency correctness fixes were also added before the baseline. These are same-machine loopback results with warm caches and documented durability differences. See the [methodology, full comparison and repeatable runner](local-s3-performance.md) for limits and remaining investigations.

The 2.3.0 follow-through closes the earlier implementation gaps: S3 version-history and reviewed configuration copy, resumable exact-range downloads and Azure block uploads, Azure account lifecycle presets/container retention/ADLS directory administration, and exact-version SAS generation are implemented through the reference adapter. Shared mobile REST administration, bounded multipart transfers, delete recovery and continuous benchmarks now cover mobile data operations. Histories are limited to 100,000 entries per plan/prefix and require an empty versioned destination; ACL/retention/KMS policy cloning is deliberately excluded. Azure management requires Entra/RBAC and HNS operations require a proven compatible public Azure endpoint.

The user selected local/emulator qualification for this build. Actual MinIO/Azurite checks cover history ordering, delete markers, configuration plans, S3/Azure resume, cross-provider copy, multipart/range byte integrity, tags, and Shared Key signed links. Cloud-only IAM/KMS/Object Lock, account management, user-delegation SAS and HNS semantics have local protocol/mock coverage, not live-cloud certification. Physical-device and public-signing/notarization qualification remain outside this development build. The special versioned stale-metadata overwrite fallback remains deferred as requested.

The arm64 macOS development verification uses local Xcode overrides for architecture and minimum deployment target (12.0) because Xcode 27's universal `lipo -verify_arch` path fails despite both framework slices being present. Project deployment/signing settings are unchanged. The ad-hoc app is re-signed without sandbox/keychain-group entitlements and is development-only. The final iOS simulator build succeeds with per-invocation plugin validation overrides after inspecting the pinned Smithy generator, a local iOS minimum-target override of 15.0 for Xcode 27, and destination-based SDK selection so host code-generation tools compile for macOS. The repository deployment defaults remain unchanged. Android arm64 debug compilation also succeeds.

Azure tier requests retain REST version `2021-12-02`, which supports the Cold tier according to the [Set Blob Tier documentation](https://learn.microsoft.com/en-us/rest/api/storageservices/set-blob-tier).

**Existing foundations worth preserving**

The app already has bucket lifecycle/policy/CORS/encryption/tagging operations, object/version listing, multipart transfers, bounded sidecar admission, lazy browser rows, isolated filtering, and bounded previews. September work added staged download publication, byte-range validation, ETag consistency checks, confirmed Azure copy completion before source deletion, and action-specific cancellation. These are existing capabilities, not new backlog items. See the [feature matrix](FEATURE_MATRIX.md) and [implementation ledger](improvements-implementation-2026-09.md).

**Ordered backlog**

| Order | Workstream | Priority and outcome | Initial engineering effort |
| --- | --- | --- | --- |
| 0 | Remove credentials from benchmark state | P0: keep supplied credentials out of engine JSON files and returned benchmark state | 3–6 days across desktop engines and host routing |
| 1 | Preserve complex lifecycle policies and retention units | P0 release blocker for expanded administration: reading/editing a configuration must not discard its meaning | 4–7 days across desktop engines |
| 1a | Lifecycle tiering presets | P1, user-requested: choose tier schedules and filters without writing JSON | 5–9 days after lifecycle fidelity |
| 2 | Capability, permission, and endpoint compatibility foundation | P1: distinguish unsupported APIs, denied access, missing configuration, and unknown support; allow bucket-scoped connections | 7–12 days for an initial vertical slice |
| 2a | Bucket access and ACL presets | P1, user-requested: generate access rules from the selected bucket, endpoint and principal | 7–12 days after capability/permission modeling |
| 2b | Full-bucket delete recovery | P1, user-requested: bounded normal retries, then individual DELETE and zero-byte PUT → DELETE for eligible non-versioned S3-compatible buckets | 5–9 days across desktop engines and shared fixtures |
| 3 | Complete version workflows | P1: page history, inspect/download/share an exact version, recover prior content, and delete explicit versions/markers | 7–12 days |
| 4 | Object Lock administration | P1: bucket defaults plus per-version retention/legal holds, with accurate units and provider-specific restrictions | 8–15 days |
| 5 | Multipart server-side copy and safer moves | P1: copy large objects and preserve source identity, metadata, and partial outcomes | 8–15 days |
| 5a | Copy full bucket across configured endpoints | P1, user-requested: independent source/destination profiles, server-side copy or bounded relay, verified per-object results | 10–18 additional days for current contents; 6–10 more for history mode |
| 6 | AWS credential providers and enterprise endpoint support | P1: named profiles, refreshable role/SSO credentials, region handling, and Requester Pays context | 10–20 days; SDK-specific support must be verified |
| 7 | Object properties, encryption, and archive restoration | P2: edit tags/metadata/headers, select supported upload encryption/storage class, restore archived objects | Split into 3 slices of roughly 5–10 days each |
| 8 | Multipart administration and durable transfer recovery | P2: inspect/abort orphan uploads first; restart-resume later | 4–7 days for administration; another 10–20 for recovery |
| 9 | S3/browser performance and credible benchmarking | P2: reuse connections, bound transfer memory, lazy-load inspection, measure continuous workloads | 8–15 days for foundation; tune from measurements |
| 10 | Azure transport performance and provider features | P2 under the chosen S3 priority: parallel blocks/ranges, retries, provider sizing, then identity/version/tier features | 8–15 days for transport; identity/features separately |

Efforts overlap in shared contracts, fixtures, and UI, so they should not be added into a delivery promise. Each initial slice should land with one desktop reference engine and explicit capability gates, then reach parity across the desktop engines that advertise it. Do not label a feature universally implemented before parity verification.

**0. Close the benchmark credential-persistence gap**

All four desktop benchmark implementations copy the supplied profile into their run state and serialize that state to a temporary JSON file. The desktop adapter supplies access key, secret key, and session token to the request. This is separate from the secure main application-state implementation and bypasses its metadata-only persistence boundary.

Evidence: [desktop adapter](../apps/flutter_app/lib/services/desktop_sidecar_engine_service.dart), `startBenchmark` around 944 and `_profileToJson` around 1565; Python `_start_benchmark` around 4145 and `_write_benchmark_state` around 3470; Go `startBenchmark` around 2657 and `writeBenchmarkState` around 2517; Rust `start_benchmark` around 2363 and `write_benchmark_state` around 3046; Java `startBenchmark` around 1928 and `writeBenchmarkState` around 2440.

A Python source probe, with network execution disabled and an isolated temporary directory, confirmed that all three fictional credential fields reached the JSON file. The fixture was removed on exit. No existing user credential files were read or printed. The other three engines were verified by following their source serialization paths.

Scope: keep benchmark credentials in the owning process's memory or resolve them through the host from `ProfileSecretStore`; persist only a profile reference and nonsecret run data. Define how status requests reach the owning process, because removing fields from disk alone would break the current polling-based execution model. Return a sanitized public run descriptor, handle process loss explicitly, and safely remove app-owned legacy credential-bearing run artifacts without importing their secrets into application state.

Acceptance: sentinel credentials never appear in benchmark state, result exports, diagnostics, or public responses; active runs still execute after repeated polls, and process restart requires secure reauthorization. This correction is required before adding refreshable AWS/Azure credentials or durable job checkpoints.

**1. Lifecycle fidelity is the first correction**

Rust's `parse_lifecycle_rules` and `lifecycle_rule_raw` support only a subset of the lifecycle schema. Java's corresponding helpers have the same limitation. They omit tag/AND/object-size filters, date-based expiration/transitions, and `NewerNoncurrentVersions`. The read serializer replaces a non-prefix filter with an empty prefix. This affects the JSON exposed to the editor, not merely a compact summary.

Evidence: [Rust engine](../engines/rust/src/main.rs), `parse_lifecycle_rules` around line 2663 and `lifecycle_rule_raw` around 2872; [Java engine](../engines/java/src/main/java/com/example/s3browser/Main.java), `parseLifecycleRules` around 2161 and `lifecycleRuleRaw` around 2305.

A read-only loopback probe supplied a policy constrained to `production/`, a `class=protected` tag, a minimum object size, and five retained noncurrent versions. The existing local Rust release binary returned `Filter: {Prefix: ""}` and omitted the retained-version count. Python source and the existing Go binary preserved those fields. The probe did not save a policy or contact cloud storage; Java was inspected in source only. Existing binaries were not rebuilt for this review.

S3 lifecycle PUT replaces the configuration, and filters determine which objects are affected. Losing predicates can change policy scope or cause validation failure; it must never happen silently. [AWS lifecycle PUT semantics](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketLifecycleConfiguration.html), [filter schema](https://docs.aws.amazon.com/AmazonS3/latest/API/API_LifecycleRuleFilter.html), [retained-version count](https://docs.aws.amazon.com/AmazonS3/latest/API/API_NoncurrentVersionExpiration.html).

Scope: preserve the complete supported schema through read → edit → write; retain fields not modified by structured controls; reject an unsupported representation before dispatch instead of dropping fields. Account for lifecycle options conveyed outside the rules JSON. Add a semantic diff before saving. A read-before-write change check can detect many intervening edits, but must not be presented as atomic compare-and-swap where the API supplies no conditional write.

Also fix Object Lock units: Python, Go, and Java currently put either `Days` or `Years` into `objectLockRetentionDays`; the UI labels it as days. Use `{value, unit}` or distinct fields. See Python `_get_bucket_admin_state`, Go `getBucketAdminState`, Java `getBucketAdminState`, and [bucket inspector](../apps/flutter_app/lib/browser/browser_workspace.dart) around line 1110.

Acceptance: golden configurations containing AND/tag/size predicates, multiple transitions, dates, empty prefixes, retained-version counts, and year-based retention survive round trips in all supported engines. Invalid or unsupported fields produce a field-specific error. Summaries do not become the source of truth for writes.

**1a. Lifecycle tiering presets without JSON editing**

Add a preset selector to bucket Lifecycle, followed by ordinary fields for scope, prefix/tags, object-size limits, transition ages, destination tiers, and optional expiration. Selecting a preset fills valid defaults; Apply enables the generated rule for the selected bucket. Show a readable timeline and effective scope, with generated JSON available only as an optional advanced view. Lifecycle scheduling is a server-side operation, not a local transfer task or a promise of immediate tier movement.

Proposed initial presets:

| Preset | Suggested starting values | User-adjustable fields |
| --- | --- | --- |
| Infrequent access | Transition current objects to Standard-IA at 30 days | Age, prefix/tags and object-size filter |
| Archive older data | Standard-IA at 30 days, Glacier Flexible Retrieval at 90 days | Supported tiers and transition ages; expiration remains off |
| Long-term archive | Deep Archive at 180 days | Age and scope; restoration requirements shown |
| Keep recent versions | Retain five noncurrent versions and expire qualifying older versions after 90 noncurrent days | Count, age and scope; available only with version history |
| Clean incomplete uploads | Abort incomplete multipart uploads after seven days | Age and prefix; separate from completed-object expiration |

These are proposed AWS defaults, not universal endpoint behavior or savings guarantees. Validate supported transitions, minimum durations, and object-size treatment using the selected provider. AWS applies a default small-object transition threshold and storage-class constraints; preserve an existing policy's transition-size behavior when editing it. Explain retrieval delays and applicable early-deletion/transition charges without inventing a price estimate. [AWS lifecycle transition constraints](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html).

For S3-compatible endpoints, use verified provider capabilities or an endpoint's configured tier names; do not advertise AWS Glacier names as usable without evidence. Use stable app-owned rule IDs to update or disable a preset without replacing unrelated rules. Preserve custom predicates and multi-stage schedules, detect overlapping rules, and read back the applied configuration. Turning a preset off stops its rule from scheduling future actions; it does not reverse completed transitions or deletions.

Acceptance: all presets compile to semantically correct configuration for the selected bucket/provider; invalid age order and unsupported tiers are caught in fields; applying twice does not duplicate rules; unrelated rules survive enable/disable; version-only presets remain unavailable for non-versioned buckets. No routine preset workflow requires editing JSON.

**2. Make S3 compatibility explicit and permission-aware**

The desktop `getCapabilities` implementations largely return fixed declarations. They describe engine implementation, not what a particular endpoint, bucket, or identity can do. Python's bucket-admin read also executes several configuration APIs in sequence; an access-denied response from one can fail the combined inspection. Version listing is requested before object details even when only current content is needed.

Evidence: [Python engine](../engines/python/src/main.py), `_get_capabilities` around 1875, `_maybe_call` around 483, `_get_bucket_admin_state` around 2055; [controller](../apps/flutter_app/lib/controllers/app_controller.dart), `_loadSelectionArtifacts` around 3228. The same general static declarations appear in Go, Rust, and Java.

Scope: separate engine support from observed endpoint support, bucket configuration, and current authorization. Preserve partial inspector results and attach status/reason per section. A 403 is not evidence that the provider lacks an API; a missing lifecycle policy is not an unsupported lifecycle API. Discover through safe reads and observed responses, with explicit refresh and bounded caching; never use mutations as capability probes.

Add a known-bucket connection path and profile test that does not require account-wide bucket listing. Python `_test_profile`/`_list_buckets` and Go `testProfile`/`listBuckets` currently call ListBuckets. Support account bucket pagination as well: AWS recommends paginated ListBuckets and rejects unpaginated requests for accounts with an approved quota above 10,000. [AWS ListBuckets](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListBuckets.html).

Compatibility fixtures should cover AWS general-purpose buckets, deployed MinIO and Ceph RGW versions, one additional relevant S3 service, path-style/virtual-hosted addressing, region redirects, TLS/custom CA handling, checksum/trailer behavior, and exact key preservation. Several engine methods trim keys; a legal key containing leading/trailing spaces must retain its identity. Include `+`, `%`, Unicode, XML-sensitive characters, zero-byte objects, and delete markers.

Acceptance: a user with only object-read permission can inspect permitted content even when tags/version history/policy reads are denied. Unknown features remain unknown, unsupported features explain why, and denied sections name the failed operation. Protocol options either work in the selected engine or report unsupported; audit fields such as `signerOverride` and TLS settings against actual use.

**2a. Bucket access presets and legacy ACL support**

Add an Access preset selector with named-principal read-only, read/write without delete, read/write/delete, public object-read, and removal of app-managed public grants. Allow a bucket-wide or prefix scope. A public-read preset need not grant anonymous bucket listing. Show the resulting permissions in plain language, let users select or enter a principal when required, and generate the resource identifiers and JSON internally. Read/write without delete does not prevent overwriting an existing key; state this in the preset description rather than presenting it as immutable storage.

Use the selected bucket name, provider/endpoint capabilities, AWS partition where applicable, and the user's chosen principal/scope. Separate bucket-level and object-level actions and resources. Endpoint URLs and access keys are not principal identities; an endpoint URL also must not be substituted for a VPC endpoint ID. Resolve identifiers where a provider supports it, otherwise ask for them in labeled fields. Escape resource patterns correctly and reject scopes that cannot be represented exactly.

Expose actual canned ACL choices, such as private and public-read, only on the bucket/object targets where they are supported; bucket-owner-full-control is an object-upload/copy option, not a universal bucket-policy equivalent. Prefer bucket-policy presets for AWS buckets with Bucket owner enforced, which disables ACL updates. Respect Object Ownership and Block Public Access and explain incompatible selections; do not silently change those settings to make a preset succeed. [AWS Object Ownership and ACL behavior](https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html).

Manage only app-owned policy statements, using stable statement IDs; preserve unrelated statements, including explicit denies. Disabling a preset removes its statements, not the entire bucket policy. Report grants this app configured separately from effective access, which can also depend on identity policies and other controls. Removing public grants must not be described as proving the bucket private if other grants or ACLs remain. Distinguish a successful policy write from permission verification, and show the exact access changes before Apply.

Acceptance: switching bucket/endpoint regenerates the policy without stale resource names; principals and prefixes do not broaden accidentally; repeated application is idempotent; custom policy statements survive; unsupported ACLs/public-access restrictions produce actionable messages. Include cross-account principals, compatible-provider identities, disabled ACLs, explicit denies, and AWS partition fixtures. Azure access should use its native authorization model rather than sending S3 policy JSON.

**2b. Full-bucket delete with bounded stale-metadata recovery**

Extend the existing `runDeleteAll` implementation and the force-delete-bucket caller. Python `_run_delete_all` around 3275 and Go `runDeleteAll` around 1936 currently count per-item batch errors without a dedicated recovery pass. Python also falls back from version listing to ordinary listing after any exception; that fallback must not be used as evidence that a bucket is non-versioned. The shared `DeleteAllToolConfig` already carries retry controls, so define and enforce their effective behavior across engines before adding more settings.

Apply the requested sequence to each still-failing or persistently listed key:

1. Perform ordinary S3 deletes with the configured bounded retry/backoff policy. Retry transient per-item errors from a successful batch HTTP response as well as eligible request failures; do not keep resending already confirmed entries. Define retry counts as retries after the initial attempt and account for SDK attempts within a shared limit, rather than multiplying nested retry loops. Reconcile ambiguous outcomes and perform bounded verification passes for keys still listed after an apparent success.
2. For a confirmed non-versioned S3-compatible bucket, attempt an individual `DeleteObject` for the exact key using the normal retry policy after the batch attempts are exhausted. Stop if deletion is confirmed.
3. If the individual delete still fails with an eligible stale-metadata condition or the same authorized key persists after verification, perform one zero-byte `PutObject` to that exact key, confirm its outcome, then perform `DeleteObject` with bounded normal retries. This is the user's requested metadata-reset workaround; whether it repairs a particular endpoint must be established in provider qualification.
4. Verify the final outcome and record per-key attempt/result details. If the PUT succeeds but final deletion fails, report **overwritten with an empty object; delete failed**. Do not count it as deleted or imply the old bytes remain recoverable. Limit recovery cycles so a persistently broken key cannot loop indefinitely.

The empty-PUT stage is restricted to the full-bucket-delete workflow on eligible S3-compatible endpoints. Native AWS S3 and Azure stay on their ordinary deletion behavior. It must not run for authorization failures, retention/legal-hold restrictions, a detected concurrent replacement, or an unreconciled network/engine outcome. Use provider-specific error classification plus bounded re-listing to identify candidates; an arbitrary HTTP failure is not proof of stale metadata. Include the empty-overwrite behavior in the existing destructive action summary, without adding a prompt for every object.

Confirm versioning with an authoritative successful response, represented as never-enabled, enabled, suspended, or unknown. A missing/failed API, `versioningEnabled == false`, or an empty version-list page is insufficient. Recheck eligibility before an overwrite and abort that fallback if it changes. Bucket versioning must remain disabled during this operation; a read followed by PUT cannot atomically exclude an external administrator changing the setting.

For **enabled or suspended versioning**, use only normal retries against the exact listed version IDs and delete-marker IDs, including literal `null` IDs. Do not substitute key-only deletion for a failed version deletion. Unknown versioning state likewise excludes empty PUT and any new destructive fallback. Suspended buckets can still contain historical versions, and ordinary deletion has different null-version/delete-marker behavior. [AWS DeleteObject semantics](https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObject.html). A special versioned-bucket recovery strategy is explicitly deferred for later research; do not add overwrite, marker rewriting, or another workaround now.

Honor cancellation between every stage, preserve exact keys, and keep the pending work queue bounded. Track confirmed deletions, failed keys/versions, skipped recovery, unknown outcomes, and empty objects left behind separately. Delete the bucket itself only after contents are verified empty and there are no unresolved failures; the force-delete caller must inspect the tool result rather than assuming completion.

Acceptance: fixtures prove the exact retry → individual DELETE → empty PUT → DELETE ordering; normal and individual-delete success cause no PUT; a recovered key is counted once; a failed final delete exposes the empty-object outcome; phantom listings and repeated cursors terminate. Assert zero overwrite PUTs for AWS, Azure, enabled/suspended/unknown versioning, access-denied/locked objects, changed objects, and cancellation before the overwrite stage. Real compatible-provider qualification must use disposable objects and reproduce the relevant stale-metadata behavior before claiming the workaround repairs it.

**3. Turn version history into a recovery workflow**

The engine interface supports version listing and explicit version deletion, but current object detail/download/copy/presign methods identify objects only by key. The controller stores `versionCursor` without a subsequent-page path, and the version rows display information without recovery actions.

Evidence: [engine interface](../apps/flutter_app/lib/services/engine_service.dart), `listObjectVersions`, `getObjectDetails`, `startDownload`, `copyObject`, and `generatePresignedUrl`; [controller](../apps/flutter_app/lib/controllers/app_controller.dart), `versionCursor` and `_loadSelectionArtifacts`; [version UI](../apps/flutter_app/lib/browser/browser_workspace.dart) around line 1710.

Scope: introduce an object reference carrying bucket, exact key, and optional version ID. Propagate it through detail/preview/download/copy/presign and mutation results. Add incremental history paging, selected-version download/preview, copy an old version into a new current version, and explicit deletion of a chosen version or delete marker. Distinguish removing a delete marker from copying historical content; these are different recovery operations.

Acceptance: histories larger than one page work; similarly prefixed keys do not leak into exact-key history; operations target the chosen version despite a concurrent new upload. Preserve literal `null` version IDs as distinct from absence. Test suspended versioning, deleted current objects, permission failures, and partial batch results.

**4. Expand Object Lock with accurate semantics**

Current support includes bucket creation with Object Lock and reading bucket defaults; there is no engine-service API for changing defaults or reading/writing per-version retention and legal holds. The create dialog also says Object Lock must be enabled at creation, which is outdated for AWS general-purpose buckets: AWS supports enabling it on existing versioned buckets. S3-compatible providers still need separate capability checks. [AWS Object Lock configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-configure.html).

Scope: show bucket default retention and exact per-version retention/legal-hold state; support changing defaults and setting/clearing legal holds when permitted. Enable Object Lock on an existing bucket only when supported. Model governance and compliance separately; any governance bypass must be an explicit operation option, never an automatic retry. Explain irreversible settings and show the exact objects/versions affected as part of the relevant mutation flow.

Acceptance: preserve years versus days, test permission denial and protected deletion, and show why a version is retained. Verify against real AWS and a selected compatible service; do not infer retention enforcement from a mock response. Run unit/fixture checks without creating permanently retained objects in general test environments.

**5. Large-object copy and move need their own transfer path**

All four desktop S3 copy handlers call single-request CopyObject. Bucket copy then loops through objects serially in Flutter. AWS requires multipart UploadPartCopy for objects larger than 5 GB. [AWS CopyObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html).

Evidence: Python `_copy_object` around 2480; Go `copyObject` around 1208; Rust `copy_object` around 1105; Java `copyObject` around 890; [controller](../apps/flutter_app/lib/controllers/app_controller.dart), `copyBucketContents` around 4022.

Scope: inspect source size/identity, choose single or multipart server-side copy, bound concurrent parts, preserve intended metadata/tags/encryption/storage class, and abort incomplete multipart copies on failure. Expose progress and per-object outcomes. For move, delete only after destination completion is confirmed and source identity remains protected by the provider's available version/conditional semantics. Do not claim atomic rename for ordinary S3 copy/delete. If a provider cannot protect against source changes, retain the source and report the limitation.

Acceptance: small/large/empty objects, reserved characters, source changes during copy, destination conflicts, failure after copy but before delete, and cancellation. Use simulated sizes/ranges for boundary fixtures and a real object above the API threshold for integration qualification. This transfer path is also the server-side foundation for the cross-profile full-bucket copy below; the current one-profile contract must be extended to support that operation.

**5a. Copy a full bucket to the same or another configured endpoint**

Add a Copy bucket flow with source endpoint/bucket preselected, destination chosen from any configured endpoint, an existing or new destination bucket/container, and explicit conflict handling (skip existing, replace, or fail; skip is the proposed default). Source and destination have independent credentials, regions, engines, addressing, and capabilities. Treat aliases resolving to the same underlying bucket as the same source/destination and reject them before writing.

Default scope is **all current object contents**, including zero-byte objects and folder-marker keys, with paginated traversal beyond the browser's loaded window. Preserve exact keys and supported content headers, metadata and tags. Offer **include version history** where both sides support the required semantics: copy historical content in order, record source-to-destination version mapping, and handle delete markers so a deleted source key is not accidentally made current at the destination. Original provider-generated version IDs and timestamps cannot be promised at the destination. Make unsupported history or attribute mappings explicit before starting rather than silently dropping them.

Choose a strategy per endpoint pair:

| Source and destination | Execution strategy |
| --- | --- |
| Same service with compatible server-side copy and sufficient authorization | Single or multipart server-side copy; retain provider copy IDs and confirm completion |
| Different profiles/accounts on a service | Server-side copy only when a supported authorization path can read the source and write the destination; otherwise relay using the two independent identities |
| Independent S3-compatible services, or S3 and Azure | Bounded download/upload relay with source and destination provider adapters; never assume an S3 CopyObject request can address an arbitrary other endpoint |
| Azure accounts/containers with supported source authorization | Confirmed Azure copy when available; otherwise use the same bounded relay path |

Server-side copy requires appropriate read/write authorization and has provider-specific handling for metadata, ACLs, and encryption. Azure copy can remain asynchronous. [AWS copy requirements](https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html), [Azure Copy Blob](https://learn.microsoft.com/en-us/rest/api/storageservices/copy-blob).

Keep credentials in secure storage/in-memory clients, with only profile references in job checkpoints. For relay, use backpressure and replayable bounded staging; do not buffer an entire bucket or send payload bytes through Flutter/JSON transport. Preserve the sequential per-file engine-request policy and bounded in-file workers. Bind reads to the selected source version or available consistency validator, validate completed bytes and meaningful checksums, and finalize destination multipart uploads only after all required parts succeed. Retry confirmed failures and reconcile unknown completions before creating another destination version.

Represent the operation as a parent job with paginated/disk-backed manifest, aggregate progress, per-object outcomes, cancellation, and retry of failed items. A live bucket listing is not a point-in-time snapshot: report source changes and allow a reconciliation pass. Do not delete source objects or unrelated destination objects. Report data relayed through the local machine and relevant transfer/storage implications.

Bucket configuration is a separate explicit option: apply compatible access/lifecycle presets to the destination or copy reviewed settings with bucket/principal references rewritten and validated. Do not blindly clone public grants, KMS identifiers, retention rules, or source endpoint references. Report any settings that cannot be represented on the destination.

Acceptance: same-endpoint and different-profile copies, independent S3 services, and S3↔Azure/Azure↔Azure paths work for supported adapters. Cover distinct credentials, source-read-only/destination-write identities, more than one listing page, folder-marker keys, zero-byte and large objects, metadata fidelity, alias detection, existing destinations, process loss, source changes, partial failure, and cancellation. A completed job accounts for every enumerated item and labels skipped/conflicting/unmapped items; partial copy is never reported as a complete clone.

**6. Add authentication modes without weakening secret persistence**

Profiles currently carry static access/secret keys and an optional session token. Desktop clients explicitly supply static credentials; they do not expose named AWS profiles, AssumeRole configuration, or an SSO login/refresh workflow. See [profile model](../apps/flutter_app/lib/models/domain_models.dart) around 184 and each engine's client builder.

Scope: represent authentication mode explicitly. First support a selected shared AWS profile and refreshable credential resolution on verified SDKs, then role assumption/MFA and IAM Identity Center workflows. Persist only nonsecret provider configuration and references in state; keep app-owned secrets in `ProfileSecretStore` and preserve its consolidated-bundle and recovery boundaries. Never serialize resolved tokens into job or benchmark state. SDK providers vary by language and platform, so advertise actual coverage. [AWS credential-provider behavior](https://docs.aws.amazon.com/sdkref/latest/guide/standardized-credentials.html).

Add Requester Pays and expected-owner context to applicable requests, region discovery/correction, and endpoint presets that explain effective addressing/signing behavior. Treat access-point ARNs and directory buckets as separate capabilities instead of assuming every bucket accepts the same APIs. Directory buckets have different listing, endpoint, and feature semantics, including no S3 Versioning or Object Lock. [AWS directory-bucket differences](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-differences.html).

Acceptance: temporary credentials refresh during a long transfer, account changes invalidate cached clients, denied roles produce actionable errors, and a profile scoped to a bucket remains usable. Test credential import/export and hydration-failure recovery alongside new authentication fields.

**7. Add the missing object-administration tools in independent slices**

| Slice | Useful first scope | Completion boundary |
| --- | --- | --- |
| Properties | Edit object tags, metadata, Content-Type, Cache-Control and Content-Disposition; preserve unrelated values | Conditional/version-aware writes, reserved-header validation, per-object batch failures; metadata replacement uses the large-copy path where required |
| Encryption and placement | Expose object encryption details and supported upload/copy options for SSE-S3/SSE-KMS and storage class | Distinguish bucket defaults from object overrides; KMS permission errors and unknown outcomes remain visible; defer customer-provided encryption keys until their lifecycle is designed |
| Archive restore | Show archive/restore state, request retrieval for a chosen object version, report pending/available/expired state | Model retrieval options and temporary availability according to storage class; no download success before content is available |
| Bucket administration | Read Public Access Block, Object Ownership, replication and notification configuration | Start with accurate status and permission explanations; authoring replication/notification/IAM-dependent configuration is a separate scope |

These APIs are absent from the current shared engine method set, beyond existing bucket encryption and read-only object properties. Archived-object restore is distinct from version recovery; some archive classes provide a temporary restored copy. [AWS archived-object restoration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/restoring-objects.html).

**8. Multipart maintenance before restart-resume**

The app aborts failed active multipart uploads, but exposes no ListMultipartUploads/ListParts administration, and no engine promises restart-resume. First add paginated upload inspection, age/prefix filters, and explicit abort of selected uploads. This gives administrators a way to find incomplete uploads left by crashes or external clients.

Durable recovery is a larger follow-up: checkpoint upload ID, ordered completed-part identities, source fingerprint, destination, chosen sizing, and state transitions. Store no credentials or signed URLs in checkpoints. On resume, revalidate the local source and reconcile remote parts before reuse. Downloads need staged-file/range manifests bound to a stable remote version. Azure recovery needs block IDs and provider-specific commit semantics rather than pretending it has S3 upload IDs.

Acceptance: process death, expired credentials, changed source, expired/aborted remote upload, and completion with a lost response cannot cause silent corruption or duplicate unexamined mutations. Reconcile unknown outcomes before offering retry.

**9. S3 and browser performance opportunities**

| Observation in current code | Proposed change | How to establish benefit |
| --- | --- | --- |
| Most operations construct a fresh SDK client despite persistent sidecars; Java closes its client per operation | Bounded client/transport reuse keyed by full effective profile/authentication/TLS configuration, with invalidation and disposal | Warm versus cold small-object latency, connection/TLS counts, handles and memory |
| Python, Go, and Rust upload workers read whole parts into memory | Replayable file-section streaming where SDKs support it, otherwise a shared memory budget that limits active buffered parts | Peak RSS across part sizes/concurrency, including manual 2–5 GiB sizes, without allocating huge fixture payloads |
| Selection reads versions before details; bucket configuration reads are bundled | Load only requested inspector sections, cache briefly, cancel obsolete reads, bound independent requests | Request count and time until useful details on a restricted/slow endpoint |
| Listing is capped at 100,000 keys / 16 Mi key characters, and local text/regex filtering applies to loaded data | Preserve those bounds; label filter scope, improve cursor navigation, optionally add a disk-backed searchable inventory later | First-page latency, responsiveness at the listing bound, stable memory over multiple windows |
| Transfer events repeatedly carry accumulated output lines in several engines | Bound retained logs, send incremental updates, coalesce progress at a measured UI-friendly cadence | Transport bytes and rebuild/frame cost during many-part transfers |

The eight-worker cap does not itself bound bytes: eight fully buffered 128 MiB parts imply roughly 1 GiB of payload buffers; manual 5 GiB parts could imply roughly 40 GiB, before SDK overhead. These are calculations from the implementation, not measured RSS. See Python `_upload_one_part` around 2780, Go `startUpload` around 1447, and Rust multipart upload around 1377. Java already has a [file-part stream](../engines/java/src/main/java/com/example/s3browser/FilePartStream.java), which should be retained and reviewed for parity.

Keep the mandated sequential per-file upload dispatch, parent-job aggregation, per-file sizing, bounded part workers, and abort-on-failure behavior. Parallelizing all selected files is outside this scope. Connection reuse and in-file scheduling can improve throughput without changing that policy. AWS also recommends concurrent requests and byte-range fetching for throughput, but actual gains depend on workload and environment. [AWS performance guidance](https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-guidelines.html).

Benchmark measurements now come from real operations, but execution is still driven by status materialization. Python and Java run each tick's operation batch serially; Python/Go/Java also derive a target count from elapsed time × configured threads × 8. Go executes its batch concurrently, and Rust runs concurrent batches within a polling-time budget. These differing schedulers prevent a clean engine-throughput comparison.

Evidence: Python `_materialize_benchmark_state` around 4057, Go `materializeBenchmarkState` around 2551 and `runBenchmarkBatch` around 3088, Rust `materialize_benchmark_state` around 3086, Java `materializeBenchmarkState` around 2444. Replace polling-triggered work with a continuously running bounded workload; status calls should observe it. Add a monotonic clock, warm-up, explicit rate-limited versus maximum-throughput modes, actual concurrency, retry/throttle counts, and bounded latency samples.

Acceptance: changing status-poll frequency does not materially change operation rate; measured concurrency matches the selected limit; all engines use comparable workload/duration semantics. Existing truthful reporting must remain intact.

**10. Azure: improve the transport before expanding parity**

Azure currently uses hand-written Shared Key REST clients in Go and Python. Rust and Java do not support Azure. Both implemented Azure upload paths use a 64 MiB threshold and fixed 16 MiB blocks, sent one at a time; download byte ranges are also sequential. Go's `do` performs one HTTP attempt, and Python uses `urllib.request.urlopen` without an explicit reusable session/retry pipeline. Upload sizing selected by Flutter is not used by these Azure paths.

Evidence: [Go Azure engine](../engines/go/src/azure.go), constants at 26, `do` at 167, `azureStartUpload` at 867, `azureStartDownload` at 998; [Python engine](../engines/python/src/main.py), `_AzureBlobClient` at 588, `_azure_start_upload` at 1230, `_azure_start_download` at 1467; [upload batch](../apps/flutter_app/lib/controllers/upload_batch.dart), `prepare`.

First scope: evaluate official Azure Blob/Identity SDKs in the two existing engines against packaging and endpoint compatibility, then implement bounded parallel blocks/ranges, connection reuse, safe request-level retries with backoff, and Azure-specific size/count validation. Microsoft documents separate block size/concurrency/threshold settings and 50,000-block limits. At the current fixed 16 MiB size, 50,000 blocks hold only 781.25 GiB; larger uploads need a different size or an early explanatory rejection. [Azure tuning](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blobs-tune-upload-download-python), [Azure limits](https://learn.microsoft.com/en-us/azure/storage/blobs/scalability-targets).

Use upload-unique, fixed-length block IDs and conditional commit where supported: current IDs are derived only from block number, so overlapping writes to the same blob need collision protection. Preserve the existing confirmed-copy boundary and staged download validation. Replace the short copy polling window with a durable pending-copy task and explicit reconciliation. Do not add blanket retries around copy/move or other uncertain mutations.

Second scope: Entra ID and SAS authentication, bounded authenticated previews, SAS sharing, blob versions/snapshots/soft-delete recovery, tiers/rehydration, metadata/index tags, and lease visibility. Microsoft recommends Entra ID and, for delegated URLs, user-delegation SAS. [Azure authorization](https://learn.microsoft.com/en-us/azure/storage/blobs/authorize-access-azure-active-directory). Add SAS/token redaction before supporting those modes; a SAS in an endpoint URL must not leak into metadata state or logs.

Account-level management must be separated from container/blob data operations; Azure is not just renamed S3. HNS/ADLS directory operations and ACLs should be a distinct capability slice. Account features differ, and blob versioning is not currently supported for HNS accounts. [Azure account-feature matrix](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-feature-support-in-storage-accounts).

**Delivery and contract boundaries**

Start with a **credential and configuration correctness increment**: credential-free benchmark state, lifecycle fidelity, retention units, golden provider fixtures, and graceful partial admin inspection. The two P0 corrections alone are approximately 7–13 engineering days before broader compatibility work. Next deliver the requested **access and tiering presets** and **non-versioned delete recovery**, based on accurate provider/versioning state. Follow with **version recovery and full-bucket copy across endpoints**, sharing version-aware references and conditional operations. Then deliver **Object Lock and AWS identity**, with properties/archive tooling as separately reviewable increments. Cross-endpoint copy includes the existing Go/Python Azure support; broad Azure transport tuning and Rust/Java/mobile parity remain separate.

Before expanding the API, strengthen [engine_contract.json](../contracts/engine_contract.json): today it enumerates method names but leaves `params` as an arbitrary object. Define method-specific request/result/error schemas and fixtures, provider-aware object references, mutation conditions, and per-section statuses. Add preset identifiers/versions and typed inputs, independent source/destination references for bucket copy, and structured per-key delete-recovery stages/results. Preserve authoritative versioning state rather than relying on a boolean. Additive fields should remain optional with explicit negotiation; breaking shapes require the documented contract-version bump. Extract provider/client, administration, and transfer modules incrementally from the large engine entry points rather than rewriting the application.

Defer S3 Tables/Vectors, broad IAM policy authoring beyond the requested access presets, full replication setup, continuous/bidirectional cross-cloud synchronization, and universal engine/mobile parity. One-time full-bucket copy across configured endpoints is included. A different stale-metadata fallback for versioned buckets is explicitly deferred pending research. Directory-bucket support deserves its own compatibility acceptance matrix when scheduled.

**Verification and evidence limits**

During this review, the Python contract suite passed: `REQUIRE_ENGINE=1 .tmp/toolchains/python/bin/python3 -m pytest tests/contract -q` → **40 passed**. The additional lifecycle probe was read-only and loopback-only, using fictional credentials. Its Python-source, Rust-binary, and Go-binary results are recorded above. A separate isolated Python probe confirmed benchmark credential persistence with fictional values and network execution disabled. Other findings are source observations or explicitly proposed improvements. No real-provider transfer benchmark, new release build, or full four-engine verification was performed. App code was not changed, so Flutter analysis/tests were not rerun for this documentation-only scope.

Implementation acceptance should include:

- `flutter analyze` and the full Flutter test suite after app changes, plus the contract suite for every affected desktop engine.
- Golden lifecycle and version-operation fixtures; 403 versus unsupported versus missing-state tests; exact-key and pagination tests; multipart boundary/failure/cancellation cases.
- Access and tiering preset generation, idempotent enable/disable and preservation of custom configuration; ACL-disabled and restricted-public-access cases; destination-aware resource/principal mapping.
- Full-bucket copy across independent endpoints/credentials/providers with complete pagination, history-mode mapping, bounded relay resources, and source-change/partial-failure recovery.
- Delete-recovery stage ordering, bounded per-item retries, truthful empty-object failure outcomes, and no empty PUT on versioned/suspended/unknown buckets, AWS, Azure, permission/retention failures, or cancelled work.
- Isolated real-provider qualification on AWS and deployed compatible-provider versions; Azure and Azurite for the Azure slice. Emulators alone cannot establish KMS, Object Lock, IAM, or service-limit behavior.
- A performance matrix of many small objects, 64 MiB–1 GiB objects, and a large multipart object; low/high latency, throttling, disconnects, and credential refresh. Capture throughput, p50/p95/p99 latency, RSS, CPU, retries, request counts, connection reuse, and cancellation latency. Record dataset, endpoint, SDK, engine, machine, and effective settings. Choose speed targets after the baseline; do not promise an unmeasured multiplier.
- Preserve secure profile persistence, bounded previews, truthful unknown mutation outcomes, and all existing transfer invariants. For affected Apple packaging/native changes, follow the repository's signing, entitlement, simulator, and physical-device requirements.
