import 'package:flutter_test/flutter_test.dart';

import 'gallery_harness.dart';

void main() {
  testWidgets('capture file_scan transfer status gallery',
      (tester) => captureGallery(tester, const [fileScanVariant]),
      skip: !galleryEnabled);
}
