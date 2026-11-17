import 'dart:convert';
import 'package:s3_browser_crossplat/models/domain_models.dart';

// Deliberately not a signing key: the editor validates structure, not RSA.
String dummyServiceAccountJson() => const JsonEncoder.withIndent('  ').convert({
      'type': 'service_account',
      'client_email': 'throwaway@example.invalid',
      'project_id': 'throwaway-project',
      'private_key':
          '-----BEGIN PRIVATE KEY-----\ndummy "quoted" body\n-----END PRIVATE KEY-----\n',
    });

EndpointProfile googleProfile() => EndpointProfile(
      id: 'gcs',
      name: 'Cloud fixture',
      endpointUrl: '',
      region: '',
      accessKey: 'throwaway@example.invalid',
      secretKey: dummyServiceAccountJson(),
      pathStyle: false,
      verifyTls: true,
      endpointType: EndpointProfileType.googleCloudStorage,
    );
