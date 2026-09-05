String formatBytes(int value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var n = value.toDouble();
  var unit = 0;
  while (n.abs() >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit++;
  }
  return '${unit == 0 ? value.toString() : n.toStringAsFixed(1)} ${units[unit]}';
}

String formatDateTime(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

String formatRelative(DateTime value, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(value);
  final seconds = delta.inSeconds.abs();
  final text = seconds < 60
      ? '$seconds seconds'
      : seconds < 3600
          ? '${seconds ~/ 60} minutes'
          : seconds < 86400
              ? '${seconds ~/ 3600} hours'
              : '${seconds ~/ 86400} days';
  return delta.isNegative ? 'in $text' : '$text ago';
}
