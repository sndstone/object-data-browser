// Coordinator: this suite needs permission to bind a loopback socket.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/key_file_sync_transport.dart';
import 'support/key_file_sync_scenarios.dart' as checks;

class _VerifiedFixtureTransport extends S3KeyFileSyncTransport {
  _VerifiedFixtureTransport(super.profile, this.fixture);

  final checks.MemoryS3 fixture;

  @override
  bool get enforcesConditionalWrites => fixture.verified;
}

void main() {
  test('automatic sync writes require a standard TLS-verified AWS endpoint',
      () {
    const aws = EndpointProfile(
        id: 'p',
        name: 'AWS',
        endpointType: EndpointProfileType.awsS3,
        endpointUrl: 'https://s3.us-east-1.amazonaws.com',
        region: 'us-east-1',
        accessKey: 'fixture-access',
        secretKey: 'fixture-secret',
        pathStyle: false,
        verifyTls: true);
    for (final (profile, permitted) in [
      (aws, true),
      (aws.copyWith(verifyTls: false), false),
      (aws.copyWith(endpointUrl: 'http://s3.us-east-1.amazonaws.com'), false),
      (
        aws.copyWith(
            endpointUrl: 'https://s3.us-east-1.amazonaws.com.example.test'),
        false
      ),
      (
        aws.copyWith(endpointUrl: 'https://s3.us-east-1.amazonaws.com/proxy'),
        false
      ),
      (aws.copyWith(endpointType: EndpointProfileType.s3Compatible), false),
    ]) {
      final transport = S3KeyFileSyncTransport(profile);
      try {
        expect(transport.enforcesConditionalWrites, permitted);
      } finally {
        transport.close();
      }
    }
  });

  // These are plain tests. Flutter's widget binding HTTP override must not
  // intercept the signed pure-Dart client talking to the in-process server.
  setUpAll(() {
    HttpOverrides.global = null;
    checks.transportHarness = (fixture) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = server.forEach((request) async {
        try {
          final body = await request
              .fold<List<int>>([], (all, chunk) => all..addAll(chunk));
          final headers = <String, String>{};
          request.headers
              .forEach((name, values) => headers[name] = values.join(','));
          final segments = request.uri.pathSegments;
          final response = await fixture.request(request.method, segments.first,
              key: segments.length > 1 ? segments.skip(1).join('/') : null,
              query: request.uri.queryParameters,
              headers: headers,
              body: body);
          request.response.statusCode = response.status;
          response.headers.forEach(request.response.headers.set);
          if (request.method != 'HEAD') request.response.add(response.body);
          await request.response.close();
        } on HttpException {
          /* The client may close during a response. */
        } on SocketException {/* Test teardown may close active clients. */}
      });
      final profile = EndpointProfile(
          id: 'p',
          name: 'Fixture',
          endpointUrl: 'http://127.0.0.1:${server.port}',
          region: 'us-east-1',
          accessKey: 'fixture-access',
          secretKey: 'fixture-secret',
          pathStyle: true,
          verifyTls: true,
          maxAttempts: 1);
      return (
        create: () => _VerifiedFixtureTransport(profile, fixture),
        close: () async {
          await server.close(force: true);
          await serving;
        }
      );
    };
  });
  tearDownAll(() {
    checks.transportHarness = null;
  });
  for (final entry in checks.scenarios.entries) {
    test('HTTP: ${entry.key}', entry.value);
  }
}
