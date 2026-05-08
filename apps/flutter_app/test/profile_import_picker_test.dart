import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/settings/profile_import_picker.dart';

void main() {
  test('android import picker uses any file type without extension filters',
      () {
    expect(
      profileImportPickerType(isAndroid: true),
      FileType.any,
    );
    expect(
      profileImportAllowedExtensions(isAndroid: true),
      isNull,
    );
  });

  test('desktop import picker keeps json extension filter', () {
    expect(
      profileImportPickerType(isAndroid: false),
      FileType.custom,
    );
    expect(
      profileImportAllowedExtensions(isAndroid: false),
      const ['json'],
    );
  });

  test('json profile import selection accepts file name or path', () {
    expect(
      isJsonProfileImportSelection(
        PlatformFile(name: 'profiles.JSON', size: 0),
      ),
      isTrue,
    );
    expect(
      isJsonProfileImportSelection(
        PlatformFile(
          name: 'profiles',
          path: '/tmp/s3-browser-profiles.json',
          size: 0,
        ),
      ),
      isTrue,
    );
    expect(
      isJsonProfileImportSelection(
        PlatformFile(name: 'profiles.txt', size: 0),
      ),
      isFalse,
    );
  });
}
