/// Formatting measured metrics never turns a missing sample into zero.
String formatMeasuredMetric(Object? value, {int decimals = 1}) =>
    value is num ? value.toStringAsFixed(decimals) : 'Unavailable';

String formatMeasuredCount(Object? value) =>
    value is num ? value.toInt().toString() : 'Unavailable';

String sizeLatencyField(String metric) => switch (metric) {
      'p50' => 'p50LatencyMs',
      'p95' => 'p95LatencyMs',
      'p99' => 'p99LatencyMs',
      _ => 'avgLatencyMs',
    };
