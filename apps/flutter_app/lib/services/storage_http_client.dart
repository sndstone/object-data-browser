import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../controllers/action_scope.dart';
import '../models/domain_models.dart';
import 'listing_cancellation.dart';

/// A bounded, signed REST transport shared by mobile storage administration.
/// Credentials live only in the profile/client instance and are never logged.
class StorageHttpClient {
  StorageHttpClient(this.profile,
      {HttpClient? client, DateTime Function()? now})
      : _client = client ?? _createClient(profile),
        _now = now ?? DateTime.now;

  final EndpointProfile profile;
  final HttpClient _client;
  final DateTime Function() _now;
  DateTime? _lastRequest;
  Future<void> _admission = Future.value();
  int requestCount = 0, retryCount = 0;
  bool get azure => profile.endpointType == EndpointProfileType.azureBlob;

  static HttpClient _createClient(EndpointProfile profile) {
    SecurityContext? context;
    if (profile.connection.caBundlePath.isNotEmpty) {
      context = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(profile.connection.caBundlePath);
    }
    return HttpClient(context: context)
      ..connectionTimeout = Duration(seconds: profile.connectTimeoutSeconds)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = profile.maxConcurrentRequests.clamp(1, 64)
      ..autoUncompress = false
      ..badCertificateCallback = (_, __, ___) => !profile.verifyTls;
  }

  void close() => _client.close(force: true);

  Uri uri(String bucket, [String? key, Map<String, String> query = const {}]) {
    final endpoint = profile.endpointUrl.isEmpty && azure
        ? 'https://${profile.accessKey}.blob.core.windows.net'
        : profile.endpointUrl;
    final base = Uri.parse(endpoint);
    if (!{'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw const EngineException(
          code: ErrorCode.invalidConfig,
          message:
              'Use an HTTP(S) endpoint without credentials or query parameters.');
    }
    var origin = base.origin;
    final pieces = <String>[];
    if (base.path.isNotEmpty && base.path != '/') {
      pieces.add(base.path.replaceAll(RegExp(r'^/|/$'), ''));
    }
    if (bucket.isNotEmpty) {
      if (!azure && !profile.pathStyle) {
        origin = base.replace(host: '$bucket.${base.host}', path: '').origin;
      } else {
        pieces.add(storageUriEncode(bucket));
      }
    }
    if (key != null) pieces.add(key.split('/').map(storageUriEncode).join('/'));
    final parameters = <String, String>{...query};
    if (azure && profile.connection.authMode == 'azureSas') {
      final raw = (profile.sessionToken ?? '').replaceFirst(RegExp(r'^\?'), '');
      final token = Uri.splitQueryString(raw);
      if (token['sig'] == null) {
        throw const EngineException(
            code: ErrorCode.invalidConfig,
            message: 'The Azure SAS credential does not contain a signature.');
      }
      if (parameters.keys.any(token.containsKey)) {
        throw const EngineException(
            code: ErrorCode.invalidConfig,
            message: 'The SAS query conflicts with this storage operation.');
      }
      parameters.addAll(token);
    }
    return ExactStorageUri(
        Uri.parse(origin), '/${pieces.join('/')}', storageQuery(parameters));
  }

  Future<StorageHttpResponse> request(String method, String bucket,
      {String? key,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      List<int> body = const [],
      int maxResponseBytes = 16 * 1024 * 1024,
      bool? retrySafe}) async {
    return requestStream(method, bucket,
        key: key,
        query: query,
        headers: headers,
        body: () => Stream.value(body),
        bodyLength: body.length,
        payloadSha256: sha256.convert(body).toString(),
        maxResponseBytes: maxResponseBytes,
        retrySafe: retrySafe);
  }

