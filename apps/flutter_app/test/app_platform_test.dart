import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/app_platform.dart';

void main() {
  test('mobile classification includes Android and iOS', () {
    expect(AppPlatform.mobileFor(android: true, ios: false), isTrue);
    expect(AppPlatform.mobileFor(android: false, ios: true), isTrue);
    expect(AppPlatform.mobileFor(android: false, ios: false), isFalse);
  });

  test('desktop classification includes all supported desktop targets', () {
    expect(
      AppPlatform.desktopFor(windows: true, linux: false, macOS: false),
      isTrue,
    );
    expect(
      AppPlatform.desktopFor(windows: false, linux: true, macOS: false),
      isTrue,
    );
    expect(
      AppPlatform.desktopFor(windows: false, linux: false, macOS: true),
      isTrue,
    );
    expect(
      AppPlatform.desktopFor(windows: false, linux: false, macOS: false),
      isFalse,
    );
  });
}
