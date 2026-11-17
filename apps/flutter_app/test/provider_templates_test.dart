import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/controllers/app_controller.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/models/provider_templates.dart';

void main() {
  test(
    'catalog orders Amazon and Azure first, then providers alphabetically',
    () {
      expect(providerTemplates, hasLength(22));
      expect(providerTemplates.take(2).map((template) => template.id), [
        'amazon-s3',
        'azure-blob',
      ]);
      final names =
          providerTemplates.skip(2).map((t) => t.displayName).toList();
      expect(
        names,
        [...names]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
      );
      expect(
        providerTemplates.map((template) => template.id).toSet(),
        hasLength(22),
      );
    },
  );

  const expectedEndpoints = {
    'amazon-s3': 'https://s3.us-east-1.amazonaws.com',
    'azure-blob': 'https://mystorageaccount.blob.core.windows.net',
    'alibaba-oss': 'https://s3.oss-cn-hangzhou.aliyuncs.com',
    'backblaze-b2': 'https://s3.us-west-004.backblazeb2.com',
    'ceph-rgw': 'https://rgw.example.com:80',
    'cloudflare-r2': 'https://example.r2.cloudflarestorage.com',
    'digitalocean-spaces': 'https://nyc3.digitaloceanspaces.com',
    'garage': 'http://localhost:3900',
    'google-cloud-storage-native': 'https://storage.googleapis.com',
    'google-cloud-storage': 'https://storage.googleapis.com',
    'hetzner': 'https://fsn1.your-objectstorage.com',
    'ibm-cos': 'https://s3.us-south.cloud-object-storage.appdomain.cloud',
    'idrive-e2': 'https://s3.us-east-1.idrivee2.com',
    'linode': 'https://us-southeast-1.linodeobjects.com',
    'minio': 'https://minio.example.net:9000',
    'oracle-oci':
        'https://example.compat.objectstorage.us-phoenix-1.oci.customer-oci.com',
    'ovhcloud': 'https://s3.gra.io.cloud.ovh.net',
    'scaleway': 'https://s3.fr-par.scw.cloud',
    'seaweedfs': 'http://localhost:8333',
    'storj': 'https://gateway.storjshare.io',
    'tencent-cos': 'https://cos.ap-guangzhou.myqcloud.com',
    'wasabi': 'https://s3.us-east-1.wasabisys.com',
  };

  for (final template in providerTemplates) {
    final values = {
      for (final placeholder in template.placeholders)
        placeholder.name: placeholder.examples.firstOrNull ?? 'example',
    };
    test('${template.id} expands endpoint, signing region and addressing', () {
      final expanded = expandProviderTemplate(template, values);
      expect(expanded.endpointUrl, expectedEndpoints[template.id]);
      expect(expanded.endpointUrl, isNot(matches(RegExp(r'[{}]'))));
      expect(
        expanded.region,
        template.signingRegion?.fixed ??
            values[template.signingRegion?.fromPlaceholder] ??
            '',
      );
      expect(expanded.pathStyle, template.pathStyleDefault);
      expect(
        template.endpointType,
        template.id == 'amazon-s3'
            ? EndpointProfileType.awsS3
            : template.id == 'azure-blob'
                ? EndpointProfileType.azureBlob
                : template.id == 'google-cloud-storage-native'
                    ? EndpointProfileType.googleCloudStorage
                    : EndpointProfileType.s3Compatible,
      );
    });
    for (final placeholder in template.placeholders) {
      test(
        '${template.id} leaves endpoint empty without ${placeholder.name}',
        () {
          final incomplete = {...values}..remove(placeholder.name);
          expect(
            expandProviderTemplate(template, incomplete).endpointUrl,
            isEmpty,
          );
          incomplete[placeholder.name] = '   ';
          expect(
            expandProviderTemplate(template, incomplete).endpointUrl,
            isEmpty,
          );
        },
      );
    }
  }

  test('uncertain signing and addressing values require review', () {
    expect(
      providerTemplates.where((t) => t.needsReview).map((t) => t.id).toSet(),
      {
        'amazon-s3',
        'alibaba-oss',
        'backblaze-b2',
        'ceph-rgw',
        'cloudflare-r2',
        'google-cloud-storage',
        'ibm-cos',
        'idrive-e2',
        'linode',
        'minio',
        'ovhcloud',
        'scaleway',
        'seaweedfs',
        'storj',
        'wasabi',
      },
    );
  });

  test('self-hosted providers expose host and port inputs', () {
    for (final id in ['minio', 'ceph-rgw', 'garage', 'seaweedfs']) {
      final template = providerTemplateById(id)!;
      expect(
        template.placeholders.map((p) => p.name),
        containsAll(['host', 'port']),
      );
    }
    final garage = providerTemplateById('garage')!;
    expect(
      expandProviderTemplate(garage, {
        'host': 'localhost',
        'port': '9001',
      }).endpointUrl,
      'http://localhost:9001',
    );
    expect(
      providerPlaceholderValues(garage, 'http://localhost:9001', 'garage'),
      {'host': 'localhost', 'port': '9001'},
    );
  });

  test('provider template id round trips and copyWith can clear it', () {
    final profile = EndpointProfile.fromJson({
      'id': 'r2',
      'providerTemplateId': 'cloudflare-r2',
      'endpointUrl': 'https://example.r2.cloudflarestorage.com',
      'region': 'auto',
    });
    expect(EndpointProfile.fromJson(profile.toJson()), profile);
    expect(
      profile.copyWith(name: 'Renamed').providerTemplateId,
      'cloudflare-r2',
    );
    expect(
      profile.copyWith(providerTemplateId: null).providerTemplateId,
      isNull,
    );
    expect(profile, isNot(profile.copyWith(providerTemplateId: null)));
  });

  test('unknown, missing and non-string provider ids decode as Custom', () {
    for (final id in ['future-provider', null, 42]) {
      final profile = EndpointProfile.fromJson({'providerTemplateId': id});
      expect(profile.providerTemplateId, isNull);
      expect(profile.endpointType, EndpointProfileType.s3Compatible);
    }
    expect(EndpointProfile.fromJson({}).providerTemplateId, isNull);
  });

  test(
    'AWS defaults stay unchanged and explicit endpoint opt-in ignores template id',
    () {
      final profile = EndpointProfile.fromJson({
        'endpointType': 'awsS3',
        'endpointUrl': 'https://s3.dualstack.eu-west-1.amazonaws.com',
        'region': 'eu-west-1',
      });
      for (final id in [null, 'amazon-s3']) {
        expect(
            normalizeEndpointProfile(profile.copyWith(providerTemplateId: id))
                .endpointUrl,
            'https://s3.eu-west-1.amazonaws.com');
        final explicit = profile.copyWith(
            providerTemplateId: id, useCustomAwsEndpoint: true);
        expect(
          normalizeEndpointProfile(explicit).endpointUrl,
          profile.endpointUrl,
        );
        expect(EndpointProfile.fromJson(explicit.toJson()), explicit);
      }
      expect(
        normalizeEndpointProfile(profile.copyWith(endpointUrl: '')).endpointUrl,
        'https://s3.eu-west-1.amazonaws.com',
      );
    },
  );
}
