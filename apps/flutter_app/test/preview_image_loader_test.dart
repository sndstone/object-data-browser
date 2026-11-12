import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/preview_image_loader.dart';

void main() {
  test('image loader bounds chunked bytes before decoding', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add(List.filled(1024, 65));
      await request.response.close();
    });
    final loader = PreviewImageLoader(maximumBytes: 128);
    addTearDown(loader.close);
    await expectLater(
        loader.load('http://127.0.0.1:${server.port}/too-large', cache: false),
        throwsFormatException);
  });
  test('image errors cannot decode as successful preview data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = 403;
      request.response.write('<Error>AccessDenied</Error>');
      await request.response.close();
    });
    final loader = PreviewImageLoader();
    addTearDown(loader.close);
    await expectLater(
        loader.load('http://127.0.0.1:${server.port}/denied', cache: false),
        throwsA(isA<HttpException>()));
  });
  test(
      'image identity condition is sent and dimensions read without full decode',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? match;
    server.listen((request) async {
      match = request.headers.value(HttpHeaders.ifMatchHeader);
      request.response.add(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII='));
      await request.response.close();
    });
    final loader = PreviewImageLoader();
    addTearDown(loader.close);
    final data = await loader.load('http://127.0.0.1:${server.port}/one',
        etag: '"original"', cache: false);
    expect(match, '"original"');
    expect((data.width, data.height), (1, 1));
  });
}
