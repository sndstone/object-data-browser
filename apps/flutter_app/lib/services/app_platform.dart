import 'dart:io';

/// Centralized platform classification for UI and service decisions.
abstract final class AppPlatform {
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static bool mobileFor({required bool android, required bool ios}) =>
      android || ios;

  static bool desktopFor({
    required bool windows,
    required bool linux,
    required bool macOS,
  }) =>
      windows || linux || macOS;
}
