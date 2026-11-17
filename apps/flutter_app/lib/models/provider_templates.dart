import 'domain_models.dart';

class ProviderPlaceholder {
  const ProviderPlaceholder({
    required this.name,
    required this.label,
    required this.hint,
    required this.examples,
    this.defaultValue = '',
  });

  final String name, label, hint;
  final List<String> examples;
  final String defaultValue;
}

class SigningRegionRule {
  const SigningRegionRule.fixed(this.fixed) : fromPlaceholder = null;
  const SigningRegionRule.fromPlaceholder(this.fromPlaceholder) : fixed = null;

  final String? fixed, fromPlaceholder;
}

class ProviderTemplate {
  const ProviderTemplate({
    required this.id,
    required this.displayName,
    required this.endpointType,
    required this.endpointTemplate,
    required this.placeholders,
    required this.signingRegion,
    required this.pathStyleDefault,
    required this.credentialsHint,
    required this.gotchas,
    required this.needsReview,
    this.portOverrideDefault,
  });

  final String id, displayName, endpointTemplate, credentialsHint;
  final EndpointProfileType endpointType;
  final List<ProviderPlaceholder> placeholders;
  final SigningRegionRule? signingRegion;
  final bool pathStyleDefault, needsReview;
  final List<String> gotchas;

  // Garage and SeaweedFS publish a literal example port in the catalog.
  // Retain that exact template while allowing a deployment-specific port.
  final String? portOverrideDefault;
}

ProviderTemplate? providerTemplateById(Object? id) {
  for (final template in providerTemplates) {
    if (template.id == id) return template;
  }
  return null;
}

class ExpandedProviderTemplate {
  const ExpandedProviderTemplate({
    required this.endpointUrl,
    required this.region,
    required this.pathStyle,
  });

  final String endpointUrl, region;
  final bool pathStyle;
}

/// Incomplete inputs produce an empty endpoint, never a URL containing braces.
ExpandedProviderTemplate expandProviderTemplate(
  ProviderTemplate template,
  Map<String, String> values,
) {
  final complete = template.placeholders.every((placeholder) {
    final value = values[placeholder.name]?.trim() ?? '';
    return value.isNotEmpty && !value.contains(RegExp(r'[{}]'));
  });
  var endpoint = complete
      ? template.endpointTemplate.replaceAllMapped(
          RegExp(r'\{([^{}]+)\}'),
          (match) => values[match[1]]!.trim(),
        )
      : '';
  if (endpoint.isNotEmpty && template.portOverrideDefault != null) {
    endpoint = endpoint.replaceFirst(
      ':${template.portOverrideDefault}',
      ':${values['port']!.trim()}',
    );
  }
  final rule = template.signingRegion;
  return ExpandedProviderTemplate(
    endpointUrl: endpoint,
    region: rule?.fixed ?? values[rule?.fromPlaceholder]?.trim() ?? '',
    pathStyle: template.pathStyleDefault,
  );
}

/// Recover editor inputs without applying defaults to an existing profile.
Map<String, String> providerPlaceholderValues(
  ProviderTemplate template,
  String endpoint,
  String region,
) {
  final names = <String>[];
  final inputTemplate = template.portOverrideDefault == null
      ? template.endpointTemplate
      : template.endpointTemplate.replaceFirst(
          ':${template.portOverrideDefault}',
          ':{port}',
        );
  final pattern = inputTemplate.splitMapJoin(
    RegExp(r'\{([^{}]+)\}'),
    onMatch: (match) {
      names.add(match[1]!);
      return '(.+?)';
    },
    onNonMatch: RegExp.escape,
  );
  final match = RegExp('^$pattern\$').firstMatch(endpoint);
  return {
    for (var i = 0; i < names.length; i++)
      if (match != null) names[i]: match[i + 1]!,
    if (template.signingRegion?.fromPlaceholder case final String name)
      name: region,
    if (template.portOverrideDefault != null)
      'port': Uri.tryParse(endpoint)?.hasPort == true
          ? '${Uri.parse(endpoint).port}'
          : template.portOverrideDefault!,
  };
}

