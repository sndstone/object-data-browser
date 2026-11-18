import 'package:xml/xml.dart';
import '../models/domain_models.dart';
import 'key_file_sync.dart';
import 'storage_http_client.dart';

String? keyFileSyncProfileIneligibility(EndpointProfile profile) {
  if (profile.endpointType != EndpointProfileType.s3Compatible &&
      profile.endpointType != EndpointProfileType.awsS3) {
    return 'Key file sync requires an S3 profile.';
  }
  if (profile.connection.authMode != 'static') {
    return 'Key file sync requires static credentials.';
  }
  if (profile.accessKey.isEmpty || profile.secretKey.isEmpty) {
    return 'Enter and save static credentials first.';
  }
  return null;
}

/// Uses the same signed pure-Dart transport on phones and desktop. No engine
/// requests, task records, previews, or encryption headers are involved.
class S3KeyFileSyncTransport implements KeyFileSyncSetupTransport {
  S3KeyFileSyncTransport(EndpointProfile profile) : _client = _create(profile);
  static StorageHttpClient _create(EndpointProfile profile) {
    final reason = keyFileSyncProfileIneligibility(profile);
    if (reason != null) throw KeyFileSyncException(reason);
    return StorageHttpClient(profile);
  }

  final StorageHttpClient _client;
  @override
  bool get enforcesConditionalWrites =>
      _client.profile.verifyTls &&
      isStandardAwsStorageEndpoint(_client.profile);

  @override
  Future<KeyFileSyncResponse> request(
    String method,
    String bucket, {
    String? key,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
    List<int> body = const [],
  }) async {
    StorageHttpResponse response;
    try {
      response = await _client.request(method, bucket,
          key: key,
          query: query,
          headers: headers,
          body: body,
          maxResponseBytes: 8 * 1024 * 1024,
          retrySafe: method == 'GET' || method == 'HEAD');
    } on StorageHttpException catch (failure) {
      response = failure.response;
    }
    return KeyFileSyncResponse(
        response.status, response.headers, response.body);
  }

  @override
  Future<List<String>> buckets() async {
    final response = await _client.request('GET', '');
    return response.xml
        .findAllElements('Bucket')
        .map((element) => element.getElement('Name')?.innerText ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
  }

  @override
  Future<void> createBucket(String bucket) async {
    // AWS requires a location constraint outside us-east-1.
    final region = _client.profile.region;
    final body = _client.profile.endpointType == EndpointProfileType.awsS3 &&
            region != 'us-east-1' &&
            region.isNotEmpty
        ? '<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><LocationConstraint>$region</LocationConstraint></CreateBucketConfiguration>'
        : '';
    await _client.request('PUT', bucket,
        body: body.codeUnits, retrySafe: false);
    await _client.request('PUT', bucket,
        query: {'versioning': ''},
        body:
            '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>'
                .codeUnits,
        retrySafe: false);
  }

  @override
  void close() => _client.close();
}
