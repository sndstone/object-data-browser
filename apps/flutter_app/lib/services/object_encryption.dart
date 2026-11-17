import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../models/domain_models.dart';

typedef CustomerKeyResolver = FutureOr<Uint8List> Function(String id);

class EncryptionDispatchException extends EngineException {
  const EncryptionDispatchException()
      : super(
          code: ErrorCode.invalidConfig,
          message:
              'The customer key cannot be resolved. Choose or unlock a key in your encryption key file.',
        );
}

mixin EngineEncryptionResolver {
  CustomerKeyResolver? customerKeyResolver;

  Future<Map<String, Object?>> encryptionArguments(
    EndpointProfile source,
    EndpointProfile? destination,
    Map<String, Object?> arguments,
  ) async {
    if (arguments['encryption'] is! ObjectEncryption &&
        arguments['sourceEncryption'] is! ObjectEncryption) {
      return arguments;
    }
    return {
      ...arguments,
      if (arguments['encryption'] is ObjectEncryption)
        'encryption': await encryptionPayload(
          destination ?? source,
          arguments['encryption'] as ObjectEncryption,
        ),
      if (arguments['sourceEncryption'] is ObjectEncryption)
        'sourceEncryption': await encryptionPayload(
          source,
          arguments['sourceEncryption'] as ObjectEncryption,
          source: true,
        ),
    };
  }

  Future<Map<String, Object?>> encryptionPayload(
    EndpointProfile profile,
    ObjectEncryption encryption, {
    bool source = false,
  }) async {
    final result = encryption.toJson()
      ..remove('customerKeyId')
      ..remove('customerKeyFingerprint');
    if (encryption.mode.isCustomerKey) {
      final resolver = customerKeyResolver;
      final id = encryption.customerKeyId;
      if (resolver == null || id == null) {
        throw const EncryptionDispatchException();
      }
      Uint8List? bytes;
      try {
        bytes = await resolver(id);
        if (bytes.length != 32) throw const EncryptionDispatchException();
        if (encryption.customerKeyFingerprint != null &&
            encryption.customerKeyFingerprint !=
                base64Encode(sha256.convert(bytes).bytes)) {
          throw const EncryptionDispatchException();
        }
        result['customerKey'] = base64Encode(bytes);
      } catch (_) {
        throw const EncryptionDispatchException();
      } finally {
        bytes?.fillRange(0, bytes.length, 0);
      }
    }
    validateObjectEncryption(profile, result, source: source);
    return result;
  }
}

bool customerKeyEndpointAllowed(EndpointProfile profile) {
  if (profile.endpointUrl.isEmpty &&
      (profile.endpointType.isAzure ||
          profile.endpointType == EndpointProfileType.awsS3)) {
    return true;
  }
  final endpoint = Uri.tryParse(profile.endpointUrl);
  final host = endpoint?.host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  final parts = host?.split('.') ?? const <String>[];
  final address = parts.length == 4 &&
      parts.first == '127' &&
      parts.every(
        (part) =>
            int.tryParse(part) != null &&
            int.parse(part) >= 0 &&
            int.parse(part) <= 255,
      );
  return endpoint?.scheme == 'https' ||
      (endpoint?.scheme == 'http' &&
          (host == 'localhost' || host == '::1' || address == true));
}

void validateObjectEncryption(
  EndpointProfile profile,
  Map<String, Object?>? value, {
  bool source = false,
}) {
  if (value == null) return;
  Never invalid() => throw const EngineException(
        code: ErrorCode.invalidConfig,
        message:
            'The encryption settings are invalid for this provider or endpoint. Customer keys require 32 bytes and HTTPS (or loopback).',
      );
  final mode = ObjectEncryptionMode.values
      .where((m) => m.wireName == value['mode'])
      .firstOrNull;
  if (mode == null || (source && !mode.isCustomerKey)) invalid();
  if (profile.endpointType.isGoogleCloudStorage &&
      mode != ObjectEncryptionMode.bucketDefault) {
    invalid();
  }
  if (mode != ObjectEncryptionMode.bucketDefault &&
      mode.isAzure != profile.endpointType.isAzure) {
    invalid();
  }
  final allowed = <String>{
    'mode',
    if (mode == ObjectEncryptionMode.sseKms ||
        mode == ObjectEncryptionMode.dsseKms) ...[
      'kmsKeyId',
      'kmsEncryptionContext',
    ],
    if (mode == ObjectEncryptionMode.sseKms) 'bucketKeyEnabled',
    if (mode == ObjectEncryptionMode.azureScope) 'encryptionScope',
    if (mode.isCustomerKey) 'customerKey',
  };
  if (value.keys.any((key) => !allowed.contains(key))) invalid();
  for (final key in ['kmsKeyId', 'encryptionScope']) {
    if (value.containsKey(key) &&
        (value[key] is! String || (value[key] as String).trim().isEmpty)) {
      invalid();
    }
  }
  if (mode == ObjectEncryptionMode.azureScope &&
      !value.containsKey('encryptionScope')) {
    invalid();
  }
  if (value.containsKey('bucketKeyEnabled') &&
      value['bucketKeyEnabled'] is! bool) {
    invalid();
  }
  final context = value['kmsEncryptionContext'];
  if (context != null &&
      (context is! Map ||
          context.entries.any((e) => e.key is! String || e.value is! String))) {
    invalid();
  }
  if (mode.isCustomerKey) {
    if (!customerKeyEndpointAllowed(profile)) invalid();
    try {
      if (base64Decode(value['customerKey'] as String).length != 32) invalid();
    } catch (_) {
      invalid();
    }
  }
}

