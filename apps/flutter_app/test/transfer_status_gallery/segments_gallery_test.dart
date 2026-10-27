import 'package:flutter_test/flutter_test.dart';

import 'gallery_harness.dart';

void main() {
  testWidgets('capture segments transfer status gallery',
      (tester) => captureGallery(tester, const [segmentsVariant]),
      skip: !galleryEnabled);
}
