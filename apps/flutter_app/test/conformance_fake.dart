import 'dart:convert';
import 'dart:io';

import 'package:s3_browser_crossplat/conformance/conformance_bytes.dart';
import 'package:s3_browser_crossplat/conformance/s3_op_executor.dart';

/// A small in-memory endpoint: enough S3 behaviour for staging and teardown
/// to be exercised; most specification details are deliberately not modelled.
class FakeExecutor implements S3OpExecutor {
  FakeExecutor({this.engineId = 'fake', this.ops, this.unsupportedOps = const {}, this.onCall});

  final Set<String>? ops;
  final Set<String> unsupportedOps;
  final void Function(S3OpRequest request)? onCall;
  final List<S3OpRequest> calls = [];
  final Set<String> buckets = {};
  final Map<String, Map<String, (int, String)>> objects = {};
  final List<String> customerKeys = [];
  bool capabilitySupported = true;

  /// Simulates a race: the first CreateBucket finds someone else's bucket
  /// (409) that HeadBucket did not see during preflight.
  bool collideFirstCreate = false;

  /// HeadBucket answers 403 for every name (preflight cannot confirm 404).
  bool headForbidden = false;

  /// DeleteBucket returns 204 without removing the bucket.
  bool noOpDeleteBucket = false;
  String? collidedBucket;

  @override
  final String engineId;

  @override
  Future<S3ConformanceCapability?> capability() async => S3ConformanceCapability(
        supported: capabilitySupported,
        version: 1,
        sdk: 'fake-sdk 1.0',
        ops: ops ?? allConformanceOps,
        client: const {'maxAttempts': 1},
      );

  @override
  Future<S3OpObservation> execute(S3OpRequest request) async {
    calls.add(request);
    onCall?.call(request);
    if (request.customerKey != null) customerKeys.add(request.customerKey!);
    if (request.sourceCustomerKey != null) customerKeys.add(request.sourceCustomerKey!);
    if (unsupportedOps.contains(request.op)) {
      throw const S3OpRpcException('unsupported_feature', 'not here');
    }
    final input = request.input;
    final bucket = '${input['Bucket'] ?? ''}';
    final key = '${input['Key'] ?? ''}';
    S3OpObservation ok([int status = 200, Map<String, Object?> output = const {}, Map<String, String> headers = const {}]) =>
        S3OpObservation(op: request.op, outcome: 'service', httpStatus: status, output: output, headers: {
          'date': HttpDate.format(DateTime.now().toUtc()),
          ...headers,
        }, latencyMs: 1.5);
    switch (request.op) {
      case 'CreateBucket':
        if (collideFirstCreate && collidedBucket == null) {
          collidedBucket = bucket;
          buckets.add(bucket);
          objects[bucket] = {'precious.txt': (8, 'not-ours')};
          return S3OpObservation(op: request.op, outcome: 'service', httpStatus: 409, errorCode: 'BucketAlreadyOwnedByYou', latencyMs: 1.5);
        }
        if (!buckets.add(bucket)) return ok(409);
        objects[bucket] = {};
        return ok();
      case 'HeadBucket':
        if (headForbidden) return ok(403);
        return ok(buckets.contains(bucket) ? 200 : 404);
      case 'DeleteBucket':
        if (!buckets.contains(bucket)) return ok(404);
        if (noOpDeleteBucket) return ok(204);
        if (objects[bucket]!.isNotEmpty) {
          return S3OpObservation(op: request.op, outcome: 'service', httpStatus: 409, errorCode: 'BucketNotEmpty', latencyMs: 1.5);
        }
        buckets.remove(bucket);
        objects.remove(bucket);
        return ok(204);
      case 'PutObject':
        final data = _bytes(request.body);
        objects[bucket]?[key] = (data.length, ConformanceBytes.sha256Hex(data));
        return ok(200, const {}, {'etag': '"${ConformanceBytes.md5Hex(data)}"'});
      case 'GetObject':
        final stored = objects[bucket]?[key];
        if (stored == null) {
          return S3OpObservation(op: request.op, outcome: 'service', httpStatus: 404, errorCode: 'NoSuchKey', latencyMs: 1.5);
        }
        return ok(200, {'Body': {'length': stored.$1, 'sha256': stored.$2}});
      case 'ListObjectVersions':
        return ok(200, {
          'Versions': [
            for (final k in objects[bucket]?.keys ?? const <String>[]) {'Key': k, 'VersionId': 'null', 'IsLatest': true}
          ]
        });
      case 'DeleteObjects':
        final entries = ((input['Delete'] as Map)['Objects'] as List).cast<Map>();
        for (final entry in entries) {
          objects[bucket]?.remove('${entry['Key']}');
        }
        return ok(200);
      case 'DeleteObject':
        objects[bucket]?.remove(key);
        return ok(204);
      default:
        return ok();
    }
  }

