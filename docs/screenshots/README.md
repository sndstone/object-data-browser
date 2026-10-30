# README screenshots

These PNGs render `S3BrowserApp` with fixed dates, fictional objects, and an in-memory engine. No storage requests are made and no real credentials are used. They show the Windows desktop layout at 1600 × 1000, using the bundled Inter/Sora fonts and system monospace text.

The gallery covers browsing, source preview, connections, benchmark configuration and results, Jobs/transfer status, and the Event Log. Benchmark metrics and transfer progress are illustrative fixtures, not measured performance or live operations.

From the repository root, after bootstrapping the pinned Flutter SDK:

```powershell
$env:README_SCREENSHOTS = '1'
Push-Location apps/flutter_app
& ../../.tmp/toolchains/flutter/bin/flutter.bat test test/readme_screenshots_test.dart
Pop-Location
Remove-Item Env:README_SCREENSHOTS
```

Linux / macOS:

```sh
cd apps/flutter_app
README_SCREENSHOTS=1 ../../.tmp/toolchains/flutter/bin/flutter test test/readme_screenshots_test.dart
```

The capture uses Consolas on Windows, Menlo on macOS, or DejaVu Sans Mono on Linux. Set `README_MONOSPACE_FONT` to a local TTF/TTC file if that font is unavailable. System font differences can change text spacing. Fonts are loaded for rendering and are not copied into the repository.

The capture is skipped during ordinary test runs. To update it, edit `apps/flutter_app/test/readme_screenshots_test.dart`, regenerate all seven PNGs, and inspect the images before committing.
