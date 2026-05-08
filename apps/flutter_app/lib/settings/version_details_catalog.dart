import '../app/version_details.dart';
import '../models/domain_models.dart';

Map<String, String> visibleDependencyVersions({required bool isAndroid}) {
  if (!isAndroid) {
    return kFlutterDependencyVersions;
  }
  return Map<String, String>.fromEntries(
    kFlutterDependencyVersions.entries.where(
      (entry) => entry.key != 'desktop_drop',
    ),
  );
}

Map<String, String> visibleBundledComponentVersions({
  required bool isAndroid,
  required List<EngineDescriptor> engines,
}) {
  if (!isAndroid) {
    return kBundledEngineVersions;
  }
  return <String, String>{
    for (final engine in engines)
      if (engine.androidSupported && engine.available)
        engine.label: engine.version,
  };
}
