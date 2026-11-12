import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

class PreviewImageData {
  const PreviewImageData(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width, height;
}

/// Owns network work for one preview surface, including HTML resources.
class PreviewImageLoader {
  PreviewImageLoader(
      {this.maximumBytes = 20 * 1024 * 1024,
      this.aggregateBytes = 40 * 1024 * 1024,
      this.maximumResources = 32});
  final int maximumBytes, aggregateBytes, maximumResources;
  static final LinkedHashMap<String, PreviewImageData> _cache = LinkedHashMap();
  static int _cachedBytes = 0;
  final Set<HttpClient> _clients = {};
  final Queue<Completer<void>> _queue = Queue();
  int _active = 0, _bytes = 0, _resources = 0;
  bool _closed = false;

  Future<PreviewImageData> load(String location,
      {String? etag, bool cache = true}) async {
    if (_closed) throw StateError('Preview closed');
    final key = '$location\u0000${etag ?? ''}';
    if (++_resources > maximumResources) {
      throw const FormatException('Preview resource limit reached');
    }
    final cached = cache ? _cache.remove(key) : null;
    if (cached != null) {
      _cache[key] = cached;
      _bytes += cached.bytes.length;
      if (_bytes > aggregateBytes) {
        throw const FormatException('Preview resource budget exceeded');
      }
      return cached;
    }
    if (_active >= 3) {
      final waiter = Completer<void>();
      _queue.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    if (_closed) throw StateError('Preview closed');
    HttpClient? client;
    try {
      final uri = Uri.parse(location);
      Uint8List bytes;
      if (uri.scheme == 'data') {
        bytes = uri.data!.contentAsBytes();
        if (bytes.length > maximumBytes) {
          throw const FormatException('Image exceeds preview limit');
        }
        _bytes += bytes.length;
      } else {
        if (!['http', 'https'].contains(uri.scheme)) {
          throw const FormatException('Unsupported image location');
        }
        client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
        _clients.add(client);
        final request = await client.getUrl(uri);
        request.maxRedirects = 3;
        if (etag != null && etag.isNotEmpty) {
          request.headers.set(HttpHeaders.ifMatchHeader, etag);
        }
        final response =
            await request.close().timeout(const Duration(seconds: 15));
        if (response.statusCode != HttpStatus.ok) {
          throw const HttpException('Image preview request failed');
        }
        if (response.contentLength > maximumBytes) {
          throw const FormatException('Image exceeds preview limit');
        }
        final output = BytesBuilder(copy: false);
        await for (final chunk
            in response.timeout(const Duration(seconds: 15))) {
          _bytes += chunk.length;
          if (_closed ||
              output.length + chunk.length > maximumBytes ||
              _bytes > aggregateBytes) {
            throw const FormatException('Preview resource budget exceeded');
          }
          output.add(chunk);
        }
        bytes = output.takeBytes();
      }
      if (_bytes > aggregateBytes) {
        throw const FormatException('Preview resource budget exceeded');
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      late final PreviewImageData data;
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          data = PreviewImageData(bytes, descriptor.width, descriptor.height);
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
      if (cache && bytes.length <= 24 * 1024 * 1024) {
        while (_cache.isNotEmpty &&
            _cachedBytes + bytes.length > 24 * 1024 * 1024) {
          _cachedBytes -= _cache.remove(_cache.keys.first)!.bytes.length;
        }
        final previous = _cache.remove(key);
        if (previous != null) _cachedBytes -= previous.bytes.length;
        _cache[key] = data;
        _cachedBytes += bytes.length;
      }
      return data;
    } finally {
      if (client != null) {
        _clients.remove(client);
        client.close(force: true);
      }
      if (_queue.isNotEmpty) {
        _queue.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
    while (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    }
  }
}
