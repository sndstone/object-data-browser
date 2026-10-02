import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/models/azure_admin_presets.dart';

void main() {
  test(
      'lifecycle preset preserves account rules, exact scope and repeated apply',
      () {
    final custom = {
      'name': 'custom',
      'definition': {
        'actions': {
          'snapshot': {
            'delete': {'daysAfterCreationGreaterThan': 70}
          }
        }
      }
    };
    final current = <String, Object?>{
      'rules': [custom],
      'futureField': 'preserve'
    };
    final policy = AzureLifecyclePresets.build(
        currentPolicy: current,
        preset: 'coldArchive',
        bucket: 'container',
        prefix: ' exact /');
    expect(current['rules'], [custom]);
    expect(policy['futureField'], 'preserve');
    final rules = policy['rules'] as List;
    expect(rules.first, custom);
    expect((rules.last as Map)['definition']['filters']['prefixMatch'],
        ['container/ exact /']);
    expect(
        AzureLifecyclePresets.build(
            currentPolicy: policy,
            preset: 'coldArchive',
            bucket: 'container',
            prefix: ' exact /'),
        policy);
    expect(
        AzureLifecyclePresets.build(
            currentPolicy: policy,
            preset: 'disabled',
            bucket: 'container',
            prefix: ' exact /')['rules'],
        [custom]);
  });

  test('tier ages validate before replacing a policy', () {
    expect(
        () => AzureLifecyclePresets.build(
            currentPolicy: null,
            preset: 'coldArchive',
            bucket: 'container',
            coolDays: 60,
            coldDays: 30),
        throwsFormatException);
    expect(
        () => AzureLifecyclePresets.build(
            currentPolicy: null,
            preset: 'archive',
            bucket: 'container',
            archiveDays: 20),
        throwsFormatException);
    expect(
        () => AzureLifecyclePresets.build(
            currentPolicy: null,
            preset: 'cool',
            bucket: 'container',
            prefix: '/root'),
        throwsFormatException);
  });

  test('typed ACL roundtrips exact identities and defaults', () {
    const acl =
        'user::rwx,user:abc-123:r-x,group::r--,mask::r-x,other::---,default:user::rwx,default:group::r-x,default:other::---';
    expect(AdlsAclEntry.encodeAll(AdlsAclEntry.parse(acl)), acl);
  });

  test('ACL rejects missing mask, repeated principals and injected fields', () {
    expect(
        () => AdlsAclEntry.encodeAll(
            AdlsAclEntry.parse('user::rwx,user:abc:r--,group::r--,other::---')),
        throwsFormatException);
    expect(
        () => AdlsAclEntry.encodeAll(
            AdlsAclEntry.parse('user::rwx,group::r--,other::---,other::rwx')),
        throwsFormatException);
    expect(
        () => const AdlsAclEntry(type: 'user', identity: 'bad,other::rwx')
            .encode(),
        throwsFormatException);
  });
}
