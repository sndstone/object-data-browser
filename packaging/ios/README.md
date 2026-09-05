# iOS packaging

Run `./scripts/build.sh ios arm64` to build an unsigned device app suitable for
CI compile verification. A distributable IPA requires an Apple Distribution
identity and provisioning profile.

For a signed export, install the certificate and provisioning profile, then set
`IOS_SIGNING_IDENTITY` and `IOS_TEAM_ID`. Set `IOS_EXPORT_OPTIONS_PLIST` to use a
custom export configuration; otherwise the build script expands
`ExportOptions.plist.template` for an App Store Connect export.

## Simulator testing

Open `apps/flutter_app/ios/Runner.xcworkspace`, select an iOS Simulator, and run
the `Runner` scheme from Xcode when testing profile persistence. Xcode supplies
the simulator-only application identifier and Keychain access group used by the
Data Protection Keychain. On first use, approve Xcode's request to enable the
`SmithyCodeGeneratorPlugin` package plug-in. If the product was built from the
command line with package plug-in validation skipped, use **Product > Perform
Action > Run Without Building** to launch that product through Xcode.

Do not install and launch an unsigned `.app` directly with `simctl` when testing
credentials. On current iOS simulator runtimes that artifact has no usable
Keychain entitlement, so Keychain operations fail with `-34018` and the app
correctly keeps credentials in memory for that session only.
