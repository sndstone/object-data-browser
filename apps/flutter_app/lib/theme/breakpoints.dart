/// Unified responsive breakpoints for the whole app.
///
/// The same window-width rules apply on every platform, so resizing a
/// desktop window down moves through the exact same layouts a tablet or
/// phone would get:
///
/// * `width < phone` — phone layout: bottom navigation, single-column
///   browser with Buckets / Objects / Inspect section tabs.
/// * `phone <= width < desktop` — tablet layout: top workspace tabs,
///   bucket panel + object list with the inspector docked below.
/// * `width >= desktop` — desktop layout: navigation rail, header search,
///   resizable inspector (right or bottom), full detail columns.
abstract final class Breakpoints {
  /// Below this the app behaves like a phone.
  static const double phone = 700;

  /// Touch-first devices (Android tablets) keep the phone-style browser
  /// shell a little longer because panel-splitting is cramped with touch
  /// targets below this width.
  static const double touchPhone = 900;

  /// At and above this the app uses the full desktop layout (rail,
  /// header search, side-by-side inspector).
  static const double desktop = 1200;

  /// Extra-wide desktop: the object table adds detail columns
  /// (storage class, ETag) and panels get roomier padding.
  static const double desktopWide = 1500;

  static bool isPhone(double width) => width < phone;
  static bool isTablet(double width) => width >= phone && width < desktop;
  static bool isDesktop(double width) => width >= desktop;
}
