import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/app_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('iOS download path resolves to the app Documents directory', () async {
    final path = await AppBootstrap.resolveDownloadPath(
      isAndroid: false,
      isIOS: true,
      documentsDirectoryProvider: () async => Directory('/ios/Documents'),
    );

    expect(path, '/ios/Documents');
  });

  test('Android native Downloads path remains preferred', () async {
    final path = await AppBootstrap.resolveDownloadPath(
      isAndroid: true,
      isIOS: false,
      androidDownloadsPath: () async => '/storage/emulated/0/Download',
    );

    expect(path, '/storage/emulated/0/Download');
  });
}
