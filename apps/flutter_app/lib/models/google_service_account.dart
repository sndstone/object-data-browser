import 'dart:convert';

/// Parses only the identity needed by the editor. Never includes input in errors.
class GoogleServiceAccount {
  const GoogleServiceAccount(this.email, this.projectId);
  final String email, projectId;

  factory GoogleServiceAccount.parse(String json) {
    Object? value;
    try {
      value = jsonDecode(json);
    } on FormatException {
      throw const FormatException('Enter a valid JSON service-account key.');
    }
    if (value is! Map || value['type'] != 'service_account') {
      throw const FormatException('The key must have type "service_account".');
    }
    for (final field in ['client_email', 'private_key', 'project_id']) {
      if (value[field] is! String || (value[field] as String).trim().isEmpty) {
        throw FormatException('The service-account key is missing $field.');
      }
    }
    return GoogleServiceAccount(
      value['client_email'] as String,
      value['project_id'] as String,
    );
  }
}
