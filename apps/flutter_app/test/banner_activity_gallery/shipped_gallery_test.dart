import 'package:flutter_test/flutter_test.dart';

import 'gallery_harness.dart';

void main() {
  testWidgets('capture shipped banner activity gallery',
      (tester) => captureGallery(tester, shippedDesign),
      skip: !galleryEnabled);
}
