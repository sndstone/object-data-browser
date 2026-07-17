# macOS Packaging

`./scripts/build.sh macos` now produces:

- A release `.app` bundle from `flutter build macos`
- A distributable `.dmg` in `dist/macos/`

The DMG is assembled from the release bundle and staged desktop engines using `hdiutil`.
For local development without signing configuration, the build verifies an
ad-hoc signature and uses the legacy macOS Keychain. Ad-hoc identity changes
between builds, so these artifacts are not suitable for reliable updates.

Public releases must provide:

- `MACOS_SIGNING_IDENTITY`: the installed `Developer ID Application` identity
- `MACOS_TEAM_ID`: the Apple Developer team identifier
- `MACOS_PROVISIONING_PROFILE`: a Developer ID provisioning profile authorizing Keychain Sharing for `com.example.s3BrowserCrossplat`
- Either `MACOS_NOTARY_KEYCHAIN_PROFILE`, or `MACOS_NOTARY_KEY_FILE`, `MACOS_NOTARY_KEY_ID`, and `MACOS_NOTARY_ISSUER_ID`

The signed lane builds with
`OBJECT_BROWSER_MAC_KEYCHAIN_MODE=data-protection`, embeds the provisioning
profile, signs the app and DMG with hardened runtime, verifies the stable
team-scoped Keychain access group, submits the DMG to Apple notarization, and
staples the accepted ticket. GitHub Actions expects the corresponding base64
certificate, provisioning profile, and App Store Connect API-key secrets and
fails instead of publishing an ad-hoc macOS release when they are absent.
