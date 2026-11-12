/// Presentation and resource policy. Correctness protections are unconditional.
class PerformanceSettings {
  const PerformanceSettings(
      {this.progressIntervalMs = 100,
      this.engineIdleSeconds = 120,
      this.listingWindowObjects = 100000,
      this.copyTimeoutSeconds = 300,
      this.imagePreviewMegapixels = 32});
  final int progressIntervalMs;
  final int engineIdleSeconds;
  final int listingWindowObjects;
  final int copyTimeoutSeconds;
  final int imagePreviewMegapixels;

  factory PerformanceSettings.fromJson(Map<String, Object?> json) =>
      PerformanceSettings(
          progressIntervalMs:
              ((json['progressIntervalMs'] as num?)?.toInt() ?? 100)
                  .clamp(50, 2000),
          engineIdleSeconds:
              ((json['engineIdleSeconds'] as num?)?.toInt() ?? 120)
                  .clamp(0, 3600),
          listingWindowObjects:
              ((json['listingWindowObjects'] as num?)?.toInt() ?? 100000)
                  .clamp(1000, 100000),
          imagePreviewMegapixels:
              ((json['imagePreviewMegapixels'] as num?)?.toInt() ?? 32)
                  .clamp(4, 64),
          copyTimeoutSeconds:
              ((json['copyTimeoutSeconds'] as num?)?.toInt() ?? 300)
                  .clamp(5, 3600));

  Map<String, Object?> toJson() => {
        'progressIntervalMs': progressIntervalMs,
        'engineIdleSeconds': engineIdleSeconds,
        'listingWindowObjects': listingWindowObjects,
        'imagePreviewMegapixels': imagePreviewMegapixels,
        'copyTimeoutSeconds': copyTimeoutSeconds
      };

  PerformanceSettings copyWith(
          {int? progressIntervalMs,
          int? engineIdleSeconds,
          int? listingWindowObjects,
          int? copyTimeoutSeconds,
          int? imagePreviewMegapixels}) =>
      PerformanceSettings.fromJson({
        'progressIntervalMs': progressIntervalMs ?? this.progressIntervalMs,
        'engineIdleSeconds': engineIdleSeconds ?? this.engineIdleSeconds,
        'listingWindowObjects':
            listingWindowObjects ?? this.listingWindowObjects,
        'imagePreviewMegapixels':
            imagePreviewMegapixels ?? this.imagePreviewMegapixels,
        'copyTimeoutSeconds': copyTimeoutSeconds ?? this.copyTimeoutSeconds
      });
}
