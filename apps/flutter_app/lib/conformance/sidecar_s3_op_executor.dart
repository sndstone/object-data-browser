import '../models/domain_models.dart';
import 's3_op_executor.dart';

/// Implemented only by the desktop sidecar engine service. Mobile engine
/// services never implement it, so the conformance feature cannot run there.
abstract interface class S3ConformanceTransport {
  /// Sends `getCapabilities` or `s3ConformanceOp` to [engineId] without any
  /// fallback service. Throws [EngineException] for RPC errors.
  Future<Map<String, Object?>> conformanceRequest({
    required String engineId,
    required EndpointProfile profile,
    required String method,
    Map<String, Object?> params,
  });
}

/// [S3OpExecutor] over the app's desktop engine processes.
class SidecarS3OpExecutor implements S3OpExecutor {
  SidecarS3OpExecutor({
    required this.engineId,
    required this.transport,
    required this.profile,
  });

  @override
  final String engineId;
  final S3ConformanceTransport transport;
  final EndpointProfile profile;

  Future<Map<String, Object?>> _send(
      String method, Map<String, Object?> params) async {
    try {
      return await transport.conformanceRequest(
          engineId: engineId, profile: profile, method: method, params: params);
    } on EngineException catch (error) {
      throw S3OpRpcException(
          _code(error.code),
          '${scrubConformanceResult({
                'errorMessage': error.message
              }, [
                profile.secretKey,
                profile.sessionToken,
                profile.accessKey
              ])['errorMessage']}');
    }
  }

  static String _code(ErrorCode code) => switch (code) {
        ErrorCode.unsupportedFeature => 'unsupported_feature',
        ErrorCode.invalidConfig => 'invalid_config',
        ErrorCode.engineUnavailable => 'engine_unavailable',
        ErrorCode.timeout => 'timeout',
        ErrorCode.authFailed => 'auth_failed',
        ErrorCode.tlsError => 'tls_error',
        _ => code.name,
      };

  @override
  Future<S3ConformanceCapability?> capability() async {
    final result = await _send('getCapabilities', const {});
    for (final item in (result['items'] as List?) ?? const []) {
      if (item is Map && item['key'] == 'conformance.s3') {
        return S3ConformanceCapability.fromJson(
            Map<String, Object?>.from(item));
      }
    }
    return null;
  }

  @override
  Future<S3OpObservation> execute(S3OpRequest request) async =>
      S3OpObservation.fromJson(scrubConformanceResult(
          await _send('s3ConformanceOp', request.toParams()), [
        profile.secretKey,
        profile.sessionToken,
        profile.accessKey,
        request.customerKey,
        request.sourceCustomerKey
      ]));
}
