import '../app/version_details.dart';
import '../models/domain_models.dart';

Map<String, String> visibleDependencyVersions({required bool isMobile}) {
  if (!isMobile) {
    return kFlutterDependencyVersions;
  }
  return Map<String, String>.fromEntries(
    kFlutterDependencyVersions.entries.where(
      (entry) => entry.key != 'desktop_drop',
    ),
  );
}

Map<String, String> visibleBundledComponentVersions({
  required bool isMobile,
  required List<EngineDescriptor> engines,
}) {
  if (!isMobile) {
    return kBundledEngineVersions;
  }
  return <String, String>{
    for (final engine in engines)
      if (engine.mobileSupported && engine.available)
        engine.label: engine.version,
  };
}
