import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/app/version_details.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/settings/version_details_catalog.dart';

void main() {
  test('application version is 2.2.7', () {
    expect(kApplicationVersion, '2.2.7');
    expect(kApplicationBuild, '2.2.7+1');
  });

  test('android version details exclude desktop-only dependency entries', () {
    final versions = visibleDependencyVersions(isMobile: true);

    expect(versions.containsKey('desktop_drop'), isFalse);
    expect(versions.containsKey('file_picker'), isTrue);
    expect(versions.containsKey('flutter_secure_storage'), isTrue);
  });

  test('android bundled component versions only show available android engines',
      () {
    final versions = visibleBundledComponentVersions(
      isMobile: true,
      engines: const [
        EngineDescriptor(
          id: 'go',
          label: 'Go Engine',
          language: 'Go',
          version: '2.2.5',
          available: true,
          desktopSupported: true,
          mobileSupported: true,
        ),
        EngineDescriptor(
          id: 'rust',
          label: 'Rust Engine',
          language: 'Rust',
          version: '2.2.5',
          available: true,
          desktopSupported: true,
          mobileSupported: true,
        ),
        EngineDescriptor(
          id: 'java',
          label: 'Java Engine',
          language: 'Java',
          version: '2.2.5',
          available: true,
          desktopSupported: true,
          mobileSupported: false,
        ),
        EngineDescriptor(
          id: 'python',
          label: 'Python Engine',
          language: 'Python',
          version: '2.2.5',
          available: false,
          desktopSupported: true,
          mobileSupported: true,
        ),
      ],
    );

    expect(versions, {
      'Go Engine': '2.2.5',
      'Rust Engine': '2.2.5',
    });
  });
}
