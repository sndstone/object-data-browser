# iOS Support — Implementation Plan

Status: **iOS v1 implemented on 2026-07-25**. The checked-in target supports
Browser and Settings workflows through the official AWS SDK for Swift. Benchmark
and bucket-encryption mutations remain explicit follow-ups and return
`unsupported_feature`.

This plan is written as a *referenced* plan: every task cites the existing code that
already solves the same problem on another platform, so the work is a port with a
known-good reference rather than a fresh design.

## 1. Why iOS cannot reuse the desktop architecture

Desktop resolves to `DesktopSidecarEngineService`
(`apps/flutter_app/lib/services/app_bootstrap.dart:76`), which runs long-lived
Python, Go, Rust, and Java subprocesses managed by
`apps/flutter_app/lib/services/desktop_engine_host.dart`.

iOS forbids spawning subprocesses and forbids shipping interpreters or JIT
runtimes. **None of the four engines under `engines/` can ship on iOS.**

Android already hit this wall and solved it, and that solution is the reference
for the entire port:

| Layer | Android reference | iOS equivalent to build |
| --- | --- | --- |
| Dart shim | `lib/services/android_engine_service.dart` (1634 lines) | `lib/services/ios_engine_service.dart` |
| Channel name | `s3_browser_crossplat/android_engine` (`android_engine_service.dart:15`) | `s3_browser_crossplat/ios_engine` |
| Native engine | `android/app/src/main/kotlin/.../MainActivity.kt` (2352 lines) | `ios/Runner/IosEngine.swift` |
| S3 client | `com.amazonaws:aws-android-sdk-s3:2.77.0` (`android/app/build.gradle.kts`) | see §2.1 |
| Bootstrap wiring | `app_bootstrap.dart:78` | new `Platform.isIOS` branch |

The engine contract itself is platform-neutral: 41 methods enumerated in
`contracts/engine_contract.json`, dispatched in Kotlin at `MainActivity.kt:121-173`.
The Swift port implements the same table.

## 2. Decisions required before coding

### 2.1 Swift S3 library

Blocks all of §5. Options:

| Option | Pros | Cons |
| --- | --- | --- |
| **AWS SDK for Swift** (recommended) | Official; custom endpoints for MinIO; SigV4, presigning, multipart all built in — closest analogue to what Kotlin gets from `aws-android-sdk-s3` | Large; SPM integration alongside CocoaPods |
| Soto | Lighter, mature S3 + presign | Community-maintained; SwiftNIO dependency |
| Hand-rolled SigV4 over `URLSession` | Zero dependencies, smallest binary, matches the repo's "no system toolchain" ethos (`scripts/bootstrap.sh`) | ~600 lines to write and test, including presign |

### 2.2 Apple Developer account

There is no iOS equivalent of the debug-signed sideloadable APK that
`scripts/build.sh:148` produces for Android. A paid account is required for
TestFlight, App Store, or ad-hoc distribution. The macOS Developer ID path
already exists (`.github/workflows/release-matrix.yml:88`, `scripts/sign-macos.sh`),
so this may only be provisioning-profile work — **confirm before Phase 6**, since
without it CI can build but produce nothing installable.

### 2.3 Bundle identifier

macOS uses `com.example.s3BrowserCrossplat`. `com.example.*` cannot be registered
on the App Store. Per `AGENTS.md`, the Keychain access group is
`TEAM_ID.com.example.s3BrowserCrossplat` — changing the identifier is a
**credential-migration event**, not a rename. Decide now.

### 2.4 Release scope

Recommend matching Android: Browser + Settings, Benchmark hidden.
`lib/app/s3_browser_app.dart:44-45` already hides the Benchmark tab on
`TargetPlatform.iOS`, so the shell has anticipated this.

Note that Android nonetheless implements benchmark natively
(`MainActivity.kt:1107-1188`, `executeBenchmark` at `MainActivity.kt:1494`).
Because the iOS tab is hidden, the six benchmark methods can return
`unsupported_feature` in v1 and be ported later.

## 3. Phase 1 — Scaffold

**1.1** Generate and commit `apps/flutter_app/ios/`:

```bash
cd apps/flutter_app && flutter create --platforms=ios .
```

The `macos/`, `windows/`, and `android/` scaffolds are checked in, and
`scripts/build.sh:58` (`require_macos_project`) depends on that convention.
iOS must follow it.

**1.2** Add `ios` to `.gitignore` review — confirm `ios/Pods/` and
`ios/Flutter/ephemeral/` are excluded the way `macos/` handles them.

## 4. Phase 2 — Shared Dart changes (regression risk for all 4 shipping platforms)

