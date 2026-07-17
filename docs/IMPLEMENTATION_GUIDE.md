# Implementation Guide

## Transport Model

Desktop engines run as sidecar processes. The Flutter shell talks to them through a versioned JSON transport. Android engines expose the same logical methods through platform channels and native adapters.

Desktop request envelope:

```json
{
  "requestId": "req-123",
  "method": "listObjects",
  "params": {},
  "engineVersion": "1.0"
}
```

Desktop response envelope:

```json
{
  "requestId": "req-123",
  "ok": true,
  "result": {},
  "error": null
}
```

Progress event envelope:

```json
{
  "event": "transferProgress",
  "payload": {
    "jobId": "transfer-1",
    "progress": 0.42
  }
}
```

## Pagination Rules

- `listBuckets` returns all visible buckets for the endpoint.
- `listObjects` must honor `prefix`, `delimiter`, and `cursor`.
- `cursor` is opaque to the UI and owned by the engine.
- Hierarchical mode uses `delimiter="/"`.
- Flat mode leaves `delimiter` empty.

## Transfer Rules

- Transfers are always represented as `TransferJob`.
- Start methods return immediately with a job descriptor.
- Progress is reported asynchronously.
- Cancel requests must be idempotent.
- Pause/resume may return `unsupported_feature` on engines or targets that cannot honor them.
- The app shell decides default destination paths; engines only receive resolved filesystem paths.
- Dynamic multipart sizing is enabled by default for uploads. The shell inspects the largest file in the batch and sends one effective part size to the engine.
- The sizing policy targets roughly 128 parallelizable parts, caps ordinary part sizes at 128 MiB to bound the memory used by concurrent workers, and increases the size when necessary to stay below 10 000 parts.
- Every non-final S3 part must be at least 5 MiB, no part may exceed 5 GiB, and an upload may contain at most 10 000 parts. See the [Amazon S3 multipart limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html).
- When automatic sizing is disabled, `multipartChunkMiB` is the upload override. It is clamped to S3's valid range. Downloads always use the manual value as their byte-range size.
- Parallel part requests are intentional: AWS recommends multiple concurrent connections for throughput. See [S3 multipart upload guidance](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html).

## Error Handling Rules

- Engines never return stack traces as user-facing messages.
- `message` is concise and safe for direct display.
- `details` may contain structured diagnostics for the diagnostics workspace.
- Unsupported target capabilities must return `unsupported_feature` with a `capabilityKey`.

## Temp and Download Path Rules

- Default download directory is the platform Downloads directory.
- Default temp directory is the platform temp directory.
- Settings may override both with absolute paths.
- The shell validates and creates missing directories before dispatching transfer requests.

## UI Expectations

- Unsupported features stay visible but disabled with an explanation.
- Workspace changes should preserve context when practical.
- The app must stay interactive while listing, transferring, or benchmarking.
- Long-running operations must surface progress and recovery actions.
- Ready image and text previews provide an expanded dialog. Images support pan/zoom; text is selectable and scrollable; truncated text identifies the loaded byte count.
- Recognized code extensions and content types use parsed syntax highlighting in both inline and expanded source previews. Unrecognized plain text keeps the ordinary monospace presentation.
- HTML opens as highlighted source by default. Only the expanded dialog exposes `Render page`; it switches to a static, non-scripted HTML widget render and animates horizontally. `View source` returns to the code representation.

## Credential Persistence

- Application state and exported profile JSON never contain access keys, secret keys, or session tokens.
- Desktop credentials are stored through the platform secure store. Developer ID releases use the Data Protection Keychain with a provisioned, team-scoped access group, giving every signed update the same credential identity. Ad-hoc development builds use the legacy encrypted Keychain because they cannot claim the provisioned group.
- Startup probes the non-primary macOS Keychain implementation as a read-only migration fallback, then consolidates recovered values into the active primary bundle. This supports migration in both directions without duplicating routine reads.
- A sandbox transition changes the macOS Application Support path. Startup compares the sandboxed and unsandboxed state files and loads the newer metadata file; subsequent saves use the active build's normal location. Neither state file contains credentials.
- All profile credentials are encoded into one versioned Keychain item. This limits an updated ad-hoc build to one credential authorization instead of separate prompts for every field or profile. Ordinary settings saves do not touch Keychain when the credential bundle is unchanged.
- Secure-storage 10.3.1 or newer is required on macOS. Earlier plugin code passed the Keychain-selection flag as an update attribute, so creating a credential item could work while updating it failed with `errSecParam` (`-50`).
- Existing per-field Data Protection Keychain entries are migrated through one bulk native read and one consolidated write. Legacy file-based Keychain entries cannot be bulk-read reliably: macOS returns `errSecParam` (`-50`) for the data-plus-attributes query. Those users receive a one-time re-entry instruction rather than per-field reads and repeated authorization prompts. Old entries are not deleted during startup.
- Importing metadata for an existing profile preserves its saved credentials when the imported credential fields are empty.
- Import files supplied by the user may contain credentials. A credential-bearing import is treated as an explicit recovery action and writes the merged bundle directly to secure storage; application-generated profile exports continue to strip every credential field. The import is reported successful only after secure persistence succeeds.
- Settings stores a default endpoint profile ID separately from the current runtime selection. Startup prefers that default when the profile still exists, while changing the header endpoint remains a runtime choice.
- If startup cannot read Keychain credentials, it reports the non-sensitive platform error and skips authenticated listing. Background settings persistence remains blocked to prevent empty hydrated fields from replacing secrets; explicitly saving a profile is allowed to repair the consolidated Keychain item after the user re-enters its credentials.
- A secure-store failure leaves the profile available only for the current session and must be reported to the user.
- A hydration failure is shown before any automatic authenticated listing is attempted; it must not degrade into a misleading backend “key not used” error.
- Unsandboxed ad-hoc builds have normal outbound network and user-file access but do not have an update-stable credential identity. Public artifacts are signed with Developer ID, hardened runtime, the embedded provisioning profile, and stable Keychain entitlements, then notarized before distribution.