  /// Each retry recreates the upload stream and calls [onResponseStart] before
  /// yielding success bytes. A consumer must reset its checksum/file offset there.
  /// Error documents remain bounded and never reach the successful-body consumer.
  Future<StorageHttpResponse> requestStream(String method, String bucket,
      {String? key,
      Map<String, String> query = const {},
      Map<String, String> headers = const {},
      Stream<List<int>> Function()? body,
      int bodyLength = 0,
      String? payloadSha256,
      FutureOr<void> Function()? onResponseStart,
      FutureOr<void> Function(List<int>)? onResponseChunk,
      int? maxResponseBytes,
      bool? retrySafe}) async {
    if (bodyLength < 0 || (bodyLength > 0 && body == null)) {
      throw const EngineException(
          code: ErrorCode.invalidConfig,
          message:
              'A repeatable upload stream and its exact length are required.');
    }
    final target = uri(bucket, key, query);
    final safe = retrySafe ?? {'GET', 'HEAD', 'OPTIONS'}.contains(method);
    final attempts = safe ? profile.maxAttempts.clamp(1, 10) : 1;
    for (var attempt = 0;; attempt++) {
      ActionScope.current?.check();
      await _admit();
      final hash = payloadSha256 ??
          (bodyLength == 0 ? sha256.convert(const <int>[]).toString() : null);
      if (!azure &&
          (hash == null || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash))) {
        throw const EngineException(
            code: ErrorCode.invalidConfig,
            message:
                'A precomputed SHA256 digest is required for a streamed S3 upload.');
      }
      final signed = signedHeaders(
          method, target, headers, const [], _now().toUtc(),
          bodyLength: bodyLength, payloadSha256: hash);
      HttpClientRequest? outgoing;
      var complete = false, sent = false;
      final scope = ActionScope.current;
      try {
        outgoing = await _client.openUrl(method, target);
        outgoing.followRedirects = false;
        outgoing.contentLength = bodyLength;
        for (final entry in signed.entries) {
          outgoing.headers.set(entry.key, entry.value);
        }
        final cancellable = outgoing;
        if (scope != null) {
          unawaited(scope.whenCancelled.then((_) {
            if (!complete) {
              if (sent && !safe) scope.outcomeUnknown = true;
              cancellable.abort(const ListingCancelled());
            }
          }));
        }
        scope?.check();
        requestCount++;
        sent = true;
        var written = 0;
        if (body != null) {
          await outgoing
              .addStream(body().map((chunk) {
                scope?.check();
                written += chunk.length;
                if (written > bodyLength) {
                  throw const EngineException(
                      code: ErrorCode.invalidConfig,
                      message: 'Upload stream exceeded its declared length.');
                }
                return chunk;
              }))
              .timeout(Duration(seconds: profile.readTimeoutSeconds));
        }
        if (written != bodyLength) {
          throw const EngineException(
              code: ErrorCode.invalidConfig,
              message: 'Upload stream did not match its declared length.');
        }
        final response = await outgoing
            .close()
            .timeout(Duration(seconds: profile.readTimeoutSeconds));
        final resultHeaders = <String, String>{};
        response.headers.forEach((name, values) =>
            resultHeaders[name.toLowerCase()] = values.join(','));
        final bytes = BytesBuilder(copy: false);
        final successful =
            response.statusCode >= 200 && response.statusCode < 300;
        final streamed = successful && onResponseChunk != null;
        if (successful) await onResponseStart?.call();
        var received = 0;
        final limit = successful
            ? maxResponseBytes ?? (streamed ? null : 16 * 1024 * 1024)
            : 1024 * 1024;
        await for (final chunk in response
            .timeout(Duration(seconds: profile.readTimeoutSeconds))) {
          scope?.check();
          received += chunk.length;
          if (limit != null && received > limit) {
            outgoing.abort();
            throw const EngineException(
                code: ErrorCode.invalidConfig,
                message:
                    'The storage response exceeded its bounded size limit.');
          }
          if (streamed) {
            await onResponseChunk(chunk);
          } else {
            bytes.add(chunk);
          }
        }
        complete = true;
        final result = StorageHttpResponse(
            response.statusCode, resultHeaders, bytes.takeBytes());
        if (result.status >= 200 && result.status < 300) return result;
        if (safe &&
            attempt + 1 < attempts &&
            {408, 429, 500, 502, 503, 504}.contains(result.status)) {
          retryCount++;
          await Future<void>.delayed(
              Duration(milliseconds: min(2000, 100 * (1 << attempt))));
          continue;
        }
        throw StorageHttpException(result);
      } on ListingCancelled {
        outgoing?.abort();
        rethrow;
      } on EngineException catch (error) {
        outgoing?.abort();
        if (sent && !safe && error is! StorageHttpException) {
          scope?.outcomeUnknown = true;
        }
        rethrow;
      } catch (error) {
        outgoing?.abort();
        if (scope?.isCancelled ?? false) throw const ListingCancelled();
        if (safe &&
            attempt + 1 < attempts &&
            (error is SocketException ||
                error is TimeoutException ||
                error is HttpException)) {
          retryCount++;
          outgoing?.abort();
          await Future<void>.delayed(
              Duration(milliseconds: min(2000, 100 * (1 << attempt))));
          continue;
        }
        if (sent && !safe) scope?.outcomeUnknown = true;
        // Exception messages may contain signed URLs. Never expose them.
        throw EngineException(
            code: error is HandshakeException
                ? ErrorCode.tlsError
                : error is TimeoutException
                    ? ErrorCode.timeout
                    : ErrorCode.unknown,
            message: sent && !safe
                ? 'The request outcome is unknown. Inspect the destination before retrying.'
                : 'Could not complete the storage request (${error.runtimeType}).');
      } finally {
        complete = true;
      }
    }
  }

  Future<void> _admit() {
    final previous = _admission;
    final scope = ActionScope.current;
    final next = () async {
      await previous;
      scope?.check();
      if (profile.maxRequestsPerSecond > 0 && _lastRequest != null) {
        final deadline = _lastRequest!.add(
            Duration(microseconds: 1000000 ~/ profile.maxRequestsPerSecond));
        final remaining = deadline.difference(DateTime.now());
        if (remaining > Duration.zero) {
          await Future.any<void>([
            Future<void>.delayed(remaining),
            if (scope != null) scope.whenCancelled,
          ]);
        }
      }
      scope?.check();
      _lastRequest = DateTime.now();
    }();
    _admission = next.catchError((Object _) {});
    return next;
  }

  Map<String, String> signedHeaders(String method, Uri target,
      Map<String, String> supplied, List<int> body, DateTime time,
      {int? bodyLength, String? payloadSha256}) {
    final length = bodyLength ?? body.length;
    final headers =
        supplied.map((key, value) => MapEntry(key.toLowerCase(), value));
    headers['host'] = target.authority;
    if (azure) {
      headers['x-ms-date'] = HttpDate.format(time);
      headers['x-ms-version'] = '2021-12-02';
      if (profile.connection.authMode == 'azureSas') return headers;
      if (profile.connection.authMode != 'static') {
        throw const EngineException(
            code: ErrorCode.unsupportedFeature,
            message:
                'Mobile Azure requests require an account key or SAS credential.');
      }
      final canonicalHeaders =
          (headers.keys.where((key) => key.startsWith('x-ms-')).toList()
                ..sort())
              .map((key) => '$key:${headers[key]!.trim()}\n')
              .join();
      final query = target.queryParametersAll;
      final queryNames = query.keys.toList()..sort();
      final resource =
          '/${profile.accessKey}${target.path}${queryNames.map((name) => '\n${name.toLowerCase()}:${(List.of(query[name]!)..sort()).join(',')}').join()}';
      final text = [
        method,
        headers['content-encoding'] ?? '',
        headers['content-language'] ?? '',
        length == 0 ? '' : '$length',
        headers['content-md5'] ?? '',
        headers['content-type'] ?? '',
        '',
        headers['if-modified-since'] ?? '',
        headers['if-match'] ?? '',
        headers['if-none-match'] ?? '',
        headers['if-unmodified-since'] ?? '',
        headers['range'] ?? '',
        '$canonicalHeaders$resource'
      ].join('\n');
      try {
        headers['authorization'] =
            'SharedKey ${profile.accessKey}:${base64Encode(Hmac(sha256, base64Decode(profile.secretKey)).convert(utf8.encode(text)).bytes)}';
      } on FormatException {
        throw const EngineException(
            code: ErrorCode.invalidConfig,
            message: 'The Azure account key is not valid base64.');
      }
      return headers;
    }
    if (profile.connection.authMode != 'static' ||
        (profile.signerOverride?.isNotEmpty == true &&
            profile.signerOverride != 's3v4')) {
      throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message:
              'Mobile S3 administration requires Signature V4 access credentials, optionally with a session token.');
    }
    if (profile.accessKey.isEmpty || profile.secretKey.isEmpty) {
      throw const EngineException(
          code: ErrorCode.invalidConfig,
          message: 'Complete the endpoint credentials before connecting.');
    }
    final date = _awsDate(time), day = date.substring(0, 8);
    final hash = payloadSha256 ?? sha256.convert(body).toString();
    headers['x-amz-date'] = date;
    headers['x-amz-content-sha256'] = hash;
    if (profile.sessionToken?.isNotEmpty == true) {
      headers['x-amz-security-token'] = profile.sessionToken!;
    }
    if (profile.connection.requesterPays) {
      headers['x-amz-request-payer'] = 'requester';
    }
    if (profile.connection.expectedBucketOwner.isNotEmpty) {
      headers['x-amz-expected-bucket-owner'] =
          profile.connection.expectedBucketOwner;
    }
    final names = headers.keys.toList()..sort();
    final signed = names.join(';');
    final canonical = names
        .map((name) =>
            '$name:${headers[name]!.trim().replaceAll(RegExp(r'\s+'), ' ')}\n')
        .join();
    final request =
        [method, target.path, target.query, canonical, signed, hash].join('\n');
    final region = profile.region.isEmpty ? 'us-east-1' : profile.region;
    final scope = '$day/$region/s3/aws4_request';
    final signingKey = _signingKey(day, region);
    final signature = Hmac(sha256, signingKey).convert(utf8.encode(
        'AWS4-HMAC-SHA256\n$date\n$scope\n${sha256.convert(utf8.encode(request))}'));
    headers['authorization'] =
        'AWS4-HMAC-SHA256 Credential=${profile.accessKey}/$scope, SignedHeaders=$signed, Signature=$signature';
    return headers;
  }

  String presign(String bucket, String key,
      {String? versionId, int expiresSeconds = 3600}) {
    if (azure) {
      if (profile.connection.authMode == 'azureSas') {
        return uri(bucket, key, {if (versionId != null) 'versionid': versionId})
            .toString();
      }
      throw const EngineException(
          code: ErrorCode.unsupportedFeature,
          message:
              'Use a scoped SAS credential to share Azure objects on mobile.');
    }
    // Validate the same auth settings before exposing a bearer URL.
    final time = _now().toUtc(),
        region = profile.region.isEmpty ? 'us-east-1' : profile.region;
    final date = _awsDate(time), day = date.substring(0, 8);
    final scope = '$day/$region/s3/aws4_request';
    final query = <String, String>{
      'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
      'X-Amz-Credential': '${profile.accessKey}/$scope',
      'X-Amz-Date': date,
      'X-Amz-Expires': '${expiresSeconds.clamp(1, 604800)}',
      'X-Amz-SignedHeaders': 'host',
      if (versionId != null) 'versionId': versionId,
      if (profile.sessionToken?.isNotEmpty == true)
        'X-Amz-Security-Token': profile.sessionToken!,
      if (profile.connection.requesterPays) 'x-amz-request-payer': 'requester',
      if (profile.connection.expectedBucketOwner.isNotEmpty)
        'x-amz-expected-bucket-owner': profile.connection.expectedBucketOwner,
    };
    final target = uri(bucket, key, query);
    signedHeaders('GET', target, {}, [], time);
    final canonical =
        'GET\n${target.path}\n${target.query}\nhost:${target.authority}\n\nhost\nUNSIGNED-PAYLOAD';
    final signature = Hmac(sha256, _signingKey(day, region)).convert(utf8.encode(
        'AWS4-HMAC-SHA256\n$date\n$scope\n${sha256.convert(utf8.encode(canonical))}'));
    return uri(bucket, key, {...query, 'X-Amz-Signature': '$signature'})
        .toString();
  }

  List<int> _signingKey(String day, String region) {
    List<int> sign(List<int> key, String text) =>
        Hmac(sha256, key).convert(utf8.encode(text)).bytes;
    return sign(
        sign(sign(sign(utf8.encode('AWS4${profile.secretKey}'), day), region),
            's3'),
        'aws4_request');
  }

  static String _awsDate(DateTime value) =>
      '${value.toUtc().toIso8601String().replaceAll(RegExp('[-:]'), '').split('.').first}Z';
}