Map<String, String> objectEncryptionHeaders(
  EndpointProfile profile,
  Object? encryption, {
  bool read = false,
  bool source = false,
}) {
  if (encryption == null) return {};
  if (encryption is! Map) {
    throw const EngineException(
      code: ErrorCode.invalidConfig,
      message: 'Invalid encryption settings.',
    );
  }
  final value = Map<String, Object?>.from(encryption);
  validateObjectEncryption(profile, value, source: source);
  final mode = ObjectEncryptionMode.parse(value['mode'] as String);
  if (read && !mode.isCustomerKey) return {};
  switch (mode) {
    case ObjectEncryptionMode.bucketDefault:
      return {};
    case ObjectEncryptionMode.sseS3:
      return {'x-amz-server-side-encryption': 'AES256'};
    case ObjectEncryptionMode.sseKms:
    case ObjectEncryptionMode.dsseKms:
      return {
        'x-amz-server-side-encryption':
            mode == ObjectEncryptionMode.sseKms ? 'aws:kms' : 'aws:kms:dsse',
        if (value['kmsKeyId'] != null)
          'x-amz-server-side-encryption-aws-kms-key-id':
              value['kmsKeyId'] as String,
        if (value['kmsEncryptionContext'] != null)
          'x-amz-server-side-encryption-context': base64Encode(
            utf8.encode(jsonEncode(value['kmsEncryptionContext'])),
          ),
        if (value['bucketKeyEnabled'] != null)
          'x-amz-server-side-encryption-bucket-key-enabled':
              '${value['bucketKeyEnabled']}',
      };
    case ObjectEncryptionMode.sseC:
      final prefix = source
          ? 'x-amz-copy-source-server-side-encryption-customer-'
          : 'x-amz-server-side-encryption-customer-';
      return {
        '${prefix}algorithm': 'AES256',
        '${prefix}key': value['customerKey'] as String,
        '${prefix}key-md5': base64Encode(
          md5.convert(base64Decode(value['customerKey'] as String)).bytes,
        ),
      };
    case ObjectEncryptionMode.azureScope:
      return {'x-ms-encryption-scope': value['encryptionScope'] as String};
    case ObjectEncryptionMode.azureCpk:
      return {
        'x-ms-encryption-algorithm': 'AES256',
        'x-ms-encryption-key': value['customerKey'] as String,
        'x-ms-encryption-key-sha256': base64Encode(
          sha256.convert(base64Decode(value['customerKey'] as String)).bytes,
        ),
      };
  }
}

Map<String, Object?>? objectEncryptionInfo(
  Map<String, String> h, {
  bool azure = false,
}) {
  if (azure) {
    final hash = h['x-ms-encryption-key-sha256'],
        scope = h['x-ms-encryption-scope'];
    if (hash == null && scope == null && h['x-ms-server-encrypted'] == null) {
      return null;
    }
    return {
      'mode': hash != null
          ? 'azure-cpk'
          : scope != null
              ? 'azure-scope'
              : 'provider',
      if (hash != null) 'customerKeySha256': hash,
      if (scope != null) 'encryptionScope': scope,
      if (h['x-ms-server-encrypted'] != null)
        'serverEncrypted': h['x-ms-server-encrypted'] == 'true',
    };
  }
  final algorithm = h['x-amz-server-side-encryption'];
  final customer =
      h['x-amz-server-side-encryption-customer-algorithm'] != null ||
          h['x-amz-server-side-encryption-customer-key-md5'] != null;
  final mode = customer
      ? 'sse-c'
      : switch (algorithm) {
          'AES256' => 'sse-s3',
          'aws:kms' => 'sse-kms',
          'aws:kms:dsse' => 'dsse-kms',
          _ => null,
        };
  if (mode == null) return null;
  return {
    'mode': mode,
    if (h['x-amz-server-side-encryption-aws-kms-key-id'] != null)
      'kmsKeyId': h['x-amz-server-side-encryption-aws-kms-key-id'],
    if (h['x-amz-server-side-encryption-bucket-key-enabled'] != null)
      'bucketKeyEnabled':
          h['x-amz-server-side-encryption-bucket-key-enabled'] == 'true',
    if (h['x-amz-server-side-encryption-customer-key-md5'] != null)
      'customerKeyMd5': h['x-amz-server-side-encryption-customer-key-md5'],
  };
}

void rejectCustomerKeyPresign(EndpointProfile profile, Object? encryption) {
  objectEncryptionHeaders(profile, encryption, read: true);
  if (encryption is Map &&
      {'sse-c', 'azure-cpk'}.contains(encryption['mode'])) {
    throw const EngineException(
      code: ErrorCode.unsupportedFeature,
      message:
          'Objects encrypted with a customer key cannot be shared through a presigned URL.',
    );
  }
}
