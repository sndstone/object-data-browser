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
- iOS uses the Data Protection Keychain only. Keep credentials in the consolidated `profiles.credentials.v2` item and preserve the same secure-recovery boundaries used on macOS.
- Public iOS builds require a provisioned Apple signing identity and the stable `TEAM_ID.com.example.s3BrowserCrossplat` Keychain group. Unsigned builds are compile-verification artifacts only.
- Keep iOS cleartext access limited to local-network endpoints through `NSAllowsLocalNetworking`; do not enable global arbitrary loads without an explicit App Review and security decision.
- Windows MSI installers must always be strictly per-user (`Scope="perUser"` in WiX v4, `InstallScope="perUser" InstallPrivileges="limited"` in WiX v3) so installation and updates never require Administrator/UAC elevation. Install under `LocalAppDataFolder` (`%LOCALAPPDATA%\Programs\Object Data Browser`), use `HKCU` `<RegistryValue KeyPath="yes">` key paths (never per-machine `ProgramFiles64Folder` or `ALLUSERS`), and include `<RemoveFolder On="uninstall">` for every created user-profile directory.

## Encryption (optional features)

- Provider-side object encryption, client-side encryption and the key file are optional and off by default. With nothing configured, every engine request and every stored byte must be identical to a build without these features. Keep the default-off tests passing in the app and in every engine. One deliberate exception: a copy or rename repeats the source object's reported encryption mode and KMS key when its details are loaded (`_preservedEncryption`), so a rename cannot silently change how an object is encrypted.
- The contract is `contracts/transport_contract.md` ("Object encryption", "Client-side encryption"). Engines and the mobile adapter implement it; do not add per-engine variations.
- Customer keys (S3 SSE-C, Azure customer-provided keys), age file keys, vault identities and the key-file passphrase are secrets. They must never reach logs, traces, events, task records, retry descriptors, recovery manifests, checkpoints, benchmark files, state JSON, profile exports or error text. Extend the sanitisers and their leak-scanning tests whenever a new path carries one.
- Encryption keys live only in the passphrase-encrypted key file (`encryption-keys.age`, managed by `EncryptionKeyStore`), not in the Keychain and not in state JSON. This is deliberate, so the file can be backed up and moved to another machine. Profiles store only key IDs, fingerprints and age recipients. Never store the passphrase and never unlock the file automatically.
- The key file may be synced through one bucket the user assigns (`KeyFileSync`). Only the encrypted file leaves the device, and only when sync is configured. Sync requires a passphrase of at least 16 characters, uses the pure-Dart storage client on every platform, and accepts only S3-type profiles with static credentials. Automatic writes require a trusted endpoint that enforces both conditional PUT preconditions. Other endpoints may still supply keys for local import or merging.
- Key-file changes merge per key by revision and device (`mergeKeyFileDocuments`); deletions leave tombstones. Keep the merge commutative, associative and idempotent, and never drop key material to resolve a conflict. A failed sync never reverts a local change or deletes anything remote.
- A passphrase changed on this device stays this device's passphrase: `passphraseChangePending` is kept until the bucket copy has been re-encrypted. Only a passphrase changed elsewhere is adopted.
- The key file and every client-encrypted object use the age v1 format unmodified, so both remain readable with the stock `age` tool. Do not add custom headers, metadata requirements or format variants. Do not implement ciphers by hand; use each platform's maintained primitives.
- An engine implements only the payload cipher. Each upload gets a fresh header, file key and payload nonce from the host; a retry gets new ones. Never reuse a file key or nonce for different content.
- Never upload plaintext into a location covered by a client-encryption rule. When the active engine lacks `object.clientEncryption`, refuse the upload.
- A download publishes plaintext only after every chunk has authenticated. Previews decrypt in Dart within the existing preview limits and never show unauthenticated bytes.
- Multipart sizing for client-encrypted uploads applies to the ciphertext length. Keep the S3 limits and add boundary tests when changing it.
- A denied write is never retried with a different encryption mode.
- The "Bucket encryption" form edits a projection of the bucket's encryption document. It must keep every rule and field it does not model (for example `BlockedEncryptionTypes`), re-read the live document before writing and refuse when it changed or when that read failed or was skipped (`bucketAdminReads` counts completed reads), and offer only "Edit as JSON" when the document cannot be represented. Hide the server form only when an engine reports `bucket.encryption` as `unsupported`; `unknown` means "not tried yet".
- Encryption saved outside the Connections editor (bucket dialog, Settings → Encryption) is rebased into an open profile draft by `saveProfile`. Keep that: a stale draft must never switch encryption off.
- Name encryption is optional, off by default and host-only. Engines receive stored keys, plus a sensitive `fileName` only for decrypted downloads. Compose AES-SIV from pointycastle CMAC and CTR in RFC 5297's 256-bit key form (pointycastle's CMAC accepts AES-128 keys only); keep the RFC 5297 appendix and `contracts/vectors/vault-names.json` tests passing. Engines redact the `fileName` field but never scrub its value from output text: a file called `a` would corrupt job status fields.
- Name keys are derived from the age identity only while unlocked, never stored, and wiped with their decode memo on lock or disposal. Decode names only at UI boundaries; diagnostics, traces, events, persisted tasks and retry metadata keep stored keys.
- Refuse an upload into a name-encrypting rule when names cannot be encrypted; never fall back to a plaintext name. Refuse an unsupported vault policy, never downgrade it. Validate every stored key against the 1,024 UTF-8 byte limit before the first upload.
- Administrative writes into a vault location go through the `storageAction` guard. A copy or directory move transfers stored bytes unchanged, so only confirmed empty folder markers may enter a vault location that way. Non-root marker ingress is allowed only for rules with names off; what the location already holds may move inside it or be restored onto its own key. History copies into a range that overlaps a vault rule are refused, and so is a directory move onto an ancestor of a vault location. The rule's own prefix marker is never encrypted and may always be created or copied from a confirmed empty source.
- Visible text typed for a name-encrypting location is never sent to an engine untranslated. When the key file is locked and a name cannot be translated, refuse or fall back to a stored folder that is already known; never send the typed text. The same holds for a rule with an unsupported policy, which may hide every name. Text and regex version filters are applied in the app and sent to engines as an empty value whenever the bucket has a vault rule.
- Under a rule with names off, names are plaintext by the rule's own setting and typed text is sent as typed. The exception is an older encoded tree: where the loaded listing or the current folder shows encoded names below that rule's prefix, an unresolved typed name is treated as hidden: sealed when the keys are available, refused when they are not. Evidence from another rule (also a nested one) or bucket does not count.
- A rule that hides names needs a folder prefix: empty, or ending in `/`. The rule editor refuses anything else.
- Paths typed outside the object browser (a bucket copy's source prefix, Azure directory administration) are not translated. Where names may be hidden they must already be in stored form (every segment a token), or name something a provider listing returned; otherwise refuse before any request or checkpoint is written.
- Some engine handlers trim a bucket name, key or prefix, and they do not agree on which characters count. The host does not model each engine: for a profile with vault rules it refuses a write target that reaches a vault location, or a different rule, once any number of spaces or control characters are removed from its ends (`_guardTrimmedVaultKey`), and a benchmark or test-data prefix that has any at its ends. Upload handlers also turn backslashes in a name into slashes, drop leading slashes, and one drops a blank prefix; two engines trim the mapped name itself; and an HTTP client may resolve `.` and `..` segments in the request path, even out of the bucket. A write whose target could be read into a vault location in any of these ways is refused (`vaultTargetIsAmbiguous`, checked for every upload file, folder marker and `storageAction` target before dispatch; the generated-data check refuses dot segments in its prefix). A key whose `..` climbs above its own root is refused outright, because what lies above it depends on the endpoint. With a vault rule anywhere in the connection, a bucket argument must be a plain name (`vaultBucketIsCertain`: letters, digits, `.`, `-`, `_`, `$`) and may not differ from a rule's bucket only in case; anything else is refused before dispatch, because it may be trimmed, resolved or lower-cased into another bucket on the way. The Go Azure client also escapes the container name.
- Under a rule with names off, a stored name counts as encoded only if it opens with a loaded key, provided the rule's own key is loaded; without that key (locked, or not in the key file) its shape alone counts.
- Generated benchmark and test data is not encrypted. Refuse to start or resume either when the keys it will write can lie in a vault location. Check the key prefixes the engines really use (`_benchmarkKeyPrefixes`, `_testDataKeyPrefixes`), not the text as typed, and update them when an engine changes how it names generated objects.
- Engine text about a download published under a hidden name is dropped, not string-replaced.
- Two vault rules may not share a bucket and prefix. Refuse the second one instead of replacing the first.

## Storage providers

- Provider templates only prefill connection fields. They add no protocol, no secret fields and no capability claims, and `providerTemplateId` never reaches an engine.
- Google Cloud Storage (native) profiles use `endpointType: googleCloudStorage`. The service-account key JSON is the profile's secret and is stored only through `ProfileSecretStore`. Python and Go implement it; Rust, Java and mobile report it as unsupported. Tokens, resumable session URIs and signed URLs are secrets for redaction.
- An unknown `endpointType` is an error. It must never be treated as S3.

## Object previews

- Inline previews remain deliberately bounded: text loads at most the controller byte limit and images respect the image-size limit.
- Ready text and image previews expose `Open preview`. Text opens as selectable, scrollable content; images open in an `InteractiveViewer` with pan and zoom.
- Detect source languages from the object key and content type. Code previews use parsed syntax highlighting while remaining selectable; ordinary text remains unhighlighted.
- HTML expanded previews default to highlighted source. The `Render page`/`View source` control exists only inside the expanded preview, and switching modes must animate horizontally with a fade.
- Render HTML as static widgets. Do not execute scripts or automatically open links from untrusted objects; relative resources may resolve against the presigned object location.
- Expanded preview windows must show the object key, content type, close control, and truncation notice when applicable.
- Presigned preview requests require the macOS `com.apple.security.network.client` entitlement.

## Multipart transfers

- Automatic upload sizing is enabled by default and is calculated in `MultipartSizing` independently for each file. Multi-file selections are coordinated as one parent UI job with sequential per-file engine requests and bounded parallel part workers inside each request.
- Keep sizing within S3 limits: 5 MiB–5 GiB per part, no more than 10,000 parts, and no more than 50,000 GiB per object. The last part may be smaller than 5 MiB.
- The automatic policy targets about 128 parts for ordinary large files, caps normal performance-oriented parts at 128 MiB to bound worker memory, and grows beyond that only when required to remain below 10,000 parts.
- Each dispatched upload contains one file and its chosen part size; the existing engine request shape remains stable. Aggregate bytes/status belong to the parent upload, and per-file outcomes nest beneath it in the event log. Stop queued files on cancellation or unknown engine outcomes.
- When `dynamicMultipartSizing` is disabled, pass the user’s manual `multipartChunkMiB` value, clamped to the S3 part-size range. Downloads continue using the manual range size.
- Preserve bounded parallel part workers and abort incomplete multipart uploads on failure.

## Settings legibility

- Field captions, helper text and switch subtitles use theme text styles and stay at 12.5 px or larger on desktop (13 px on phones) at 100 % UI scale. Do not set literal font sizes in settings code.
- UI text wraps; it is never clipped or ellipsized. Keep captions short and put units and explanations in helper text. Only user data may be shortened, and then the full value needs a tooltip or a copyable value.
- Keep `test/settings_legibility_test.dart` passing: every section at 1000, 1280 and 390 px wide, at 100 % and 150 % UI scale, with no overflow.
- On desktop layouts the Upload button opens an anchored popup menu; compact layouts keep the bottom sheet.

## Verification

- Run `flutter analyze` and the full Flutter test suite after app changes.
- Add boundary tests when changing multipart sizing.
- After touching encryption code, run the engine vector tests against `contracts/vectors/age-stream.json`, and run the Flutter age and key-store tests with `AGE_BIN` pointing at a reference `age` binary to prove interoperability both ways.
- Flutter tests that wait on real file or isolate work must alternate `tester.runAsync` with `tester.pump`; continuations of awaited I/O run in the test zone and do not advance inside `runAsync` alone.
- For macOS packaging changes, build the release app, verify its signature, and inspect the effective signed entitlements.
- For iOS changes, build the simulator target and verify both the Keychain and local-network flows on a physical device before release.
