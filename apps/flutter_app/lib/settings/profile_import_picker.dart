import 'package:file_picker/file_picker.dart';

FileType profileImportPickerType({required bool isAndroid}) {
  return isAndroid ? FileType.any : FileType.custom;
}

List<String>? profileImportAllowedExtensions({required bool isAndroid}) {
  return isAndroid ? null : const ['json'];
}

bool isJsonProfileImportSelection(PlatformFile file) {
  return <String>[file.name, if (file.path != null) file.path!]
      .where((candidate) => candidate.isNotEmpty)
      .any((candidate) => candidate.toLowerCase().endsWith('.json'));
}
