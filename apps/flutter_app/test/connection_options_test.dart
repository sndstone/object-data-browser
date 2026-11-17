import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/domain_models.dart';
import 'package:s3_browser_crossplat/services/app_state_repository.dart';
import 'package:s3_browser_crossplat/services/profile_secret_store.dart';
import 'package:s3_browser_crossplat/widgets/connection_options_editor.dart';

class _MemorySecrets extends ProfileSecretStore {
  final values = <String, String>{};
  @override
  bool get supportsPrimaryBulkRead => true;
  @override
  Future<String?> readSecret(String key) async => values[key];
  @override
  Future<Map<String, String>> readAllSecrets() async => Map.of(values);
  @override
  Future<String?> readFallbackMacSecret(String key) async => null;
  @override
  Future<Map<String, String>> readAllFallbackMacSecrets() async => {};
  @override
  Future<void> saveSecret(String key, String value) async =>
      values[key] = value;
  @override
  Future<void> deleteSecret(String key) async => values.remove(key);
}

void main() {
  test(
    'provider template metadata survives state and export/import without secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'provider-template-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = _MemorySecrets();
      final repository = LocalAppStateRepository(
        secretStore: store,
        applicationSupportDirectoryProvider: () async => directory,
      );
      final profile = EndpointProfile.fromJson({
        'id': 'r2-profile',
        'name': 'R2',
        'providerTemplateId': 'cloudflare-r2',
        'endpointUrl': 'https://example.r2.cloudflarestorage.com',
        'region': 'auto',
        'accessKey': 'PROVIDER-ACCESS-SENTINEL',
        'secretKey': 'PROVIDER-SECRET-SENTINEL',
      });
      await repository.saveState(
        settings: AppSettings.fromJson({}),
        profiles: [profile],
        selectedProfileId: profile.id,
      );
      expect((await repository.loadState())!.profiles.single, profile);
      final exported = await repository.exportProfiles(
        profiles: [profile],
        path: '${directory.path}/export.json',
      );
      final imported = (await repository.importProfiles(exported.path)).single;
      expect(imported.providerTemplateId, 'cloudflare-r2');
      expect(imported.accessKey, isEmpty);
      expect(imported.secretKey, isEmpty);
      for (final file in directory.listSync().whereType<File>()) {
        final text = await file.readAsString();
        expect(text, contains('cloudflare-r2'));
        expect(text, isNot(contains('PROVIDER-ACCESS-SENTINEL')));
        expect(text, isNot(contains('PROVIDER-SECRET-SENTINEL')));
      }
      final json = jsonDecode(await exported.readAsString()) as Map;
      (json['profiles'] as List).single['providerTemplateId'] =
          'future-provider';
      await exported.writeAsString(jsonEncode(json));
      expect(
        (await repository.importProfiles(
          exported.path,
        ))
            .single
            .providerTemplateId,
        isNull,
      );
    },
  );

  test(
      'AWS provider options survive metadata persistence without resolved keys',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('connection-options-');
    addTearDown(() => directory.delete(recursive: true));
    final store = _MemorySecrets();
    final repository = LocalAppStateRepository(
        secretStore: store,
        applicationSupportDirectoryProvider: () async => directory);
    final profile = EndpointProfile.fromJson({
      'id': 'role-profile',
      'name': 'Role',
      'providerTemplateId': 'amazon-s3',
      'useCustomAwsEndpoint': true,
      'endpointType': 'awsS3',
      'endpointUrl': 'https://s3.eu-west-1.amazonaws.com',
      'region': 'eu-west-1',
      'authMode': 'assumeRole',
      'awsProfileName': 'corporate-sso',
      'roleArn': 'arn:aws:iam::123456789012:role/Reader',
      'externalId': 'example-external',
      'roleSessionName': 'browser-tests',
      'knownBucket': 'restricted-bucket',
      'requesterPays': true,
      'expectedBucketOwner': '123456789012',
      'caBundlePath': '/tmp/example.pem',
      'storageClasses': ['STANDARD_IA', 'GLACIER'],
    });
    await repository.saveState(
        settings: AppSettings.fromJson({}),
        profiles: [profile],
        selectedProfileId: profile.id);
    final loaded = await repository.loadState();
    expect(loaded!.profiles.single.connection, profile.connection);
    expect(loaded.profiles.single.useCustomAwsEndpoint, isTrue);
    final exported = await repository.exportProfiles(
        profiles: [profile], path: '${directory.path}/export.json');
    expect(
        (await repository.importProfiles(exported.path))
            .single
            .useCustomAwsEndpoint,
        isTrue);
    expect(loaded.profiles.single.accessKey, isEmpty);
    expect(loaded.profiles.single.secretKey, isEmpty);
    expect(loaded.profiles.single.connection.storageClasses,
        ['STANDARD_IA', 'GLACIER']);
  });

  test(
      'SAS endpoint import moves token to secure storage and exports metadata only',
      () async {
    final directory = await Directory.systemTemp.createTemp('sas-options-');
    addTearDown(() => directory.delete(recursive: true));
    final store = _MemorySecrets();
    final repository = LocalAppStateRepository(
        secretStore: store,
        applicationSupportDirectoryProvider: () async => directory);
    final profile = EndpointProfile.fromJson({
      'id': 'sas-profile',
      'name': 'Delegated container',
      'endpointType': 'azureBlob',
      'endpointUrl':
          'https://example.blob.core.windows.net?sp=rl&sig=SAS-SENTINEL-SECRET',
      'knownBucket': 'allowed-container',
    });
    expect(profile.endpointUrl, 'https://example.blob.core.windows.net');
    expect(profile.connection.authMode, 'azureSas');
    expect(profile.sessionToken, contains('SAS-SENTINEL-SECRET'));
    await repository.saveState(
        settings: AppSettings.fromJson({}),
        profiles: [profile],
        selectedProfileId: profile.id);
    final exported = await repository.exportProfiles(
        profiles: [profile], path: '${directory.path}/export.json');
    for (final entity in directory.listSync().whereType<File>()) {
      expect(
          await entity.readAsString(), isNot(contains('SAS-SENTINEL-SECRET')),
          reason: entity.path);
    }
    expect(store.values.values.join(), contains('SAS-SENTINEL-SECRET'));
    expect((await repository.loadState())!.profiles.single.sessionToken,
        profile.sessionToken);
    final exportedProfile =
        ((jsonDecode(await exported.readAsString()) as Map)['profiles'] as List)
            .single as Map;
    expect(exportedProfile['authMode'], 'azureSas');
    expect(exportedProfile['knownBucket'], 'allowed-container');
    expect(exportedProfile['sessionToken'], anyOf(isNull, isEmpty));
  });

  testWidgets(
      'AWS role editor updates profile settings without static credential fields',
      (tester) async {
    var options = const ConnectionOptions(authMode: 'assumeRole');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: StatefulBuilder(
                    builder: (context, setState) => ConnectionOptionsEditor(
                          value: options,
                          endpointType: EndpointProfileType.awsS3,
                          onChanged: (updated) =>
                              setState(() => options = updated),
                        ))))));
    await tester.enterText(
        find.byKey(const ValueKey('awsProfileName')), 'corporate');
    await tester.enterText(find.byKey(const ValueKey('roleArn')),
        'arn:aws:iam::123456789012:role/Reader');
    await tester.pump();
    expect(options.awsProfileName, 'corporate');
    expect(options.roleArn, 'arn:aws:iam::123456789012:role/Reader');
    expect(find.text('Secret key'), findsNothing);
    await tester.tap(find.text('Bucket access and endpoint capabilities'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('knownBucket')), 'private-bucket');
    await tester.enterText(
        find.byKey(const ValueKey('storageClasses')), 'STANDARD_IA, GLACIER');
    await tester.pump();
    expect(options.knownBucket, 'private-bucket');
    expect(options.storageClasses, ['STANDARD_IA', 'GLACIER']);
  });

  testWidgets('Azure identity editor excludes AWS-only controls',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ConnectionOptionsEditor(
      value: const ConnectionOptions(authMode: 'azureDefault'),
      endpointType: EndpointProfileType.azureBlob,
      onChanged: (_) {},
    )))));
    expect(find.text('Microsoft Entra ID'), findsOneWidget);
    await tester.tap(find.text('Bucket access and endpoint capabilities'));
    await tester.pumpAndSettle();
    expect(find.text('Known container'), findsOneWidget);
    expect(find.text('Requester Pays'), findsNothing);
    expect(find.byKey(const ValueKey('roleArn')), findsNothing);
  });
}