// Transcribed from docs/review-2026-11-15/provider-catalog.json. Feature claims
// intentionally stay out of this convenience catalog and engine dispatch.
const providerTemplates = <ProviderTemplate>[
  ProviderTemplate(
    id: 'amazon-s3',
    displayName: 'Amazon S3',
    endpointType: EndpointProfileType.awsS3,
    endpointTemplate: 'https://s3.{region}.amazonaws.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'AWS Region code of the bucket',
        examples: [
          'us-east-1',
          'us-west-2',
          'eu-west-1',
          'eu-central-1',
          'ap-southeast-1',
          'ap-northeast-1',
        ],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: false,
    credentialsHint: 'IAM access key ID and secret access key.',
    gotchas: [
      'Creating a bucket outside us-east-1 requires LocationConstraint set to the same Region.',
      'Buckets and new objects are encrypted with SSE-S3 by default.',
      'Multipart: parts 5 MB to 5 GB, 10,000 parts; the quota table lists max object size as 48.828125 TB.',
      'Object tags are limited to 10 per object.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'azure-blob',
    displayName: 'Azure Blob Storage',
    endpointType: EndpointProfileType.azureBlob,
    endpointTemplate: 'https://{account}.blob.core.windows.net',
    placeholders: [
      ProviderPlaceholder(
        name: 'account',
        label: 'Storage account name',
        hint:
            'Storage account name: 3-24 characters, lowercase letters and numbers only',
        examples: ['mystorageaccount', 'devstoreaccount1'],
      ),
    ],
    signingRegion: null,
    pathStyleDefault: false,
    credentialsHint:
        'Storage account name plus an access key (portal: Security + networking > Access keys), or a SAS token.',
    gotchas: [
      'Sovereign clouds change only the suffix; connection strings carry it as EndpointSuffix.',
      'Azurite\'s default account is devstoreaccount1 with a fixed well-known key; the UseDevelopmentStorage=true shortcut uses HTTP on port 10000.',
      'Shared Key authorization can be disabled on an account; Microsoft recommends Entra ID.',
      'Azurite does not support Data Lake Storage Gen2 or Azure Files.',
    ],
    needsReview: false,
  ),
  ProviderTemplate(
    id: 'alibaba-oss',
    displayName: 'Alibaba Cloud OSS',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://s3.oss-{region}.aliyuncs.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'OSS region ID without the \'oss-\' prefix',
        examples: [
          'cn-hangzhou',
          'cn-shanghai',
          'cn-beijing',
          'ap-southeast-1',
          'us-west-1',
          'eu-central-1',
        ],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: false,
    credentialsHint:
        'AccessKey ID and AccessKey Secret created in the RAM console.',
    gotchas: [
      'OSS does not support aws-chunked transfer encoding; send unsigned or non-chunked payloads.',
      'Since March 20, 2025, new OSS users need a custom domain (CNAME) for data operations on buckets in Chinese mainland regions.',
      'A wrong-region endpoint returns NoSuchBucket; there are no cross-region redirects.',
      'Bucket names with underscores cannot be reached virtual-hosted style.',
      'Requests are rejected when the clock differs from the server by more than 15 minutes.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'backblaze-b2',
    displayName: 'Backblaze B2 (S3-compatible API)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://s3.{region}.backblazeb2.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint:
            'Region of your B2 account, shown with the bucket endpoint in the web console',
        examples: ['us-west-004', 'us-east-005'],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: true,
    credentialsHint:
        'An app key created in the Backblaze web UI: app key ID = access key ID, app key = secret access key.',
    gotchas: [
      'The master app key does not work with the S3-compatible API; create a separate app key.',
      'An app key restricted to one bucket needs the listAllBucketNames capability or ListBuckets fails.',
      'An account belongs to a single region; buckets cannot be created outside it.',
      'HTTPS only and SigV4 only (no SigV2).',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'ceph-rgw',
    displayName: 'Ceph RADOS Gateway (self-hosted)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: '{scheme}://{host}:{port}',
    placeholders: [
      ProviderPlaceholder(
        name: 'scheme',
        label: 'Scheme',
        hint: 'http or https',
        examples: ['https', 'http'],
      ),
      ProviderPlaceholder(
        name: 'host',
        label: 'Host',
        hint: 'Hostname of the RGW endpoint or load balancer',
        examples: ['rgw.example.com'],
      ),
      ProviderPlaceholder(
        name: 'port',
        label: 'Port',
        hint: 'RGW frontend port set by the administrator',
        examples: ['80', '8000'],
      ),
    ],
    signingRegion: SigningRegionRule.fixed('us-east-1'),
    pathStyleDefault: true,
    credentialsHint:
        'Access key and secret key of an RGW user, issued by the cluster administrator.',
    gotchas: [
      'Server-side encryption requests must use HTTPS.',
      'SSE-KMS and SSE-S3 depend on a key management service configured by the administrator.',
      'The frontends page lists port default 80; real deployments vary, so do not pre-fill a port.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'cloudflare-r2',
    displayName: 'Cloudflare R2',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://{accountId}.r2.cloudflarestorage.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'accountId',
        label: 'Account ID',
        hint:
            'Cloudflare account ID, shown under Account Details on the R2 overview page',
        examples: [],
      ),
    ],
    signingRegion: SigningRegionRule.fixed('auto'),
    pathStyleDefault: true,
    credentialsHint:
        'Access Key ID and Secret Access Key from an R2 API token: R2 > Overview > Account Details > Manage API Tokens.',
    gotchas: [
      'Region is \'auto\'; an empty value and \'us-east-1\' alias to it.',
      'Buckets created in a jurisdiction (EU, FedRAMP, US) are reachable only through the matching jurisdictional endpoint, so one profile per jurisdiction.',
      'The Secret Access Key is shown only once at token creation.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'digitalocean-spaces',
    displayName: 'DigitalOcean Spaces',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://{region}.digitaloceanspaces.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'Datacenter slug of the Space',
        examples: ['nyc3', 'sfo3', 'ams3', 'sgp1', 'fra1', 'syd1'],
      ),
    ],
    signingRegion: SigningRegionRule.fixed('us-east-1'),
    pathStyleDefault: false,
    credentialsHint:
        'Spaces access key and secret key: Control Panel > Spaces Object Storage > Access Keys > Create Access Key.',
    gotchas: [
      'The SDK guide says to configure region \'us-east-1\'; the datacenter goes only in the endpoint. The API reference\'s SigV4 examples use the slug (nyc3) in the credential scope, so test which the app needs.',
      'Limited-access keys are incompatible with bucket policies set through PutBucketPolicy.',
      'Versioning and bucket policy are API-only (not in the control panel); bucket-level encryption settings are unsupported.',
      'UploadPartCopy does not work across regions or clusters.',
      'Files fetched through presigned URLs are not cached by the Spaces CDN.',
    ],
    needsReview: false,
  ),
  ProviderTemplate(
    id: 'garage',
    displayName: 'Garage (self-hosted)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'http://{host}:3900',
    placeholders: [
      ProviderPlaceholder(
        name: 'host',
        label: 'Host',
        hint: 'Hostname or IP of the Garage node or reverse proxy',
        examples: ['localhost', 'garage.example.com'],
      ),
      ProviderPlaceholder(
        name: 'port',
        label: 'Port',
        hint: 'Confirm the deployment port (catalog example: 3900)',
        examples: ['3900'],
        defaultValue: '3900',
      ),
    ],
    signingRegion: SigningRegionRule.fixed('garage'),
    pathStyleDefault: true,
    credentialsHint:
        '\'garage key create <name>\' prints a Key ID (GK...) and Secret key; grant access with \'garage bucket allow\'.',
    gotchas: [
      'The region must match the server\'s s3_region (\'garage\' in the reference config); a mismatch fails with AuthorizationHeaderMalformed.',
      'The S3 API port has no TLS; HTTPS needs a reverse proxy.',
      'SigV2 is not implemented.',
      'GetBucketVersioning is a stub that always reports versioning not enabled.',
    ],
    needsReview: false,
    portOverrideDefault: '3900',
  ),
  ProviderTemplate(
    id: 'google-cloud-storage-native',
    displayName: 'Google Cloud Storage (native, service account)',
    endpointType: EndpointProfileType.googleCloudStorage,
    endpointTemplate: 'https://storage.googleapis.com',
    placeholders: [],
    signingRegion: null,
    pathStyleDefault: false,
    credentialsHint:
        'Choose or paste a service-account key JSON file. Credentials are saved securely and excluded from exports.',
    gotchas: [
      'Available on desktop with a compatible Python or Go engine.',
      'Bucket administration is limited to versioning in this version.',
    ],
    needsReview: false,
  ),
  ProviderTemplate(
    id: 'google-cloud-storage',
    displayName: 'Google Cloud Storage (S3-compatible, HMAC keys)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://storage.googleapis.com',
    placeholders: [],
    signingRegion: SigningRegionRule.fixed('auto'),
    pathStyleDefault: true,
    credentialsHint:
        'HMAC key (access ID and secret): Cloud Storage > Settings > Interoperability; service-account HMAC keys are recommended for production.',
    gotchas: [
      'HMAC keys work only with the XML API, not the JSON API.',
      'For SigV4 with x-amz headers the service is \'s3\' and request type \'aws4_request\'; any LOCATION value is accepted.',
      'UploadPartCopy is not supported by the XML API.',
      'A new service-account HMAC key can take up to 60 seconds to become usable.',
      'An organisation policy can block HMAC keys, producing 403 Forbidden.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'hetzner',
    displayName: 'Hetzner Object Storage',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://{location}.your-objectstorage.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'location',
        label: 'Location',
        hint: 'Hetzner location of the bucket',
        examples: ['fsn1', 'nbg1', 'hel1'],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('location'),
    pathStyleDefault: false,
    credentialsHint:
        'S3 credentials (access key and secret key) generated in the Hetzner Console; valid for every bucket in the project.',
    gotchas: [
      'CopyObject works only within the same bucket.',
      'The AWS CLI guide says to use virtual addressing before creating presigned URLs.',
      'The region value is loosely enforced: AWS CLI may leave it empty, rclone uses the location.',
      'Limits: 5 GB per PUT or part, 10,000 parts, 5 TB per object, 100 TB per bucket.',
      'The secret key cannot be viewed again after creation.',
    ],
    needsReview: false,
  ),
  ProviderTemplate(
    id: 'ibm-cos',
    displayName: 'IBM Cloud Object Storage',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate:
        'https://s3.{region}.cloud-object-storage.appdomain.cloud',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'Region, cross-region geo or single-site code of the bucket',
        examples: ['us-south', 'us-east', 'eu-gb', 'eu-de', 'au-syd', 'jp-tok'],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: true,
    credentialsHint:
        'HMAC credentials: create a Service Credential with \'Include HMAC Credential\' on; use cos_hmac_keys.access_key_id and secret_access_key.',
    gotchas: [
      'Docs disagree on the signing region: the HMAC page says it accepts any string (examples use \'us-standard\'), while the AWS CLI page says to enter a provisioning code (LocationConstraint).',
      'Standard service credentials have no HMAC keys unless the HMAC option was enabled at creation.',
      'ListObjects returns at most 1,000 objects per call; instances are limited to 1,000 buckets.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'idrive-e2',
    displayName: 'IDrive e2',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://s3.{region}.idrivee2.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'Region code of an enabled e2 region',
        examples: [
          'us-east-1',
          'us-west-1',
          'us-west-2',
          'us-central-1',
          'us-midwest-1',
          'ca-east-1',
        ],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: true,
    credentialsHint:
        'Access key and secret key created in the e2 dashboard for a chosen enabled region.',
    gotchas: [
      'Docs are inconsistent: the endpoint table uses s3.{region}.idrivee2.com, while the developer guide says endpoints are unique per user. Let users paste the dashboard value.',
      'Access keys are created per region.',
      'Multipart parts must be at least 5 MB except the last; part numbers run 1 to 10,000.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'linode',
    displayName: 'Linode / Akamai Object Storage',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://{endpoint}.linodeobjects.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'endpoint',
        label: 'Endpoint prefix',
        hint:
            'S3 endpoint hostname prefix shown for the region in Cloud Manager',
        examples: [
          'us-southeast-1',
          'us-ord-1',
          'us-ord-10',
          'us-lax-4',
          'au-mel-1',
          'gb-lon-1',
        ],
      ),
    ],
    signingRegion: SigningRegionRule.fixed('us-east-1'),
    pathStyleDefault: false,
    credentialsHint:
        'Access key and secret key: Cloud Manager > Object Storage > Access Keys > Create Access Key.',
    gotchas: [
      'One region can have several endpoints of different types (us-ord-1 is E1, us-ord-10 is E3); features differ by type.',
      'CORS policies, object ACLs and static websites exist only on legacy E0/E1 endpoints.',
      'Access keys are created for selected regions; a limited key\'s permissions cannot be changed later.',
      'Limits: 5 GB per request, parts 5 MiB to 5 GiB, 10,000 parts, 5 TiB per object.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'minio',
    displayName: 'MinIO (self-hosted)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: '{scheme}://{host}:{port}',
    placeholders: [
      ProviderPlaceholder(
        name: 'scheme',
        label: 'Scheme',
        hint: 'http or https, depending on whether TLS is configured',
        examples: ['https', 'http'],
      ),
      ProviderPlaceholder(
        name: 'host',
        label: 'Host',
        hint: 'Hostname or IP of the MinIO server or load balancer',
        examples: ['minio.example.net', 'localhost'],
      ),
      ProviderPlaceholder(
        name: 'port',
        label: 'Port',
        hint: 'S3 API port (9000 appears in MinIO examples)',
        examples: ['9000'],
      ),
    ],
    signingRegion: SigningRegionRule.fixed('us-east-1'),
    pathStyleDefault: true,
    credentialsHint:
        'Access key and secret key of a MinIO user or service account; creation steps not confirmed.',
    gotchas: [
      'Bucket and object ACL calls are unsupported; MinIO says to use policies instead.',
      'Virtual-hosted requests fail unless MINIO_DOMAIN is set on the server.',
      'The docs now centre on the commercial AIStor product; community-edition defaults may differ.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'oracle-oci',
    displayName: 'Oracle Cloud (OCI) Object Storage',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate:
        'https://{namespace}.compat.objectstorage.{region}.oci.customer-oci.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'namespace',
        label: 'Namespace',
        hint: 'Object Storage namespace of the tenancy',
        examples: [],
      ),
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'OCI region identifier',
        examples: [
          'us-phoenix-1',
          'us-ashburn-1',
          'eu-frankfurt-1',
          'uk-london-1',
        ],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: true,
    credentialsHint:
        'Customer Secret Key (Access Key and Secret Key): Profile menu > User settings > Customer secret keys.',
    gotchas: [
      'SigV2 is not supported; use SigV4.',
      'If the client cannot set the real OCI region, \'us-east-1\' or blank works only against the tenancy\'s home region.',
      'The Secret Key cannot be retrieved after generation.',
      'SSE-KMS takes the OCID of a Vault key in x-amz-server-side-encryption-aws-kms-key-id.',
    ],
    needsReview: false,
  ),
  ProviderTemplate(
    id: 'ovhcloud',
    displayName: 'OVHcloud Object Storage (S3)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://s3.{region}.io.cloud.ovh.net',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'OVHcloud region code, lowercase',
        examples: ['gra', 'sbg', 'rbx', 'de', 'uk', 'eu-west-par'],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: false,
    credentialsHint:
        'S3 access key and secret key of an Object Storage user; Control Panel location not confirmed.',
    gotchas: [
      'Enter the region in lowercase.',
      'Prefer the \'io\' endpoint; \'perf\' is kept only for tools that cannot use the Express One Zone class.',
      'Cold Archive exists only in eu-west-par.',
      'The FAQ says access rights cannot yet be configured per bucket, only per user profile and per object.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'scaleway',
    displayName: 'Scaleway Object Storage',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://s3.{region}.scw.cloud',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'Scaleway region of the bucket',
        examples: ['fr-par', 'nl-ams', 'pl-waw', 'it-mil'],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: false,
    credentialsHint:
        'Scaleway API key (access key and secret key); console location not confirmed.',
    gotchas: [
      'Legacy Get/PutBucketLifecycle are deprecated; use the LifecycleConfiguration calls.',
      'Bucket notifications are still in development.',
      'Losing an SSE-C key means losing the data; HeadObject without the key returns 400.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'seaweedfs',
    displayName: 'SeaweedFS S3 gateway (self-hosted)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'http://{host}:8333',
    placeholders: [
      ProviderPlaceholder(
        name: 'host',
        label: 'Host',
        hint: 'Hostname or IP of the \'weed s3\' gateway',
        examples: ['localhost'],
      ),
      ProviderPlaceholder(
        name: 'port',
        label: 'Port',
        hint: 'Confirm the deployment port (catalog example: 8333)',
        examples: ['8333'],
        defaultValue: '8333',
      ),
    ],
    signingRegion: SigningRegionRule.fixed('us-east-1'),
    pathStyleDefault: true,
    credentialsHint:
        'accessKey/secretKey identities in the JSON file passed with -s3.config, or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY on the server when nothing else is configured.',
    gotchas: [
      'Port 8333 appears in the wiki\'s examples; confirm it for the deployment.',
      'GetBucketLocation returns a default location; no region is documented.',
      'Bucket replication, notification, logging, website and accelerate configuration are unsupported.',
    ],
    needsReview: true,
    portOverrideDefault: '8333',
  ),
  ProviderTemplate(
    id: 'storj',
    displayName: 'Storj (hosted S3 gateway)',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://gateway.storjshare.io',
    placeholders: [],
    signingRegion: SigningRegionRule.fixed('us-east-1'),
    pathStyleDefault: true,
    credentialsHint:
        'S3 credentials (access key, secret key, endpoint) generated from a new access grant in the Storj web console, or with \'uplink share --register\'.',
    gotchas: [
      'Official docs give no region value; forum staff say the gateway ignores it.',
      'gateway.storjshare.io routes to the nearest gateway instance automatically.',
      'Multipart: 5 MiB minimum part size, 10,000 parts; UploadPartCopy is enabled only on request.',
      'ListMultipartUploads does not support UploadIdMarker.',
    ],
    needsReview: true,
  ),
  ProviderTemplate(
    id: 'tencent-cos',
    displayName: 'Tencent Cloud COS',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://cos.{region}.myqcloud.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'COS region of the bucket',
        examples: ['ap-guangzhou', 'ap-shanghai', 'ap-beijing', 'ap-singapore'],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: false,
    credentialsHint:
        'SecretId (access key) and SecretKey from the CAM console.',
    gotchas: [
      'Bucket names must be given in full as BucketName-APPID, e.g. examplebucket-1250000000.',
      'Only buckets in the endpoint\'s region are listed or usable.',
      'Tencent states that COS does not guarantee full S3 compatibility and publishes no feature matrix on the pages read.',
    ],
    needsReview: false,
  ),
  ProviderTemplate(
    id: 'wasabi',
    displayName: 'Wasabi',
    endpointType: EndpointProfileType.s3Compatible,
    endpointTemplate: 'https://s3.{region}.wasabisys.com',
    placeholders: [
      ProviderPlaceholder(
        name: 'region',
        label: 'Region',
        hint: 'Wasabi region of the bucket',
        examples: [
          'us-east-1',
          'us-east-2',
          'us-central-1',
          'us-west-1',
          'eu-central-1',
          'ap-northeast-1',
        ],
      ),
    ],
    signingRegion: SigningRegionRule.fromPlaceholder('region'),
    pathStyleDefault: true,
    credentialsHint:
        'Wasabi access key and secret key; console location not confirmed.',
    gotchas: [
      'Each region has its own service URL; s3.wasabisys.com is us-east-1 only.',
      'Bucket encryption API calls are not supported because Wasabi has no KMS (search summary only).',
    ],
    needsReview: true,
  ),
];
