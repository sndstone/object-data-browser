import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/mobile_storage_admin.dart';
import 'package:xml/xml.dart';

/// Binary REST fixture shared by adapter and controller integration tests.
class MobileAgeFixture {
  MobileAgeFixture(this.azure);
  final bool azure;
  late HttpServer server;
  late Directory directory;
  final admin = MobileStorageAdmin();
  late EndpointProfile profile;
  final objects = <String, Uint8List>{};
  final parts = <String, Uint8List>{};
  final requests = <({
    String method,
    Uri uri,
    Map<String, String> headers,
    Uint8List body
  })>[];
  final events = <Map<String, Object?>>[];
  bool failPartOnce = false, reverseParts = false;
  final _laterPart = Completer<void>();
  Future<void> Function()? onFailedPart;
  int aborts = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    directory = await Directory.systemTemp.createTemp('mobile-age-');
    profile = EndpointProfile(
        id: 'fixture',
        name: 'Fixture',
        endpointUrl: 'http://127.0.0.1:${server.port}',
        region: 'us-east-1',
        accessKey: 'test',
        secretKey: azure ? base64Encode(utf8.encode('secret')) : 'secret',
        endpointType: azure
            ? EndpointProfileType.azureBlob
            : EndpointProfileType.s3Compatible,
        pathStyle: true,
        verifyTls: true,
        maxAttempts: 2,
        maxConcurrentRequests: 2);
    admin.onTransfer = (event) => events.add(event);
    server.listen(_serve);
  }

  Future<void> _serve(HttpRequest request) async {
    final builder = BytesBuilder();
    try {
      await for (final bytes in request) {
        builder.add(bytes);
      }
    } on HttpException {
      // The adapter hangs up mid-body when it aborts an upload.
      return;
    }
    final body = builder.takeBytes();
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    requests.add((
      method: request.method,
      uri: request.uri,
      headers: headers,
      body: body
    ));
    final response = request.response;
    final key = request.uri.pathSegments.skip(1).join('/');
    final query = request.uri.queryParameters;
    response.headers.set('etag', '"fixture"');
    if (request.method == 'HEAD') {
      final object = objects[key];
      if (object == null) {
        response.statusCode = 404;
      } else {
        response.contentLength = object.length;
      }
    } else if (request.method == 'GET') {
      final object = objects[key]!;
      final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(headers['range']!)!;
      final start = int.parse(range[1]!), end = int.parse(range[2]!);
      response.statusCode = 206;
      response.headers
          .set('content-range', 'bytes $start-$end/${object.length}');
      response.add(Uint8List.sublistView(object, start, end + 1));
    } else if (request.method == 'DELETE') {
      aborts++;
    } else if (request.method == 'POST' && query.containsKey('uploads')) {
      response.write(
          '<InitiateMultipartUploadResult><UploadId>fixture</UploadId></InitiateMultipartUploadResult>');
    } else if (request.method == 'POST' && query.containsKey('uploadId')) {
      final document = XmlDocument.parse(utf8.decode(body));
      final ids =
          document.findAllElements('PartNumber').map((e) => e.innerText);
      objects[key] =
          (BytesBuilder()..addAll(ids.map((id) => parts[id]!))).takeBytes();
      response.write(
          '<CompleteMultipartUploadResult><ETag>"fixture"</ETag></CompleteMultipartUploadResult>');
    } else if (query['comp'] == 'blocklist') {
      final ids = XmlDocument.parse(utf8.decode(body))
          .findAllElements('Latest')
          .map((e) => e.innerText);
      objects[key] =
          (BytesBuilder()..addAll(ids.map((id) => parts[id]!))).takeBytes();
    } else if (request.method == 'PUT') {
      final part = query['partNumber'] ?? query['blockid'];
      if (part != null && reverseParts) {
        final first = azure
            ? utf8.decode(base64Decode(part)).endsWith('-000000')
            : part == '1';
        if (first) {
          await _laterPart.future;
        } else if (!_laterPart.isCompleted) {
          _laterPart.complete();
        }
      }
      if (part != null && failPartOnce) {
        failPartOnce = false;
        response.statusCode = 503;
        response.headers.set('retry-after', '0');
        await onFailedPart?.call();
      } else if (part != null) {
        parts[part] = body;
      } else {
        objects[key] = body;
      }
    }
    await response.close();
  }

  Future<Map<String, Object?>> dispatch(
          String method, Map<String, Object?> args) =>
      admin.dispatch(method,
          {'profile': profile.toJson(), 'bucketName': 'bucket', ...args});

  Future<void> upload(Map<String, dynamic> vector,
      {bool multipart = false,
      bool encrypted = true,
      Object? providerEncryption}) async {
    final file = File('${directory.path}/source');
    await file.writeAsBytes(vectorPlaintext(vector));
    await dispatch('startUpload', {
      'filePaths': [file.path],
      'objectKeyByPath': {file.path: 'report.pdf.age'},
      'multipartThresholdMiB': multipart ? 1 : 32,
      'multipartChunkMiB': 5,
      if (providerEncryption != null) 'encryption': providerEncryption,
      if (encrypted)
        'clientEncryption': {
          'format': 'age-v1',
          'header': vector['header'],
          'fileKey': vector['fileKey'],
          'payloadNonce': vector['payloadNonce']
        }
    });
  }

  Future<Map<String, Object?>> download(Map<String, dynamic> vector,
          {String key = 'report.pdf.age'}) =>
      admin.download(profile, {
        'bucketName': 'bucket',
        'key': key,
        'destinationPath': directory.path,
        'clientEncryption': {
          'format': 'age-v1',
          'fileKey': vector['fileKey'],
          'headerLength': vector['headerLength']
        }
      });

  Future<void> close() async {
    admin.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}

extension on BytesBuilder {
  void addAll(Iterable<List<int>> chunks) {
    for (final chunk in chunks) {
      add(chunk);
    }
  }
}

Uint8List vectorPlaintext(Map<String, dynamic> vector) =>
    Uint8List.fromList(List.generate(vector['plaintextLength'] as int,
        (i) => (i * 31 + (i >> 8) * 7 + 3) & 255));

List<Map<String, dynamic>> mobileAgeVectors() =>
    (jsonDecode(File('../../contracts/vectors/age-stream.json')
            .readAsStringSync())['cases'] as List)
        .cast<Map<String, dynamic>>();

String objectDigest(List<int> bytes) => sha256.convert(bytes).toString();
