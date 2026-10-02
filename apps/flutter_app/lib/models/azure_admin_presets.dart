import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Azure management policies replace an account-wide document. Only the exact
/// app-owned rule for this container/prefix is changed by these presets.
class AzureLifecyclePresets {
  static const choices = <String, String>{
    'cool': 'Move to Cool',
    'archive': 'Cool, then Archive',
    'coldArchive': 'Cool, Cold, then Archive',
    'disabled': 'Disable this app preset',
  };

  static String ruleName(String bucket, String prefix) =>
      'object-browser-${sha256.convert(utf8.encode('$bucket/$prefix')).toString().substring(0, 24)}';

  static Map<String, Object?> build({
    required Map<String, Object?>? currentPolicy,
    required String preset,
    required String bucket,
    String prefix = '',
    int coolDays = 30,
    int coldDays = 90,
    int archiveDays = 180,
  }) {
    if (!choices.containsKey(preset)) {
      throw const FormatException('Choose a lifecycle preset.');
    }
    if (!RegExp(r'^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$').hasMatch(bucket)) {
      throw const FormatException('A valid Azure container is required.');
    }
    if (prefix.startsWith('/')) {
      throw const FormatException(
          'The prefix must be relative to the container.');
    }
    if (preset != 'disabled' && (coolDays < 1 || coolDays > 36500)) {
      throw const FormatException('Cool age must be between 1 and 36500 days.');
    }
    if (preset == 'coldArchive' && coldDays <= coolDays) {
      throw const FormatException('Cold age must be greater than Cool age.');
    }
    if ({'archive', 'coldArchive'}.contains(preset) &&
        (archiveDays <= (preset == 'coldArchive' ? coldDays : coolDays) ||
            archiveDays > 36500)) {
      throw const FormatException(
          'Archive age must follow earlier tiers and be at most 36500 days.');
    }
    final result = Map<String, Object?>.from(
        jsonDecode(jsonEncode(currentPolicy ?? <String, Object?>{})) as Map);
    final existing = result['rules'];
    if (existing != null && existing is! List) {
      throw const FormatException(
          'Existing account lifecycle rules are malformed.');
    }
    final id = ruleName(bucket, prefix);
    final rules = <Object?>[
      for (final rule in existing as List? ?? const [])
        if (rule is! Map || rule['name'] != id) rule,
    ];
    if (preset != 'disabled') {
      rules.add({
        'name': id,
        'enabled': true,
        'type': 'Lifecycle',
        'definition': {
          'filters': {
            'blobTypes': ['blockBlob'],
            'prefixMatch': ['$bucket/$prefix'],
          },
          'actions': {
            'baseBlob': {
              'tierToCool': {'daysAfterModificationGreaterThan': coolDays},
              if (preset == 'coldArchive')
                'tierToCold': {'daysAfterModificationGreaterThan': coldDays},
              if ({'archive', 'coldArchive'}.contains(preset))
                'tierToArchive': {
                  'daysAfterModificationGreaterThan': archiveDays,
                },
            },
          },
        },
      });
    }
    result['rules'] = rules;
    return result;
  }
}

class AdlsAclEntry {
  const AdlsAclEntry({
    required this.type,
    this.identity = '',
    this.permissions = 'r-x',
    this.isDefault = false,
  });
  final String type, identity, permissions;
  final bool isDefault;

  AdlsAclEntry copyWith(
          {String? type,
          String? identity,
          String? permissions,
          bool? isDefault}) =>
      AdlsAclEntry(
          type: type ?? this.type,
          identity: identity ?? this.identity,
          permissions: permissions ?? this.permissions,
          isDefault: isDefault ?? this.isDefault);

  String encode() {
    if (!{'user', 'group', 'mask', 'other'}.contains(type) ||
        !RegExp(r'^[r-][w-][x-]$').hasMatch(permissions) ||
        identity.contains(RegExp(r'[:,\r\n]')) ||
        ({'mask', 'other'}.contains(type) && identity.isNotEmpty)) {
      throw const FormatException('Check ACL type, identity and permissions.');
    }
    return '${isDefault ? 'default:' : ''}$type:$identity:$permissions';
  }

  static List<AdlsAclEntry> parse(String value) => value.isEmpty
      ? const []
      : value.split(',').map((text) {
          final parts = text.split(':');
          final isDefault = parts.first == 'default';
          if (parts.length != (isDefault ? 4 : 3)) {
            throw const FormatException(
                'The provider returned an invalid ACL entry.');
          }
          final offset = isDefault ? 1 : 0;
          final entry = AdlsAclEntry(
              type: parts[offset],
              identity: parts[offset + 1],
              permissions: parts[offset + 2],
              isDefault: isDefault);
          entry.encode();
          return entry;
        }).toList();

  static String encodeAll(List<AdlsAclEntry> entries) {
    final identities = <String>{};
    for (final entry in entries) {
      if (!identities
          .add('${entry.isDefault}/${entry.type}/${entry.identity}')) {
        throw const FormatException(
            'An ACL identity appears more than once in the same scope.');
      }
    }
    for (final scope in [false, true]) {
      final scoped =
          entries.where((entry) => entry.isDefault == scope).toList();
      if (scoped.isEmpty && scope) continue;
      for (final type in ['user', 'group', 'other']) {
        if (!scoped
            .any((entry) => entry.type == type && entry.identity.isEmpty)) {
          throw const FormatException(
              'Each ACL scope needs the owning user, owning group and other entry.');
        }
      }
      if (scoped.any((entry) => entry.identity.isNotEmpty) &&
          !scoped.any((entry) => entry.type == 'mask')) {
        throw const FormatException(
            'Named user/group ACL entries need a mask entry in the same scope.');
      }
    }
    return entries.map((entry) => entry.encode()).join(',');
  }
}