There are 24 platform branches in `lib/`. Most `Platform.isAndroid` sites mean
*"mobile"*, not *"Android"*. Adding `|| Platform.isIOS` at each call site will rot.

**2.1** Introduce `AppPlatform.isMobile` / `.isDesktop` helpers, then migrate:

| Site | Current | Why it must change |
| --- | --- | --- |
| `lib/browser/browser_workspace.dart:457` | `if (Platform.isAndroid \|\| Breakpoints.isPhone(...))` skips `DropTarget` | **Required.** `desktop_drop` 0.6.1 ships `android/linux/macos/windows` only — no iOS implementation |
| `lib/browser/browser_workspace.dart:787` | `final mobileTablet = !phone && Platform.isAndroid` | iPad layout |
| `lib/browser/browser_workspace.dart:1278` | `if (!phone && !Platform.isAndroid && !compactDesktop)` | iPad layout |
| `lib/browser/browser_workspace.dart:1294` | `Platform.isAndroid ? ...` | iPad layout |
| `lib/settings/settings_workspace.dart:25` | `final isAndroid = Platform.isAndroid` | drives version list + picker types |
| `lib/settings/version_details_catalog.dart:4,15` | `isAndroid` parameter hides `desktop_drop` from the version list | rename to `isMobile`; iOS must hide it too |

**2.2 — Download path.** `app_bootstrap.dart:95-121` falls through to
`Directory.current.path` (line 120) for unhandled platforms. On iOS that is the
read-only app bundle. Route iOS to `getApplicationDocumentsDirectory()`, and set
`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` in `Info.plist` so
downloads are reachable from Files.app.

Also update the destination label at `lib/controllers/app_controller.dart:1233`
(`Platform.isAndroid ? 'Downloads' : settings.downloadPath`).

**2.3 — file_picker gaps.** `file_picker` 8.3.7 does ship an `ios/` implementation, but:

- `FilePicker.platform.getDirectoryPath` (`browser_workspace.dart:117`, folder
  upload) is **not supported on iOS** — hide the control.
- `FilePicker.platform.saveFile` (`settings_workspace.dart:112`) already
  special-cases Android by writing to `downloadPath`; iOS needs the same branch
  plus a share sheet.

**2.4 — Engine descriptor model.** `lib/models/domain_models.dart:303,312` exposes
`androidSupported` on `EngineDescriptor`, consumed by
`version_details_catalog.dart:24`. Either add `iosSupported` or generalise to
`mobileSupported`; the latter avoids a third field later.

## 5. Phase 3 — The Swift engine adapter (~70% of total effort)

**3.1** `lib/services/ios_engine_service.dart` — structural copy of
`android_engine_service.dart`, including the `MockEngineService` fallback
(`android_engine_service.dart:20`) and the `EngineLogSinkRegistrant` /
`TransferJobSinkRegistrant` implementations.

**3.2** Add the `Platform.isIOS` branch at `app_bootstrap.dart:78`.

**3.3** `ios/Runner/IosEngine.swift` — port the dispatch table at
`MainActivity.kt:121-173`. Sequenced so the app is runnable early:

| Step | Methods | Kotlin reference |
| --- | --- | --- |
| **3.3a** Core browse | `health`, `getCapabilities`, `testProfile`, `listBuckets`, `listObjects`, `listObjectVersions`, `getObjectDetails` | `MainActivity.kt:191-558` |
| **3.3b** Mutations | `createBucket`, `deleteBucket`, `createFolder`, `copyObject`, `moveObject`, `deleteObjects`, `deleteObjectVersions` | `MainActivity.kt:316-355`, `679-789` |
| **3.3c** Bucket admin | versioning, lifecycle, policy, CORS, tagging | `MainActivity.kt:559-678` |
| **3.3d** Transfers | `startUpload`, `startDownload`, `pause/resume/cancelTransfer`, `generatePresignedUrl` | `MainActivity.kt:790-980` |
| **3.3e** Inspector tools | `runPutTestData`, `runDeleteAll`, `cancelToolExecution` | `MainActivity.kt:981-1088` |
| **3.3f** Benchmark (deferred) | 6 benchmark methods | `MainActivity.kt:1107-1188`, `1494-1855` |

Step 3.3a is the first runnable milestone against MinIO.

**3.4 — Parity choices to copy exactly from Android, not re-litigate:**

- Advertise engine IDs `go` and `rust` with labels `Go (iOS)` / `Rust (iOS)`
  — mirrors `MainActivity.kt:81-99`, so the Settings engine selector needs no change.
- `putBucketEncryption` / `deleteBucketEncryption` return `unsupported_feature`
  — matches `MainActivity.kt:643-656`.
- **Azure Blob is unsupported.** The Kotlin adapter contains no Azure code at all;
  `docs/FEATURE_MATRIX.md` lists Azure for Python and Go only. iOS must not diverge.
