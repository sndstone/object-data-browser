import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/services/source_preview.dart';

void main() {
  test('detects source languages from extensions and content types', () {
    expect(sourcePreviewLanguage('src/main.dart', null), 'dart');
    expect(sourcePreviewLanguage('config/settings.yaml', null), 'yaml');
    expect(sourcePreviewLanguage('Dockerfile', null), 'dockerfile');
    expect(sourcePreviewLanguage('object', 'application/json'), 'json');
    expect(sourcePreviewLanguage('notes.txt', 'text/plain'), isNull);
  });

  test('recognizes HTML independently of content type parameters', () {
    expect(isHtmlPreview('site/index.html', null), isTrue);
    expect(isHtmlPreview('object', 'text/html; charset=utf-8'), isTrue);
    expect(isHtmlPreview('site/index.xml', 'application/xml'), isFalse);
  });
}