  static List<int> _bytes(S3OpBody? body) {
    final json = body?.toJson() ?? const {};
    if (json['generate'] case final Map g) return ConformanceBytes.generate(g['size'] as int, g['seed'] as int);
    if (json['text'] case final String t) return utf8.encode(t);
    if (json['base64'] case final String b) return base64.decode(b);
    return const [];
  }
}

const allConformanceOps = {
  'CreateBucket', 'HeadBucket', 'DeleteBucket', 'ListBuckets', 'GetBucketLocation', 'GetBucketVersioning',
  'PutBucketVersioning', 'GetBucketTagging', 'PutBucketTagging', 'DeleteBucketTagging', 'GetBucketCors',
  'PutBucketCors', 'DeleteBucketCors', 'GetBucketLifecycleConfiguration', 'PutBucketLifecycleConfiguration',
  'DeleteBucketLifecycle', 'GetBucketPolicy', 'PutBucketPolicy', 'DeleteBucketPolicy', 'GetBucketPolicyStatus',
  'GetBucketEncryption', 'PutBucketEncryption', 'DeleteBucketEncryption', 'GetPublicAccessBlock',
  'PutPublicAccessBlock', 'DeletePublicAccessBlock', 'GetBucketOwnershipControls', 'PutBucketOwnershipControls',
  'DeleteBucketOwnershipControls', 'GetBucketAcl', 'PutBucketAcl', 'GetBucketAccelerateConfiguration',
  'PutBucketAccelerateConfiguration', 'GetBucketRequestPayment', 'PutBucketRequestPayment', 'GetBucketLogging',
  'GetBucketWebsite', 'PutBucketWebsite', 'DeleteBucketWebsite', 'GetBucketNotificationConfiguration',
  'PutBucketNotificationConfiguration', 'GetBucketReplication', 'DeleteBucketReplication',
  'ListBucketAnalyticsConfigurations', 'GetBucketAnalyticsConfiguration', 'PutBucketAnalyticsConfiguration',
  'DeleteBucketAnalyticsConfiguration', 'ListBucketMetricsConfigurations', 'GetBucketMetricsConfiguration',
  'PutBucketMetricsConfiguration', 'DeleteBucketMetricsConfiguration', 'ListBucketInventoryConfigurations',
  'GetBucketInventoryConfiguration', 'PutBucketInventoryConfiguration', 'DeleteBucketInventoryConfiguration',
  'ListBucketIntelligentTieringConfigurations', 'GetBucketIntelligentTieringConfiguration',
  'PutBucketIntelligentTieringConfiguration', 'DeleteBucketIntelligentTieringConfiguration',
  'GetObjectLockConfiguration', 'PutObjectLockConfiguration', 'PutObject', 'GetObject', 'HeadObject',
  'DeleteObject', 'DeleteObjects', 'CopyObject', 'GetObjectAttributes', 'ListObjects', 'ListObjectsV2',
  'ListObjectVersions', 'GetObjectTagging', 'PutObjectTagging', 'DeleteObjectTagging', 'GetObjectAcl',
  'PutObjectAcl', 'CreateMultipartUpload', 'UploadPart', 'UploadPartCopy', 'ListParts', 'ListMultipartUploads',
  'CompleteMultipartUpload', 'AbortMultipartUpload', 'GetObjectRetention', 'PutObjectRetention',
  'GetObjectLegalHold', 'PutObjectLegalHold', 'PresignedRequest',
};

