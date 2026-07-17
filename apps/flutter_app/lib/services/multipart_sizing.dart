import 'dart:math' as math;

/// Chooses upload part sizes that preserve parallel throughput while staying
/// inside the Amazon S3 multipart API limits.
abstract final class MultipartSizing {
  static const int bytesPerMiB = 1024 * 1024;
  static const int minimumPartMiB = 5;
  static const int preferredMinimumPartMiB = 8;
  static const int maximumPartMiB = 5 * 1024;
  static const int maximumParts = 10000;
  static const int targetParts = 128;
  static const int maximumThroughputPartMiB = 128;
  static const int maximumObjectBytes =
      maximumPartMiB * bytesPerMiB * maximumParts;

  static int recommendedPartSizeMiB(int fileSizeBytes) {
    if (fileSizeBytes < 0) {
      throw ArgumentError.value(fileSizeBytes, 'fileSizeBytes');
    }
    if (fileSizeBytes > maximumObjectBytes) {
      throw ArgumentError.value(
        fileSizeBytes,
        'fileSizeBytes',
        'Object exceeds the S3 multipart maximum.',
      );
    }

    final throughputSize = _ceilDiv(
      fileSizeBytes,
      targetParts * bytesPerMiB,
    ).clamp(preferredMinimumPartMiB, maximumThroughputPartMiB);
    final complianceSize = _ceilDiv(
      fileSizeBytes,
      maximumParts * bytesPerMiB,
    );
    final requiredMiB = math.max(
      preferredMinimumPartMiB,
      math.max(throughputSize, complianceSize),
    );
    return _roundEfficientMiB(requiredMiB).clamp(
      minimumPartMiB,
      maximumPartMiB,
    );
  }

  static int compliantManualPartSizeMiB(int configuredMiB) {
    return configuredMiB.clamp(minimumPartMiB, maximumPartMiB);
  }

  static int partCount({
    required int fileSizeBytes,
    required int partSizeMiB,
  }) {
    if (fileSizeBytes == 0) return 0;
    return _ceilDiv(fileSizeBytes, partSizeMiB * bytesPerMiB);
  }

  static int _roundEfficientMiB(int value) {
    if (value <= 4096) {
      var rounded = 1;
      while (rounded < value) {
        rounded *= 2;
      }
      return rounded;
    }
    // The only valid range above 4 GiB is narrow. Align it to 64 MiB so
    // offsets remain simple without ever crossing S3's 5 GiB ceiling.
    return _ceilDiv(value, 64) * 64;
  }

  static int _ceilDiv(int value, int divisor) {
    if (value == 0) return 0;
    return 1 + ((value - 1) ~/ divisor);
  }
}
