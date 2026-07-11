/// Unified responsive breakpoints for the whole app.
///
/// The same window-width rules apply on every platform, so resizing a
/// desktop window down moves through the exact same layouts a tablet or
/// phone would get:
///
/// * `width < phone` — phone layout: bottom navigation, single-column
///   browser with Buckets / Objects / Inspect section tabs.
/// * `phone <= width < smallDesktop` — tablet layout: top workspace tabs,
///   bucket panel + object list with the inspector available on demand.
/// * `smallDesktop <= width < desktop` — compact desktop layout: a narrow
///   navigation rail and a bottom-docked inspector.
/// * `width >= desktop` — desktop layout: full navigation rail, header search,
///   resizable inspector (right or bottom), full detail columns.
abstract final class Breakpoints {
  /// Below this the app behaves like a phone.
  static const double phone = 700;

  /// At and above this the app uses its compact desktop shell.
  static const double smallDesktop = 1000;

  /// At and above this the app uses the full desktop layout (wide rail,
  /// header search, side-by-side inspector).
  static const double desktop = 1360;

  /// Extra-wide desktop: the object table adds detail columns
  /// (storage class, ETag) and panels get roomier padding.
  static const double desktopWide = 1500;

  static bool isPhone(double width) => width < phone;
  static bool isTablet(double width) => width >= phone && width < smallDesktop;
  static bool isSmallDesktop(double width) =>
      width >= smallDesktop && width < desktop;
  static bool isDesktop(double width) => width >= desktop;

  static WindowSizeClass sizeClass(double width) {
    if (isPhone(width)) return WindowSizeClass.phone;
    if (isTablet(width)) return WindowSizeClass.tablet;
    if (isSmallDesktop(width)) return WindowSizeClass.smallDesktop;
    return WindowSizeClass.desktop;
  }
}

enum WindowSizeClass { phone, tablet, smallDesktop, desktop }
