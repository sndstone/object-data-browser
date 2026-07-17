# Object Data Browser Agent Guide

## Security and profile persistence

- Endpoint credentials must never be written to the JSON state file or profile exports. Persist them through `ProfileSecretStore`; state JSON contains profile metadata only.
- Keychain Sharing requires a provisioned Apple signing identity. Repository-produced ad-hoc artifacts are therefore re-signed without sandbox entitlements so the legacy macOS Keychain remains available; do not apply `keychain-access-groups` to an ad-hoc build because Xcode will reject it.
- Developer ID builds set `OBJECT_BROWSER_MAC_KEYCHAIN_MODE=data-protection` and use the Data Protection Keychain as primary. Ad-hoc development builds use the legacy Keychain as primary. In either mode, probe the other implementation as a read-only migration fallback.
- Store all profile credentials in the single `profiles.credentials.v2` Keychain item. Startup may read that item once; do not return to per-profile or per-field reads because an updated ad-hoc signature can trigger one macOS authorization dialog per item.
- Keep `flutter_secure_storage` on 10.3.1 or newer. The old macOS 3.1.3 implementation incorrectly included `kSecUseDataProtectionKeychain` in `SecItemUpdate` attributes and returned `errSecParam` (`-50`) when an existing credential bundle was saved. Even on newer versions, do not call `readAll` against the legacy Keychain.
- Bulk-migrate `profile.<id>.<field>` items only when the source is the Data Protection Keychain. The legacy file-based Keychain rejects the plugin's bulk data-and-attributes query with `errSecParam` (`-50`); request one-time credential re-entry instead of falling back to per-field reads and multiple authorization prompts. Keep legacy cleanup out of startup.
- Skip the Keychain write when only non-secret application state changed and the encoded credential bundle is unchanged.
- A metadata-only import must preserve the credentials of an existing profile with the same ID. A new imported profile with empty credentials remains empty and must be completed by the user.
- A credential-bearing import is an explicit secure-recovery boundary, like profile Save: persist the merged credential bundle to `ProfileSecretStore`, clear the hydration error only after that write succeeds, and never copy imported secrets into state JSON. Repository-generated exports remain metadata-only.
- `AppSettings.defaultProfileId` is the startup endpoint preference and is separate from the last runtime `selectedProfileId`. Prefer the configured default when it still exists; fall back safely when it was deleted.
- Never report a profile as saved when secure persistence failed. Keep it usable for the current session and show the session-only warning.
- Never silently start an authenticated bucket listing after Keychain hydration fails. Surface the credential-store error and let the user re-enter and save credentials first.
- After a Keychain hydration failure, ordinary state persistence must remain blocked so empty in-memory credentials cannot replace stored values. An explicit profile Save is the recovery boundary: it may create a fresh consolidated credential item and clears the error only after that secure write succeeds.
- Public macOS releases must use the Developer ID signing/notarization path, its embedded provisioning profile, and the stable `TEAM_ID.com.example.s3BrowserCrossplat` Keychain group. Ad-hoc artifacts are development-only and must never be published as update-safe releases.
- When changing sandbox state, load the newest metadata state from the sandboxed and unsandboxed Application Support locations. Credentials remain in Keychain; never copy them into the state file during this migration.

## Object previews

- Inline previews remain deliberately bounded: text loads at most the controller byte limit and images respect the image-size limit.
- Ready text and image previews expose `Open preview`. Text opens as selectable, scrollable content; images open in an `InteractiveViewer` with pan and zoom.
- Detect source languages from the object key and content type. Code previews use parsed syntax highlighting while remaining selectable; ordinary text remains unhighlighted.
- HTML expanded previews default to highlighted source. The `Render page`/`View source` control exists only inside the expanded preview, and switching modes must animate horizontally with a fade.
- Render HTML as static widgets. Do not execute scripts or automatically open links from untrusted objects; relative resources may resolve against the presigned object location.
- Expanded preview windows must show the object key, content type, close control, and truncation notice when applicable.
- Presigned preview requests require the macOS `com.apple.security.network.client` entitlement.

## Multipart transfers

- Automatic upload sizing is enabled by default and is calculated in `MultipartSizing` from the largest file in the selected upload batch.
- Keep sizing within S3 limits: 5 MiB–5 GiB per part, no more than 10,000 parts, and no more than 50,000 GiB per object. The last part may be smaller than 5 MiB.
- The automatic policy targets about 128 parts for ordinary large files, caps normal performance-oriented parts at 128 MiB to bound worker memory, and grows beyond that only when required to remain below 10,000 parts.
- All files in one dispatched upload use the chosen batch part size so the existing engine contract remains stable.
- When `dynamicMultipartSizing` is disabled, pass the user’s manual `multipartChunkMiB` value, clamped to the S3 part-size range. Downloads continue using the manual range size.
- Preserve bounded parallel part workers and abort incomplete multipart uploads on failure.

## Verification

- Run `flutter analyze` and the full Flutter test suite after app changes.
- Add boundary tests when changing multipart sizing.
- For macOS packaging changes, build the release app, verify its signature, and inspect the effective signed entitlements.