- Honour the `MultipartSizing` part size the Dart shell computes
  (`lib/services/multipart_sizing.dart`) rather than recomputing natively — see
  the multipart rules in `AGENTS.md`.

**3.5 — Error mapping.** Reproduce `EngineFailure` (`MainActivity.kt:2338`) and
`mapFailure` (`MainActivity.kt:2027-2057`) so identical `code`/`message` pairs reach
the shared Dart error UI.

## 6. Phase 4 — iOS platform integration

**4.1 — App Transport Security.** The sharpest iOS-specific risk for this app.
Users point it at `http://192.168.x.x:9000` for MinIO; ATS blocks cleartext by
default. Needs `NSAllowsLocalNetworking`, plus `NSLocalNetworkUsageDescription`
for the iOS 14+ local-network permission prompt, plus a written App Review
justification. Decide whether cleartext to *non-local* hosts is in scope — it
materially changes review risk.

**4.2 — Keychain.** iOS is data-protection-keychain only, so the macOS dual-mode
logic described in `AGENTS.md` collapses to a single path. The invariants still
bind: one `profiles.credentials.v2` item, never write secrets to state JSON, never
report a profile as saved when the secure write failed. Set `keychain-access-groups`
with the real team ID (§2.3). Reference: `lib/services/profile_secret_store.dart`.

**4.3 — Background transfers.** iOS suspends apps aggressively and will kill a
large multipart upload. Minimum bar: clean pause-on-suspend and resume-on-foreground
through the existing job API (`pauseTransfer`/`resumeTransfer`,
`MainActivity.kt:925-965`). `URLSession` background sessions are the real fix and
can follow.

**4.4 — Entitlements.** iOS has no sandbox entitlement file equivalent to
`macos/Runner/Release.entitlements`, but network client access is implicit and
presigned previews (`AGENTS.md`, "Object previews") need no extra key.

**4.5** Launch screen, app icons, orientation, and any photo-library usage strings.

## 7. Phase 5 — Build and packaging

**5.1** Add an `ios)` case to `scripts/build.sh` alongside `linux)` (line 75),
`macos)` (line 90), and `android)` (line 148): `flutter build ipa` plus an export
options plist. Note that **no engine staging is needed** — `scripts/stage-engines.sh`
is a no-op for iOS because no sidecars ship.

**5.2** New `packaging/ios/` for the export-options plist and signing config,
alongside the existing `packaging/{android,linux,macos,windows}/`.

**5.3** `scripts/bootstrap.sh` needs no new toolchain for iOS.

## 8. Phase 6 — CI

**6.1** Add an `ios:` job to `.github/workflows/release-matrix.yml` on `macos-14`,
modelled on the `android:` job (line 139) for structure and the `macos:` job
(line 70) for signing-secret handling.

**6.2** Gate artifact upload on §2.2 — without a signing identity the job can only
produce an unsigned build.

## 9. Phase 7 — Verification

Per `AGENTS.md` ("Verification"):

**7.1** `flutter analyze` and the full Flutter test suite.

**7.2** Add unit coverage for the new `AppPlatform` helper and iOS download-path
resolution. These are *shared-code* changes (§4) and are the main regression risk
to the four platforms that already ship.

**7.3** Manual matrix on simulator **and** a physical device — Keychain,
local-network permission, and ATS all behave differently on device — against both
MinIO and AWS S3.

## 10. Phase 8 — Documentation

| File | Change |
| --- | --- |
| `docs/FEATURE_MATRIX.md:30,64,75` | Add an iOS column beside the existing `Android` column in all three tables |
| `README.md` | Currently says "Windows, macOS, Linux, and Android"; add iOS and an iOS bootstrap section |
| `AGENTS.md` | Add iOS Keychain and ATS rules |
| `CHANGELOG.md` | Entry under `## Unreleased` |
| `docs/index.html` | Add the iOS download/target |

## 11. Effort weighting

- **Phase 3 (Swift adapter): ~70%** — porting ~2350 lines of Kotlin and
  re-verifying each of the 41 contract methods.
- **Phases 2 and 4: small but high-risk** — they touch shared Dart code and
  therefore carry the regression risk for Windows, macOS, Linux, and Android.
- **Phases 5–8: mechanical**, following existing per-platform patterns.

## 12. Open questions

1. Swift S3 library (§2.1).
2. Paid Apple Developer account available? (§2.2)
3. Final bundle identifier, given the Keychain-group migration cost (§2.3).
4. Is cleartext HTTP to non-local hosts in scope for App Review? (§4.1)
5. Ship benchmark on iOS in v1, or defer with the tab hidden? (§2.4)
