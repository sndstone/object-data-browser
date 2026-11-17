import 'package:flutter/material.dart';
import '../controllers/app_controller.dart';
import '../theme/app_motion.dart';

/// Provider facts come from docs/review-2026-11-15/encryption-scope.md, the
/// transport contract and the AWS S3 user guide (SSE-KMS and multipart upload
/// permissions). Deliberately contains no automatically opened links.
class EncryptionSetupGuide extends StatelessWidget {
  const EncryptionSetupGuide({super.key, required this.controller});
  final AppController controller;

  static const entries = <String, List<String>>{
    'SSE-S3': [
      'Nothing to prepare on AWS: new objects are already encrypted with SSE-S3 unless something else is configured. On an S3-compatible service, check that it supports SSE-S3; some require their own key service to be configured first.',
      'Choose SSE-S3 in bucket menu → "Bucket encryption" for a bucket default, or Settings → Encryption → "Encryption by connection" → Edit… for uploads from this connection.',
      'Upload a new object and check the encryption mode in the object inspector.',
    ],
    'SSE-KMS': [
      'Create or choose a KMS key in the same region as the bucket. On AWS the identity used by this connection needs kms:GenerateDataKey to upload and kms:Decrypt to download; multipart uploads of large files need both. Setting a bucket default also needs s3:PutEncryptionConfiguration. S3-compatible services need their own key service configured first, and some do not support SSE-KMS.',
      'Choose SSE-KMS in bucket menu → "Bucket encryption" to make it the default for uploads that do not ask for another mode (enforcing it for every client needs a bucket policy), or in Settings → Encryption → "Encryption by connection" → Edit… to encrypt only uploads from this connection. Enter the KMS key ID or ARN, or leave it empty for the provider-managed key. Prefer a full ARN. Turn on "Use S3 Bucket Key" to reduce KMS request costs.',
      'Upload a new object and check the encryption mode, KMS key and bucket key in the object inspector.',
    ],
    'DSSE-KMS': [
      'Use AWS with KMS configured. S3 Bucket Keys are not supported for DSSE-KMS.',
      'Choose DSSE-KMS in bucket menu → "Bucket encryption", or Settings → Encryption → "Encryption by connection" → Edit…, and choose the KMS key.',
      'Upload a new object and check the encryption mode and KMS key in the object inspector.',
    ],
    'SSE-C (customer keys)': [
      'Use HTTPS and a service that allows SSE-C. Since April 2026 AWS blocks SSE-C on new general purpose buckets by default; the bucket owner must allow it first.',
      'In Settings → Encryption, create or unlock the key file and generate or import a customer key. Back up the key file: losing the key loses access to the objects.',
      'In Settings → Encryption → "Encryption by connection" → Edit…, choose Customer key (SSE-C) and select the key. Upload an object and check the mode and key fingerprint in the object inspector.',
    ],
    'Azure encryption scopes and customer-provided keys': [
      'For an encryption scope, configure an enabled scope on the storage account first. Customer-provided keys require HTTPS.',
      'In Settings → Encryption → "Encryption by connection" → Edit…, choose Encryption scope and enter its name, or Customer-provided key and choose a customer key from the key file in Settings → Encryption.',
      'Upload an object and check the encryption mode, scope or customer-key fingerprint in the object inspector. Keep a backup of customer keys.',
    ],
    'Vault encryption by this app': [
      'In Settings → Encryption, create the key file and generate a vault key.',
      'Assign the bucket and optional prefix in bucket menu → "Bucket encryption", or Settings → Encryption → "Encryption by connection" → Edit…. Only new uploads are encrypted; existing objects are not converted.',
      'Choose Default to encrypt contents with one vault key and keep names visible. Turn on "Encrypt file and folder names" to hide each name while folders and filtering keep working. Someone listing the bucket can still see the folder structure, name lengths and which names are equal.',
      'Choose Strict to give every upload a random name key and hide names and folders in one flat list. Strict never overwrites: uploading the same name again keeps both objects. A bucket listing reveals only the path length rounded to 16 bytes. Sizes, counts and dates stay visible in every mode; the destination prefix also stays visible.',
      'Unlock the key file to upload or read encrypted names. Some S3-compatible servers limit a name segment to 255 characters: encrypted names then fit about 170 bytes per name, or about 143 bytes for a whole path under Strict. These are UTF-8 byte limits.',
      'Names can also be recovered outside this app from the vault key. The Name encryption section of contracts/transport_contract.md documents the format and recovery steps.',
      'Back up or sync the key file in Settings → Encryption. Nobody can recover the objects without the key. Upload an object and check the encryption mode in the object inspector. Objects use the standard age format and remain readable with the stock age tool and the vault key.',
    ],
  };

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 18),
          Text('How to set up encryption',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 18),
          for (final entry in entries.entries)
            ExpansionTile(
              title: Text(entry.key),
              tilePadding: EdgeInsets.zero,
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              expansionAnimationStyle: AnimationStyle(
                  curve: Curves.easeOutCubic,
                  duration: AppMotion.duration(context,
                      enabled: controller.settings.enableAnimations,
                      milliseconds: 240)),
              children: [
                for (var i = 0; i < entry.value.length; i++)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SelectableText('${i + 1}. ${entry.value[i]}',
                          style: Theme.of(context).textTheme.bodyMedium)),
              ],
            ),
        ],
      );
}