class StorageHttpResponse {
  const StorageHttpResponse(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
  String get text => utf8.decode(body, allowMalformed: true);
  XmlElement get xml => XmlDocument.parse(text).rootElement;
}

class StorageHttpException extends EngineException {
  StorageHttpException(this.response)
      : super(
            code: switch (response.status) {
              401 || 403 => ErrorCode.authFailed,
              409 || 412 => ErrorCode.objectConflict,
              429 => ErrorCode.throttled,
              501 || 405 => ErrorCode.unsupportedFeature,
              _ => ErrorCode.unknown,
            },
            message:
                'Storage request failed (HTTP ${response.status}, ${_errorCode(response)}).');
  final StorageHttpResponse response;
  String get serviceCode => _errorCode(response);
  static String _errorCode(StorageHttpResponse response) {
    try {
      final code = response.xml.findAllElements('Code').firstOrNull?.innerText;
      if (code != null && RegExp(r'^[A-Za-z0-9_.-]{1,120}$').hasMatch(code)) {
        return code;
      }
    } catch (_) {/* Never include an untrusted response/URL in the error. */}
    return 'request_failed';
  }
}

String storageUriEncode(String value) => Uri.encodeComponent(value)
    .replaceAll('!', '%21')
    .replaceAll("'", '%27')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29')
    .replaceAll('*', '%2A');

String storageQuery(Map<String, String> query) {
  final values = query.entries
      .map((e) => MapEntry(storageUriEncode(e.key), storageUriEncode(e.value)))
      .toList()
    ..sort((a, b) =>
        a.key == b.key ? a.value.compareTo(b.value) : a.key.compareTo(b.key));
  return values.map((e) => '${e.key}=${e.value}').join('&');
}

/// Object keys are opaque. Dart's ordinary Uri normalizes `.`/`..` segments,
/// which would change the object addressed and invalidate its S3 signature.
/// HttpClient consumes this exact encoded path; redirects are disabled above.
class ExactStorageUri implements Uri {
  const ExactStorageUri(this.base, this.path, this.query);
  final Uri base;
  @override
  final String path;
  @override
  final String query;
  @override
  String get scheme => base.scheme;
  @override
  String get authority => base.authority;
  @override
  String get userInfo => base.userInfo;
  @override
  String get host => base.host;
  @override
  int get port => base.port;
  @override
  String get fragment => '';
  @override
  bool get hasFragment => false;
  @override
  bool get isAbsolute => true;
  @override
  bool get hasScheme => true;
  @override
  bool get hasAuthority => true;
  @override
  bool get hasPort => base.hasPort;
  @override
  bool get hasQuery => query.isNotEmpty;
  @override
  bool get hasEmptyPath => path.isEmpty;
  @override
  bool get hasAbsolutePath => path.startsWith('/');
  @override
  String get origin => base.origin;
  @override
  List<String> get pathSegments =>
      path.split('/').skip(1).map(Uri.decodeComponent).toList(growable: false);
  @override
  Map<String, String> get queryParameters => Uri.splitQueryString(query);
  @override
  Map<String, List<String>> get queryParametersAll =>
      Uri(query: query).queryParametersAll;
  @override
  UriData? get data => null;
  @override
  bool isScheme(String scheme) => base.isScheme(scheme);
  @override
  Uri removeFragment() => this;
  @override
  Uri normalizePath() => this;
  @override
  String toString() => '${base.origin}$path${query.isEmpty ? '' : '?$query'}';
  @override
  String toFilePath({bool? windows}) =>
      throw UnsupportedError('A storage URI is not a file URI.');
  @override
  Uri resolve(String reference) => Uri.parse(toString()).resolve(reference);
  @override
  Uri resolveUri(Uri reference) => resolve(reference.toString());
  @override
  Uri replace(
      {String? scheme,
      String? userInfo,
      String? host,
      int? port,
      String? path,
      Iterable<String>? pathSegments,
      String? query,
      Map<String, dynamic>? queryParameters,
      String? fragment}) {
    final origin = base.replace(
        scheme: scheme, userInfo: userInfo, host: host, port: port);
    final target = pathSegments == null
        ? path ?? this.path
        : '/${pathSegments.map(storageUriEncode).join('/')}';
    final encodedQuery = queryParameters == null
        ? query ?? this.query
        : Uri(queryParameters: queryParameters).query;
    if (fragment?.isNotEmpty == true) {
      throw ArgumentError('Storage request fragments are not supported.');
    }
    return ExactStorageUri(origin, target, encodedQuery);
  }

  @override
  bool operator ==(Object other) =>
      other is Uri && toString() == other.toString();
  @override
  int get hashCode => toString().hashCode;
}
