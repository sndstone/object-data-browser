import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/multipart_sizing.dart';

void main() {
  const mib = MultipartSizing.bytesPerMiB;
  const gib = 1024 * mib;
  const tib = 1024 * gib;

  test('dynamic multipart sizing grows with large files', () {
    expect(MultipartSizing.recommendedPartSizeMiB(0), 8);
    expect(MultipartSizing.recommendedPartSizeMiB(1 * gib), 8);
    expect(MultipartSizing.recommendedPartSizeMiB(10 * gib), 128);
    expect(MultipartSizing.recommendedPartSizeMiB(100 * gib), 128);
    expect(MultipartSizing.recommendedPartSizeMiB(2 * tib), 256);
  });

  test('dynamic multipart sizing never exceeds S3 part limits', () {
    const size = MultipartSizing.maximumObjectBytes;
    final partSize = MultipartSizing.recommendedPartSizeMiB(size);

    expect(partSize, MultipartSizing.maximumPartMiB);
    expect(
      MultipartSizing.partCount(
        fileSizeBytes: size,
        partSizeMiB: partSize,
      ),
      MultipartSizing.maximumParts,
    );
    expect(
      () => MultipartSizing.recommendedPartSizeMiB(size + 1),
      throwsArgumentError,
    );
  });

  test('manual multipart overrides are clamped to S3 limits', () {
    expect(MultipartSizing.compliantManualPartSizeMiB(1), 5);
    expect(MultipartSizing.compliantManualPartSizeMiB(64), 64);
    expect(MultipartSizing.compliantManualPartSizeMiB(9000), 5120);
  });
}
