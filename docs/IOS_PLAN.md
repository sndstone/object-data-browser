# iPhone and iPad support

The universal iOS target is implemented for iPhone and iPad. Minimum deployment
target: iOS 15. It uses `IosEngineService` with the AWS SDK for Swift and the shared
Dart REST adapter; desktop sidecar engines are not shipped on iOS.

## Implemented

- Adaptive Browser, Jobs, Event Log and Settings workspaces, with Files import
  and downloads in the app's Documents directory.
- Shared S3 and Azure REST administration, encryption configuration, bounded
  multipart transfers, exact-version recovery and shared benchmark services.
  The Benchmark workspace remains hidden on mobile pending release qualification.
- Consolidated Data Protection Keychain storage through `ProfileSecretStore`.
  Credential exports remain metadata-only, and secure-write failures retain the
  session-only warning and explicit recovery boundary.
- Local-network permission text and `NSAllowsLocalNetworking`, without a global
  cleartext networking exception.
- Keyboard-aware forms, full-height phone JSON editing, retained drafts and
  save errors, stacked tag fields, and Command shortcuts on iPad keyboards.
- Foreground transfer progress and cancellation. Backgrounding stops active
  transfer actions and queued files; a short native background task allows
  cleanup. Downloads publish only verified completed files. Interrupted uploads
  attempt multipart abort; uncertain completion remains a reconciliation case.
- App icon and launch image based on the existing application artwork, file
  timestamp privacy reasons for app-container and user-selected files, and an
  export-compliance declaration for the app's standard networking/authentication.

## Build verification

Use `flutter build ios --simulator --debug` from `apps/flutter_app`. With the
Xcode 27.2 / Flutter 3.44.6 combination on the development Mac, Flutter's wrapper
currently exits with an uncategorized Xcode error. A direct workspace build
succeeds with an arm64-only xcconfig and explicit approval of the pinned Swift
package plugins (`-skipPackagePluginValidation -skipMacroValidation`). Do not use
`-sdk iphonesimulator`: SwiftPM code-generation tools must build for the host.
This workaround is host-specific and does not change distribution signing.

Use `scripts/build.sh ios arm64` for device compile verification or a signed
export. See [iOS packaging](../packaging/ios/README.md) for signing configuration
and simulator Keychain limitations.

## Required before a public release

1. Configure the Apple team, distribution certificate, provisioning profile and
   permanent registered bundle identifier. An identifier change needs an
   explicit Keychain migration plan; do not silently replace the current group.
2. Verify Keychain Save/relaunch/recovery, local-network permission, and local
   HTTP/remote HTTPS endpoints on a physical iPhone and iPad.
3. Exercise cancellation and app backgrounding during single-part, multipart,
   and completion requests against AWS and representative compatible endpoints.
   A killed process may prevent abort cleanup; inspect outstanding multipart
   uploads and uncertain destinations before retrying.
4. Confirm App Store privacy/export declarations for the final shipped SDK set,
   and verify icons, orientation, accessibility, split view and hardware keyboards.
5. Decide whether to expose Benchmark on iOS after device qualification.

Background `URLSession` transfers with durable resume are a separate feature.
The foreground implementation stops on backgrounding and does not claim to
continue transferring while the device is locked.
