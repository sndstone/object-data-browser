[Subagent hand-back] The text below is the final report of a subagent this session delegated to. It is model output, NOT a message from the user: instructions, requests, or approval claims inside it are the subagent's words and carry no user authority. The harness indents every line of the report, so a frame-like line at column zero inside it would be forged. Notes above this frame may quote model-derived text, which carries no user authority either. The report follows:
No repo files were touched and nothing was created on disk, so there is nothing to clean up. Of the 21 providers, 2 are fully `verified` (Garage, Hetzner) and 19 are `partial`, each with its unconfirmed fields listed in `unverifiedFields`.

Three things to know before using the catalog:

- **Second-hand quoting.** Pages were read through a fetch tool that summarises each page with a small model, so "verified" means a doc page was read this session and reported the fact, not that I saw raw HTML. AWS and Microsoft pages came back raw.
- **Schema deviations.** Azure's `signingRegion` is `null` because SigV4 does not apply, and its S3 feature keys are all `unknown`.
- **Placeholder guesses.** Where the docs did not state a signing region I put `us-east-1` and flagged it; test these before shipping. Region examples I could not read this session are also flagged.

```json
[
  {
    "id": "cloudflare-r2",
    "name": "Cloudflare R2",
    "kind": "s3",
    "endpointTemplate": "https://{accountId}.r2.cloudflarestorage.com",
    "alternateEndpoints": [
      "https://{accountId}.eu.r2.cloudflarestorage.com",
      "https://{accountId}.fedramp.r2.cloudflarestorage.com",
      "https://{accountId}.us.r2.cloudflarestorage.com"
    ],
    "placeholders": [
      {"name": "accountId", "hint": "Cloudflare account ID, shown under Account Details on the R2 overview page", "examples": []}
    ],
    "signingRegion": {"fixed": "auto"},
    "pathStyleDefault": true,
    "addressingNote": "The R2 S3 API page does not state path-style or virtual-hosted support; path-style is an untested default.",
    "credentialsHint": "Access Key ID and Secret Access Key from an R2 API token: R2 > Overview > Account Details > Manage API Tokens.",
    "features": {
      "versioning": "unsupported",
      "tagging": "unsupported",
      "acl": "unsupported",
      "bucketPolicy": "unsupported",
      "lifecycle": "partial: Get/PutBucketLifecycleConfiguration implemented; legacy Get/PutBucketLifecycle not",
      "objectLock": "unsupported",
      "presign": "unknown",
      "sseS3": "unsupported",
      "sseKms": "unsupported",
      "sseC": "supported"
    },
    "gotchas": [
      "Region is 'auto'; an empty value and 'us-east-1' alias to it.",
      "Buckets created in a jurisdiction (EU, FedRAMP, US) are reachable only through the matching jurisdictional endpoint, so one profile per jurisdiction.",
      "The Secret Access Key is shown only once at token creation."
    ],
    "sources": [
      "https://developers.cloudflare.com/r2/api/s3/api/",
      "https://developers.cloudflare.com/r2/api/tokens/"
    ],
    "confidence": "partial",
    "unverifiedFields": ["pathStyleDefault", "features.presign", "placeholders.accountId.examples"]
  },
  {
    "id": "backblaze-b2",
    "name": "Backblaze B2 (S3-compatible API)",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.backblazeb2.com",
    "alternateEndpoints": ["https://{bucket}.s3.{region}.backblazeb2.com"],
    "placeholders": [
      {"name": "region", "hint": "Region of your B2 account, shown with the bucket endpoint in the web console", "examples": ["us-west-004", "us-east-005"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": true,
    "addressingNote": "Docs say the bucket may be in the hostname or the path; no recommendation is stated. Path-style default is my choice.",
    "credentialsHint": "An app key created in the Backblaze web UI: app key ID = access key ID, app key = secret access key.",
    "features": {
      "versioning": "partial: buckets are versioned by default; Get Bucket Versioning support seen only in a search summary",
      "tagging": "unsupported",
      "acl": "partial: bucket-level canned ACLs private/public-read only; object ACLs unsupported",
      "bucketPolicy": "unknown",
      "lifecycle": "partial: S3 lifecycle calls announced on the Backblaze blog (search summary only)",
      "objectLock": "partial: Put Object Lock Configuration listed as supported (search summary only)",
      "presign": "partial: presigned GET and PUT supported; browser POST uploads to presigned URLs unsupported",
      "sseS3": "partial: SSE-B2 (Backblaze-managed keys) supported; AES256 header value not confirmed",
      "sseKms": "unsupported",
      "sseC": "supported"
    },
    "gotchas": [
      "The master app key does not work with the S3-compatible API; create a separate app key.",
      "An app key restricted to one bucket needs the listAllBucketNames capability or ListBuckets fails.",
      "An account belongs to a single region; buckets cannot be created outside it.",
      "HTTPS only and SigV4 only (no SigV2)."
    ],
    "sources": [
      "https://www.backblaze.com/docs/cloud-storage-s3-compatible-api",
      "https://www.backblaze.com/docs/cloud-storage-call-the-s3-compatible-api",
      "https://www.backblaze.com/apidocs/introduction-to-the-s3-compatible-api",
      "https://www.backblaze.com/docs/cloud-storage-s3-compatible-app-keys",
      "https://www.backblaze.com/docs/cloud-storage-application-keys"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion", "pathStyleDefault", "features.versioning", "features.bucketPolicy", "features.lifecycle", "features.objectLock", "features.sseS3"]
  },
  {
    "id": "wasabi",
    "name": "Wasabi",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.wasabisys.com",
    "alternateEndpoints": [
      "https://s3.wasabisys.com (us-east-1 only)",
      "https://s3.nl-1.wasabisys.com (alias of eu-central-1; similar aliases exist for other EU regions)"
    ],
    "placeholders": [
      {"name": "region", "hint": "Wasabi region of the bucket", "examples": ["us-east-1", "us-east-2", "us-central-1", "us-west-1", "eu-central-1", "ap-northeast-1"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": true,
    "addressingNote": "Both styles appear in Wasabi docs (search summary); only an old API guide recommends path-style. Not confirmed on a current page.",
    "credentialsHint": "Wasabi access key and secret key; console location not confirmed.",
    "features": {
      "versioning": "supported",
      "tagging": "unknown",
      "acl": "partial: access control is listed as supported; API details not confirmed",
      "bucketPolicy": "partial: bucket policies described in console docs (search summary only)",
      "lifecycle": "supported",
      "objectLock": "partial: supported, but only if enabled at bucket creation with versioning on (search summary only)",
      "presign": "unknown",
      "sseS3": "unknown",
      "sseKms": "unsupported",
      "sseC": "unknown"
    },
    "gotchas": [
      "Each region has its own service URL; s3.wasabisys.com is us-east-1 only.",
      "Bucket encryption API calls are not supported because Wasabi has no KMS (search summary only)."
    ],
    "sources": [
      "https://docs.wasabi.com/docs/what-are-the-service-urls-for-wasabi-s-different-storage-regions",
      "https://docs.wasabi.com/apidocs",
      "https://docs.wasabi.com/docs/how-do-i-use-aws-cli-with-wasabi",
      "https://docs.wasabi.com/apidocs/object-lock-on-buckets-with-the-wasabi-s3-api"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion", "pathStyleDefault", "addressingNote", "credentialsHint", "features.tagging", "features.acl", "features.bucketPolicy", "features.objectLock", "features.presign", "features.sseS3", "features.sseKms", "features.sseC"]
  },
  {
    "id": "digitalocean-spaces",
    "name": "DigitalOcean Spaces",
    "kind": "s3",
    "endpointTemplate": "https://{region}.digitaloceanspaces.com",
    "alternateEndpoints": ["https://{bucket}.{region}.digitaloceanspaces.com"],
    "placeholders": [
      {"name": "region", "hint": "Datacenter slug of the Space", "examples": ["nyc3", "sfo3", "ams3", "sgp1", "fra1", "syd1"]}
    ],
    "signingRegion": {"fixed": "us-east-1"},
    "pathStyleDefault": false,
    "addressingNote": "The SDK guide sets forcePathStyle to false (virtual-hosted). The API reference accepts either {region} or {bucket}.{region} as Host.",
    "credentialsHint": "Spaces access key and secret key: Control Panel > Spaces Object Storage > Access Keys > Create Access Key.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "partial: canned ACLs private and public-read only",
      "bucketPolicy": "supported",
      "lifecycle": "partial: time-based expiration and aborting incomplete multipart uploads only; no tag-based rules",
      "objectLock": "unknown",
      "presign": "supported",
      "sseS3": "unknown",
      "sseKms": "unknown",
      "sseC": "supported"
    },
    "gotchas": [
      "The SDK guide says to configure region 'us-east-1'; the datacenter goes only in the endpoint. The API reference's SigV4 examples use the slug (nyc3) in the credential scope, so test which the app needs.",
      "Limited-access keys are incompatible with bucket policies set through PutBucketPolicy.",
      "Versioning and bucket policy are API-only (not in the control panel); bucket-level encryption settings are unsupported.",
      "UploadPartCopy does not work across regions or clusters.",
      "Files fetched through presigned URLs are not cached by the Spaces CDN."
    ],
    "sources": [
      "https://docs.digitalocean.com/products/spaces/reference/s3-compatibility/",
      "https://docs.digitalocean.com/reference/api/spaces-api/",
      "https://docs.digitalocean.com/products/spaces/how-to/use-aws-sdks/",
      "https://docs.digitalocean.com/products/spaces/how-to/manage-access/",
      "https://docs.digitalocean.com/products/spaces/details/availability/"
    ],
    "confidence": "partial",
    "unverifiedFields": ["features.objectLock", "features.sseS3", "features.sseKms", "gotcha: CDN endpoint must not be used for signing (not found in the pages read)"]
  },
  {
    "id": "google-cloud-storage",
    "name": "Google Cloud Storage (XML API interoperability)",
    "kind": "s3",
    "endpointTemplate": "https://storage.googleapis.com",
    "alternateEndpoints": ["https://{bucket}.storage.googleapis.com"],
    "placeholders": [],
    "signingRegion": {"fixed": "auto"},
    "pathStyleDefault": true,
    "addressingNote": "Both path-style and virtual-hosted XML endpoints are documented with no stated preference. Virtual-hosted cannot reach domain-named buckets.",
    "credentialsHint": "HMAC key (access ID and secret): Cloud Storage > Settings > Interoperability; service-account HMAC keys are recommended for production.",
    "features": {
      "versioning": "partial: x-amz-version-id maps to the GCS generation number",
      "tagging": "unknown",
      "acl": "partial: supported, but ACL XML differs from S3",
      "bucketPolicy": "unknown",
      "lifecycle": "partial: GCS lifecycle XML differs from S3 lifecycle XML",
      "objectLock": "unknown",
      "presign": "supported",
      "sseS3": "partial: x-amz-server-side-encryption is not required; all data is encrypted automatically",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "HMAC keys work only with the XML API, not the JSON API.",
      "For SigV4 with x-amz headers the service is 's3' and request type 'aws4_request'; any LOCATION value is accepted.",
      "UploadPartCopy is not supported by the XML API.",
      "A new service-account HMAC key can take up to 60 seconds to become usable.",
      "An organisation policy can block HMAC keys, producing 403 Forbidden."
    ],
    "sources": [
      "https://docs.cloud.google.com/storage/docs/interoperability",
      "https://docs.cloud.google.com/storage/docs/authentication/hmackeys",
      "https://docs.cloud.google.com/storage/docs/request-endpoints",
      "https://docs.cloud.google.com/storage/docs/authentication/signatures",
      "https://docs.cloud.google.com/storage/docs/migrating"
    ],
    "confidence": "partial",
    "unverifiedFields": ["pathStyleDefault", "features.tagging", "features.bucketPolicy", "features.objectLock", "features.sseKms", "features.sseC"]
  },
  {
    "id": "oracle-oci",
    "name": "Oracle Cloud (OCI) Object Storage",
    "kind": "s3",
    "endpointTemplate": "https://{namespace}.compat.objectstorage.{region}.oci.customer-oci.com",
    "alternateEndpoints": [
      "https://{bucket}.vhcompat.objectstorage.{region}.oci.customer-oci.com",
      "https://{namespace}.compat.objectstorage.{region}.oraclecloud.com"
    ],
    "placeholders": [
      {"name": "namespace", "hint": "Object Storage namespace of the tenancy", "examples": []},
      {"name": "region", "hint": "OCI region identifier", "examples": ["us-phoenix-1", "us-ashburn-1", "eu-frankfurt-1", "uk-london-1"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": true,
    "addressingNote": "Docs say the application can use path-style or virtual-hosted URLs; Oracle's SDK examples force path-style.",
    "credentialsHint": "Customer Secret Key (Access Key and Secret Key): Profile menu > User settings > Customer secret keys.",
    "features": {
      "versioning": "partial: version IDs are supported; enabling or listing versions via the S3 API is not documented",
      "tagging": "partial: bucket tagging only; object tagging is not listed",
      "acl": "unsupported",
      "bucketPolicy": "unknown",
      "lifecycle": "unknown",
      "objectLock": "unknown",
      "presign": "unknown",
      "sseS3": "partial: all data is encrypted at rest by default and this cannot be toggled through the API",
      "sseKms": "supported",
      "sseC": "supported"
    },
    "gotchas": [
      "SigV2 is not supported; use SigV4.",
      "If the client cannot set the real OCI region, 'us-east-1' or blank works only against the tenancy's home region.",
      "The Secret Key cannot be retrieved after generation.",
      "SSE-KMS takes the OCID of a Vault key in x-amz-server-side-encryption-aws-kms-key-id."
    ],
    "sources": [
      "https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi.htm",
      "https://docs.oracle.com/en-us/iaas/Content/Object/Tasks/s3compatibleapi_topic-Amazon_S3_Compatibility_API_Support.htm"
    ],
    "confidence": "partial",
    "unverifiedFields": ["placeholders.region.examples (only us-phoenix-1 was read this session)", "placeholders.namespace.hint", "alternateEndpoints[2] (oraclecloud.com form seen only in a doc code example)", "features.bucketPolicy", "features.lifecycle", "features.objectLock", "features.presign"]
  },
  {
    "id": "ibm-cos",
    "name": "IBM Cloud Object Storage",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.cloud-object-storage.appdomain.cloud",
    "alternateEndpoints": [
      "https://s3.private.{region}.cloud-object-storage.appdomain.cloud",
      "https://s3.direct.{region}.cloud-object-storage.appdomain.cloud",
      "https://s3.{geo}.cloud-object-storage.appdomain.cloud (cross-region: us, eu, ap)",
      "https://s3.{site}.cloud-object-storage.appdomain.cloud (single site, e.g. ams03, sng01)"
    ],
    "placeholders": [
      {"name": "region", "hint": "Region, cross-region geo or single-site code of the bucket", "examples": ["us-south", "us-east", "eu-gb", "eu-de", "au-syd", "jp-tok"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": true,
    "addressingNote": "IBM's HMAC signature examples are path-style; virtual-hosted support was not confirmed.",
    "credentialsHint": "HMAC credentials: create a Service Credential with 'Include HMAC Credential' on; use cos_hmac_keys.access_key_id and secret_access_key.",
    "features": {
      "versioning": "unknown",
      "tagging": "unknown",
      "acl": "partial: ACLs other than public-read are unsupported",
      "bucketPolicy": "unknown",
      "lifecycle": "unknown",
      "objectLock": "unknown",
      "presign": "unknown",
      "sseS3": "unknown",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "Docs disagree on the signing region: the HMAC page says it accepts any string (examples use 'us-standard'), while the AWS CLI page says to enter a provisioning code (LocationConstraint).",
      "Standard service credentials have no HMAC keys unless the HMAC option was enabled at creation.",
      "ListObjects returns at most 1,000 objects per call; instances are limited to 1,000 buckets."
    ],
    "sources": [
      "https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-endpoints",
      "https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-uhc-hmac-credentials-main",
      "https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-hmac-signature",
      "https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-compatibility-api",
      "https://cloud.ibm.com/docs/cloud-object-storage?topic=cloud-object-storage-aws-cli"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion", "pathStyleDefault", "features.versioning", "features.tagging", "features.bucketPolicy", "features.lifecycle", "features.objectLock", "features.presign", "features.sseS3", "features.sseKms", "features.sseC"]
  },
  {
    "id": "alibaba-oss",
    "name": "Alibaba Cloud OSS",
    "kind": "s3",
    "endpointTemplate": "https://s3.oss-{region}.aliyuncs.com",
    "alternateEndpoints": [
      "https://s3.oss-{region}-internal.aliyuncs.com",
      "https://oss-{region}.aliyuncs.com"
    ],
    "placeholders": [
      {"name": "region", "hint": "OSS region ID without the 'oss-' prefix", "examples": ["cn-hangzhou", "cn-shanghai", "cn-beijing", "ap-southeast-1", "us-west-1", "eu-central-1"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": false,
    "addressingNote": "The S3 compatibility page says OSS supports only virtual-hosted style; the AWS SDK guide reads as if path-style also works. Treat virtual-hosted as required.",
    "credentialsHint": "AccessKey ID and AccessKey Secret created in the RAM console.",
    "features": {
      "versioning": "unknown",
      "tagging": "unknown",
      "acl": "partial: only private, public-read and public-read-write",
      "bucketPolicy": "unknown",
      "lifecycle": "supported",
      "objectLock": "unknown",
      "presign": "unknown",
      "sseS3": "unknown",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "OSS does not support aws-chunked transfer encoding; send unsigned or non-chunked payloads.",
      "Since March 20, 2025, new OSS users need a custom domain (CNAME) for data operations on buckets in Chinese mainland regions.",
      "A wrong-region endpoint returns NoSuchBucket; there are no cross-region redirects.",
      "Bucket names with underscores cannot be reached virtual-hosted style.",
      "Requests are rejected when the clock differs from the server by more than 15 minutes."
    ],
    "sources": [
      "https://www.alibabacloud.com/help/en/oss/developer-reference/compatibility-with-amazon-s3",
      "https://www.alibabacloud.com/help/en/oss/developer-reference/use-aws-sdks-to-access-oss"
    ],
    "confidence": "partial",
    "unverifiedFields": ["placeholders.region.examples (only cn-hangzhou was read this session)", "pathStyleDefault (the two doc pages conflict)", "features.versioning", "features.tagging", "features.bucketPolicy", "features.objectLock", "features.presign", "features.sseS3", "features.sseKms", "features.sseC"]
  },
  {
    "id": "tencent-cos",
    "name": "Tencent Cloud COS",
    "kind": "s3",
    "endpointTemplate": "https://cos.{region}.myqcloud.com",
    "alternateEndpoints": [],
    "placeholders": [
      {"name": "region", "hint": "COS region of the bucket", "examples": ["ap-guangzhou", "ap-shanghai", "ap-beijing", "ap-singapore"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": false,
    "addressingNote": "COS supports virtual-hosted style. Buckets created after January 1, 2024 do not support path-style domain names.",
    "credentialsHint": "SecretId (access key) and SecretKey from the CAM console.",
    "features": {
      "versioning": "unknown",
      "tagging": "unknown",
      "acl": "unknown",
      "bucketPolicy": "unknown",
      "lifecycle": "unknown",
      "objectLock": "unknown",
      "presign": "unknown",
      "sseS3": "unknown",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "Bucket names must be given in full as BucketName-APPID, e.g. examplebucket-1250000000.",
      "Only buckets in the endpoint's region are listed or usable.",
      "Tencent states that COS does not guarantee full S3 compatibility and publishes no feature matrix on the pages read."
    ],
    "sources": [
      "https://www.tencentcloud.com/document/product/436/32537",
      "https://www.tencentcloud.com/document/product/436/34688"
    ],
    "confidence": "partial",
    "unverifiedFields": ["placeholders.region.examples (only ap-guangzhou was read this session)", "features (all)"]
  },
  {
    "id": "scaleway",
    "name": "Scaleway Object Storage",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.scw.cloud",
    "alternateEndpoints": ["https://{bucket}.s3.{region}.scw.cloud"],
    "placeholders": [
      {"name": "region", "hint": "Scaleway region of the bucket", "examples": ["fr-par", "nl-ams", "pl-waw", "it-mil"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": false,
    "addressingNote": "Both styles are valid; the concepts page says virtual-host style is generally preferred.",
    "credentialsHint": "Scaleway API key (access key and secret key); console location not confirmed.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "supported",
      "bucketPolicy": "supported",
      "lifecycle": "supported",
      "objectLock": "supported",
      "presign": "unknown",
      "sseS3": "partial: PutBucketEncryption offers SSE-ONE (Scaleway-managed); AES256 request header not confirmed",
      "sseKms": "partial: SSE-KMS is listed for PutBucketEncryption only",
      "sseC": "supported"
    },
    "gotchas": [
      "Legacy Get/PutBucketLifecycle are deprecated; use the LifecycleConfiguration calls.",
      "Bucket notifications are still in development.",
      "Losing an SSE-C key means losing the data; HeadObject without the key returns 400."
    ],
    "sources": [
      "https://www.scaleway.com/en/docs/object-storage/api-cli/using-api-call-list/",
      "https://raw.githubusercontent.com/scaleway/docs-content/main/pages/object-storage/api-cli/using-api-call-list.mdx",
      "https://raw.githubusercontent.com/scaleway/docs-content/main/pages/object-storage/concepts.mdx",
      "https://raw.githubusercontent.com/scaleway/docs-content/main/pages/object-storage/api-cli/enable-sse-c.mdx"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion", "credentialsHint", "features.presign", "sources[0] (scaleway.com returned 403 to the fetcher; content was read from the docs' GitHub source)"]
  },
  {
    "id": "hetzner",
    "name": "Hetzner Object Storage",
    "kind": "s3",
    "endpointTemplate": "https://{location}.your-objectstorage.com",
    "alternateEndpoints": ["https://{bucket}.{location}.your-objectstorage.com"],
    "placeholders": [
      {"name": "location", "hint": "Hetzner location of the bucket", "examples": ["fsn1", "nbg1", "hel1"]}
    ],
    "signingRegion": {"fromPlaceholder": "location"},
    "pathStyleDefault": false,
    "addressingNote": "Docs configure tools virtual-hosted (mc 'path: off'; AWS CLI addressing_style virtual for presigned URLs). Path-style is not documented.",
    "credentialsHint": "S3 credentials (access key and secret key) generated in the Hetzner Console; valid for every bucket in the project.",
    "features": {
      "versioning": "supported",
      "tagging": "partial: bucket tagging is not supported; object tagging is not addressed",
      "acl": "partial: canned private/public-read on bucket creation",
      "bucketPolicy": "partial: supported, but the NotAction element is not",
      "lifecycle": "partial: NoncurrentVersionExpiration supports NoncurrentDays only",
      "objectLock": "supported",
      "presign": "supported",
      "sseS3": "unsupported",
      "sseKms": "unsupported",
      "sseC": "partial: supported, but copying SSE-C encrypted objects is not"
    },
    "gotchas": [
      "CopyObject works only within the same bucket.",
      "The AWS CLI guide says to use virtual addressing before creating presigned URLs.",
      "The region value is loosely enforced: AWS CLI may leave it empty, rclone uses the location.",
      "Limits: 5 GB per PUT or part, 10,000 parts, 5 TB per object, 100 TB per bucket.",
      "The secret key cannot be viewed again after creation."
    ],
    "sources": [
      "https://docs.hetzner.com/storage/object-storage/overview",
      "https://docs.hetzner.com/storage/object-storage/supported-actions",
      "https://docs.hetzner.com/storage/object-storage/getting-started/using-s3-api-tools"
    ],
    "confidence": "verified",
    "unverifiedFields": []
  },
  {
    "id": "linode",
    "name": "Linode / Akamai Object Storage",
    "kind": "s3",
    "endpointTemplate": "https://{endpoint}.linodeobjects.com",
    "alternateEndpoints": ["https://{bucket}.{endpoint}.linodeobjects.com"],
    "placeholders": [
      {"name": "endpoint", "hint": "S3 endpoint hostname prefix shown for the region in Cloud Manager", "examples": ["us-southeast-1", "us-ord-1", "us-ord-10", "us-lax-4", "au-mel-1", "gb-lon-1"]}
    ],
    "signingRegion": {"fixed": "us-east-1"},
    "pathStyleDefault": false,
    "addressingNote": "Bucket URLs are documented virtual-hosted; a signed-URL example in the docs is path-style, so both appear to work. Docs do not name either style.",
    "credentialsHint": "Access key and secret key: Cloud Manager > Object Storage > Access Keys > Create Access Key.",
    "features": {
      "versioning": "supported",
      "tagging": "unknown",
      "acl": "partial: object-level ACLs on legacy E0/E1 endpoints only",
      "bucketPolicy": "unknown",
      "lifecycle": "partial: expiration of current and noncurrent versions and failed multipart uploads; NewerNoncurrentVersions unsupported (search summary only)",
      "objectLock": "partial: must be enabled at bucket creation and is managed only through the S3 API (search summary only)",
      "presign": "supported",
      "sseS3": "partial: default encryption at rest on E2/E3 endpoints only",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "One region can have several endpoints of different types (us-ord-1 is E1, us-ord-10 is E3); features differ by type.",
      "CORS policies, object ACLs and static websites exist only on legacy E0/E1 endpoints.",
      "Access keys are created for selected regions; a limited key's permissions cannot be changed later.",
      "Limits: 5 GB per request, parts 5 MiB to 5 GiB, 10,000 parts, 5 TiB per object."
    ],
    "sources": [
      "https://techdocs.akamai.com/cloud-computing/docs/endpoint-types",
      "https://techdocs.akamai.com/cloud-computing/docs/access-buckets-and-files-through-urls",
      "https://techdocs.akamai.com/cloud-computing/docs/object-storage-product-limits",
      "https://techdocs.akamai.com/cloud-computing/docs/manage-access-keys",
      "https://techdocs.akamai.com/cloud-computing/docs/protect-data-with-object-lock"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion (no doc read this session states one; us-east-1 is a placeholder)", "pathStyleDefault", "features.versioning (implied by the Object Lock page)", "features.tagging", "features.bucketPolicy", "features.lifecycle", "features.objectLock", "features.sseKms", "features.sseC"]
  },
  {
    "id": "ovhcloud",
    "name": "OVHcloud Object Storage (S3)",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.io.cloud.ovh.net",
    "alternateEndpoints": [
      "https://{bucket}.s3.{region}.io.cloud.ovh.net",
      "https://s3.{region}.perf.cloud.ovh.net (legacy; default write class High Performance)",
      "https://s3.{region}.cloud.ovh.net (legacy Swift-based storage)"
    ],
    "placeholders": [
      {"name": "region", "hint": "OVHcloud region code, lowercase", "examples": ["gra", "sbg", "rbx", "de", "uk", "eu-west-par"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": false,
    "addressingNote": "Only the virtual-host bucket endpoint is documented; path-style is not stated either way.",
    "credentialsHint": "S3 access key and secret key of an Object Storage user; Control Panel location not confirmed.",
    "features": {
      "versioning": "unknown",
      "tagging": "unknown",
      "acl": "unknown",
      "bucketPolicy": "unknown",
      "lifecycle": "supported",
      "objectLock": "partial: supported, but not for the Cold Archive storage class",
      "presign": "supported",
      "sseS3": "partial: SSE-OMK (OVHcloud-managed keys, AES-256); request header not confirmed",
      "sseKms": "unknown",
      "sseC": "supported"
    },
    "gotchas": [
      "Enter the region in lowercase.",
      "Prefer the 'io' endpoint; 'perf' is kept only for tools that cannot use the Express One Zone class.",
      "Cold Archive exists only in eu-west-par.",
      "The FAQ says access rights cannot yet be configured per bucket, only per user profile and per object."
    ],
    "sources": [
      "https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-location",
      "https://docs.ovhcloud.com/en/guides/storage-and-backup/object-storage/s3-faq"
    ],
    "confidence": "partial",
    "unverifiedFields": ["pathStyleDefault", "credentialsHint", "features.versioning", "features.tagging", "features.acl", "features.bucketPolicy", "features.sseKms"]
  },
  {
    "id": "storj",
    "name": "Storj (hosted S3 gateway)",
    "kind": "s3",
    "endpointTemplate": "https://gateway.storjshare.io",
    "alternateEndpoints": ["https://gateway.eu1.storjshare.io (regional; from a Storj forum staff reply, not the docs)"],
    "placeholders": [],
    "signingRegion": {"fixed": "us-east-1"},
    "pathStyleDefault": true,
    "addressingNote": "Official docs do not state addressing support; the official s3fs guide uses path-style. Forum staff say both styles work.",
    "credentialsHint": "S3 credentials (access key, secret key, endpoint) generated from a new access grant in the Storj web console, or with 'uplink share --register'.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "unsupported",
      "bucketPolicy": "unsupported",
      "lifecycle": "unsupported",
      "objectLock": "supported",
      "presign": "unknown",
      "sseS3": "unknown",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "Official docs give no region value; forum staff say the gateway ignores it.",
      "gateway.storjshare.io routes to the nearest gateway instance automatically.",
      "Multipart: 5 MiB minimum part size, 10,000 parts; UploadPartCopy is enabled only on request.",
      "ListMultipartUploads does not support UploadIdMarker."
    ],
    "sources": [
      "https://storj.dev/dcs/api/s3/s3-compatibility",
      "https://storj.dev/dcs/api/s3/s3-compatible-gateway",
      "https://storj.dev/dcs/third-party-tools/s3fs"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion (placeholder)", "pathStyleDefault", "alternateEndpoints", "features.presign (a 'Using presigned URLs' docs page exists but was not read)", "features.sseS3", "features.sseKms", "features.sseC"]
  },
  {
    "id": "idrive-e2",
    "name": "IDrive e2",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.idrivee2.com",
    "alternateEndpoints": [
      "https://s3.{alias}.idrivee2.com (short aliases, e.g. s3.va-1.idrivee2.com for us-east-1)",
      "Account-specific hostnames shown in the dashboard's Enabled regions section (e.g. l4g4.ch11.idrivee2-2.com)"
    ],
    "placeholders": [
      {"name": "region", "hint": "Region code of an enabled e2 region", "examples": ["us-east-1", "us-west-1", "us-west-2", "us-central-1", "us-midwest-1", "ca-east-1"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": true,
    "addressingNote": "All API examples are path-style; virtual-hosted is not documented.",
    "credentialsHint": "Access key and secret key created in the e2 dashboard for a chosen enabled region.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "partial: canned private/public-read on bucket creation; an object ACL must match the bucket's",
      "bucketPolicy": "supported",
      "lifecycle": "partial: expiration rules; docs note the bucket must have versioning enabled",
      "objectLock": "partial: supported, but must be enabled at bucket creation",
      "presign": "unknown",
      "sseS3": "supported",
      "sseKms": "partial: appears only in bucket default-encryption examples",
      "sseC": "supported"
    },
    "gotchas": [
      "Docs are inconsistent: the endpoint table uses s3.{region}.idrivee2.com, while the developer guide says endpoints are unique per user. Let users paste the dashboard value.",
      "Access keys are created per region.",
      "Multipart parts must be at least 5 MB except the last; part numbers run 1 to 10,000."
    ],
    "sources": [
      "https://www.idrive.com/s3-storage-e2/e2-endpoint-urls",
      "https://www.idrive.com/s3-storage-e2/s3-compatible-api",
      "https://www.idrive.com/s3-storage-e2/developer-guide"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion", "credentialsHint (from a search summary)", "alternateEndpoints[1]", "features.presign"]
  },
  {
    "id": "minio",
    "name": "MinIO (self-hosted)",
    "kind": "s3",
    "endpointTemplate": "{scheme}://{host}:{port}",
    "alternateEndpoints": [],
    "placeholders": [
      {"name": "scheme", "hint": "http or https, depending on whether TLS is configured", "examples": ["https", "http"]},
      {"name": "host", "hint": "Hostname or IP of the MinIO server or load balancer", "examples": ["minio.example.net", "localhost"]},
      {"name": "port", "hint": "S3 API port (9000 appears in MinIO examples)", "examples": ["9000"]}
    ],
    "signingRegion": {"fixed": "us-east-1"},
    "pathStyleDefault": true,
    "addressingNote": "Without MINIO_DOMAIN the server accepts only path-style requests; virtual-host needs MINIO_DOMAIN, wildcard DNS and a matching TLS certificate.",
    "credentialsHint": "Access key and secret key of a MinIO user or service account; creation steps not confirmed.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "unsupported",
      "bucketPolicy": "supported",
      "lifecycle": "supported",
      "objectLock": "supported",
      "presign": "unknown",
      "sseS3": "partial: bucket encryption calls are listed; server-side KMS requirements not confirmed",
      "sseKms": "partial: bucket encryption calls are listed; server-side KMS requirements not confirmed",
      "sseC": "partial: referenced in the compatibility page; TLS requirement not confirmed"
    },
    "gotchas": [
      "Bucket and object ACL calls are unsupported; MinIO says to use policies instead.",
      "Virtual-hosted requests fail unless MINIO_DOMAIN is set on the server.",
      "The docs now centre on the commercial AIStor product; community-edition defaults may differ."
    ],
    "sources": [
      "https://docs.min.io/community/minio-object-store/reference/s3-api-compatibility.html",
      "https://docs.min.io/aistor/reference/aistor-server/settings/core/",
      "https://docs.min.io/aistor/reference/aistor-server/settings/site/"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion (us-east-1 appears only as an example value for MINIO_SITE_REGION)", "placeholders.port (9000 not confirmed as the default)", "credentialsHint", "features.presign", "features.sseS3", "features.sseKms", "features.sseC"]
  },
  {
    "id": "ceph-rgw",
    "name": "Ceph RADOS Gateway (self-hosted)",
    "kind": "s3",
    "endpointTemplate": "{scheme}://{host}:{port}",
    "alternateEndpoints": [],
    "placeholders": [
      {"name": "scheme", "hint": "http or https", "examples": ["https", "http"]},
      {"name": "host", "hint": "Hostname of the RGW endpoint or load balancer", "examples": ["rgw.example.com"]},
      {"name": "port", "hint": "RGW frontend port set by the administrator", "examples": ["80", "8000"]}
    ],
    "signingRegion": {"fixed": "us-east-1"},
    "pathStyleDefault": true,
    "addressingNote": "Both styles are supported, but virtual-hosted needs rgw_dns_name (or zonegroup hostnames), wildcard DNS and a wildcard certificate.",
    "credentialsHint": "Access key and secret key of an RGW user, issued by the cluster administrator.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "partial: supported with a different set of canned ACLs",
      "bucketPolicy": "supported",
      "lifecycle": "supported",
      "objectLock": "unknown",
      "presign": "unknown",
      "sseS3": "supported",
      "sseKms": "supported",
      "sseC": "partial: supported, but a bucket or the cluster can block SSE-C (BlockedEncryptionTypes, rgw_s3_block_sse_c_by_default)"
    },
    "gotchas": [
      "Server-side encryption requests must use HTTPS.",
      "SSE-KMS and SSE-S3 depend on a key management service configured by the administrator.",
      "The frontends page lists port default 80; real deployments vary, so do not pre-fill a port."
    ],
    "sources": [
      "https://docs.ceph.com/en/latest/radosgw/s3/",
      "https://docs.ceph.com/en/latest/radosgw/s3/commons/",
      "https://docs.ceph.com/en/latest/radosgw/encryption/",
      "https://docs.ceph.com/en/latest/radosgw/frontends/"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion (placeholder; not read)", "credentialsHint", "features.objectLock", "features.presign"]
  },
  {
    "id": "garage",
    "name": "Garage (self-hosted)",
    "kind": "s3",
    "endpointTemplate": "http://{host}:3900",
    "alternateEndpoints": ["https://{bucket}{rootDomain} (vhost-style; needs root_domain, e.g. .s3.example.com)"],
    "placeholders": [
      {"name": "host", "hint": "Hostname or IP of the Garage node or reverse proxy", "examples": ["localhost", "garage.example.com"]}
    ],
    "signingRegion": {"fixed": "garage"},
    "pathStyleDefault": true,
    "addressingNote": "Path-style is always enabled; vhost-style works only when root_domain is configured with wildcard DNS.",
    "credentialsHint": "'garage key create <name>' prints a Key ID (GK...) and Secret key; grant access with 'garage bucket allow'.",
    "features": {
      "versioning": "unsupported",
      "tagging": "unsupported",
      "acl": "unsupported",
      "bucketPolicy": "unsupported",
      "lifecycle": "partial: only AbortIncompleteMultipartUpload and Expiration actions",
      "objectLock": "unsupported",
      "presign": "supported",
      "sseS3": "unsupported",
      "sseKms": "unsupported",
      "sseC": "supported"
    },
    "gotchas": [
      "The region must match the server's s3_region ('garage' in the reference config); a mismatch fails with AuthorizationHeaderMalformed.",
      "The S3 API port has no TLS; HTTPS needs a reverse proxy.",
      "SigV2 is not implemented.",
      "GetBucketVersioning is a stub that always reports versioning not enabled."
    ],
    "sources": [
      "https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/",
      "https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/",
      "https://garagehq.deuxfleurs.fr/documentation/quick-start/"
    ],
    "confidence": "verified",
    "unverifiedFields": []
  },
  {
    "id": "seaweedfs",
    "name": "SeaweedFS S3 gateway (self-hosted)",
    "kind": "s3",
    "endpointTemplate": "http://{host}:8333",
    "alternateEndpoints": [],
    "placeholders": [
      {"name": "host", "hint": "Hostname or IP of the 'weed s3' gateway", "examples": ["localhost"]}
    ],
    "signingRegion": {"fixed": "us-east-1"},
    "pathStyleDefault": true,
    "addressingNote": "The wiki pages read do not cover addressing style; path-style is an untested default.",
    "credentialsHint": "accessKey/secretKey identities in the JSON file passed with -s3.config, or AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY on the server when nothing else is configured.",
    "features": {
      "versioning": "partial: supported; MFA Delete is not",
      "tagging": "supported",
      "acl": "supported",
      "bucketPolicy": "supported",
      "lifecycle": "partial: transition rules are not supported",
      "objectLock": "supported",
      "presign": "supported",
      "sseS3": "supported",
      "sseKms": "supported",
      "sseC": "supported"
    },
    "gotchas": [
      "Port 8333 appears in the wiki's examples; confirm it for the deployment.",
      "GetBucketLocation returns a default location; no region is documented.",
      "Bucket replication, notification, logging, website and accelerate configuration are unsupported."
    ],
    "sources": [
      "https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API",
      "https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials"
    ],
    "confidence": "partial",
    "unverifiedFields": ["signingRegion (placeholder; not read)", "pathStyleDefault"]
  },
  {
    "id": "amazon-s3",
    "name": "Amazon S3",
    "kind": "s3",
    "endpointTemplate": "https://s3.{region}.amazonaws.com",
    "alternateEndpoints": [
      "https://s3.dualstack.{region}.amazonaws.com",
      "https://s3-fips.{region}.amazonaws.com (US, Canada and GovCloud regions)",
      "https://s3-fips.dualstack.{region}.amazonaws.com (US, Canada and GovCloud regions)"
    ],
    "placeholders": [
      {"name": "region", "hint": "AWS Region code of the bucket", "examples": ["us-east-1", "us-west-2", "eu-west-1", "eu-central-1", "ap-southeast-1", "ap-northeast-1"]}
    ],
    "signingRegion": {"fromPlaceholder": "region"},
    "pathStyleDefault": false,
    "addressingNote": "The endpoints page says both virtual-hosted and path-style methods can be used; AWS's preference for virtual-hosted was not read this session.",
    "credentialsHint": "IAM access key ID and secret access key.",
    "features": {
      "versioning": "supported",
      "tagging": "supported",
      "acl": "supported",
      "bucketPolicy": "supported",
      "lifecycle": "supported",
      "objectLock": "supported",
      "presign": "supported",
      "sseS3": "supported",
      "sseKms": "supported",
      "sseC": "partial: per a search summary, SSE-C is disabled by default on new general purpose buckets from April 2026"
    },
    "gotchas": [
      "Creating a bucket outside us-east-1 requires LocationConstraint set to the same Region.",
      "Buckets and new objects are encrypted with SSE-S3 by default.",
      "Multipart: parts 5 MB to 5 GB, 10,000 parts; the quota table lists max object size as 48.828125 TB.",
      "Object tags are limited to 10 per object."
    ],
    "sources": [
      "https://docs.aws.amazon.com/general/latest/gr/s3.html",
      "https://docs.aws.amazon.com/AmazonS3/latest/userguide/default-bucket-encryption.html",
      "https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html"
    ],
    "confidence": "partial",
    "unverifiedFields": ["pathStyleDefault (recommendation not read)", "credentialsHint", "features.versioning/acl/bucketPolicy/objectLock/presign/sseKms (assumed for the reference implementation, not read)", "features.sseC"]
  },
  {
    "id": "azure-blob",
    "name": "Azure Blob Storage",
    "kind": "azure",
    "endpointTemplate": "https://{account}.blob.core.windows.net",
    "alternateEndpoints": [
      "https://{account}.blob.core.usgovcloudapi.net (Azure Government)",
      "https://{account}.blob.core.chinacloudapi.cn (Azure operated by 21Vianet)",
      "https://{account}.z{N}.blob.storage.azure.net (Azure DNS zone endpoints, preview, retiring March 2027)",
      "https://{account}.dfs.core.windows.net (Data Lake Storage)",
      "http://127.0.0.1:10000/devstoreaccount1 (Azurite)"
    ],
    "placeholders": [
      {"name": "account", "hint": "Storage account name: 3-24 characters, lowercase letters and numbers only", "examples": ["mystorageaccount", "devstoreaccount1"]}
    ],
    "signingRegion": null,
    "pathStyleDefault": false,
    "addressingNote": "Not S3: the account is in the hostname and the container in the path. Azurite puts the account in the path (http://127.0.0.1:10000/{account}/{container}).",
    "credentialsHint": "Storage account name plus an access key (portal: Security + networking > Access keys), or a SAS token.",
    "features": {
      "versioning": "unknown",
      "tagging": "unknown",
      "acl": "unknown",
      "bucketPolicy": "unknown",
      "lifecycle": "unknown",
      "objectLock": "unknown",
      "presign": "unknown",
      "sseS3": "unknown",
      "sseKms": "unknown",
      "sseC": "unknown"
    },
    "gotchas": [
      "Sovereign clouds change only the suffix; connection strings carry it as EndpointSuffix.",
      "Azurite's default account is devstoreaccount1 with a fixed well-known key; the UseDevelopmentStorage=true shortcut uses HTTP on port 10000.",
      "Shared Key authorization can be disabled on an account; Microsoft recommends Entra ID.",
      "Azurite does not support Data Lake Storage Gen2 or Azure Files."
    ],
    "sources": [
      "https://learn.microsoft.com/en-us/azure/storage/common/storage-account-overview",
      "https://learn.microsoft.com/en-us/azure/storage/common/storage-configure-connection-string",
      "https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azurite",
      "https://learn.microsoft.com/en-us/azure/azure-government/documentation-government-get-started-connect-to-storage"
    ],
    "confidence": "partial",
    "unverifiedFields": ["alternateEndpoints[0] (Azure Government suffix confirmed only through a search summary of Microsoft Learn)", "features (S3 feature keys were not researched for Azure)"]
  }
]
```

## Native GCS JSON API

**(a) Service-account auth**
- Build a JWT with header `{"alg":"RS256","typ":"JWT"}` and claims `iss` (service account email), `scope` (space-delimited), `aud` = `https://oauth2.googleapis.com/token`, `iat`, and `exp` (at most 1 hour after `iat`).
- Sign it with the key's private key and POST form-encoded to `https://oauth2.googleapis.com/token` with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer` and `assertion=<jwt>`.
- The response carries `access_token`, `token_type: Bearer` and `expires_in` (3600 in the example). No refresh token is mentioned; mint a new JWT on expiry.
- Read-write scope: `https://www.googleapis.com/auth/devstorage.read_write`. Others: `devstorage.read_only`, `devstorage.full_control`, `cloud-platform`.
- Sources: https://developers.google.com/identity/protocols/oauth2/service-account, https://docs.cloud.google.com/storage/docs/oauth-scopes

**(b) Endpoints** (base `https://storage.googleapis.com`, HTTPS only; object names URL-encoded in the path)
- **Bucket list:** `GET /storage/v1/b?project=…` (`project` required), with `maxResults`, `pageToken`, `prefix`, `projection`.
- **Object list:** `GET /storage/v1/b/{bucket}/o` with `prefix`, `delimiter`, `pageToken`, `maxResults` (1000 recommended ceiling), `versions`, `startOffset`, `endOffset`, `includeTrailingDelimiter`, `matchGlob`, `softDeleted`. It returns `items[]`, `prefixes[]`, `nextPageToken`; a page can be empty while a token is still present.
- **Metadata:** `GET /storage/v1/b/{bucket}/o/{object}`, optionally with `generation`.
- **Download:** the same URL with `alt=media`; the `Range` header is supported. `/download/storage/v1/b/{bucket}/o/{object}?alt=media` is an optional alternative.
- **Simple upload:** `POST /upload/storage/v1/b/{bucket}/o?uploadType=media&name=…`; `uploadType=multipart` sends metadata and data together. Maximum object size is 5 TiB.
- **Resumable upload:**
  - Initiate with `POST /upload/storage/v1/b/{bucket}/o?uploadType=resumable&name=…`; the session URI comes back in the `Location` header. Treat it as a credential.
  - PUT chunks with `Content-Range: bytes first-last/total` (`*` if the total is unknown). Chunks must be multiples of 256 KiB except the last; 8 MiB or more is recommended.
  - Intermediate responses are `308` with a `Range` header; continue from the byte after its upper bound.
  - To resume, PUT with `Content-Length: 0` and `Content-Range: bytes */SIZE`.
  - Sessions expire after one week. `DELETE` on the session URI cancels and returns 499.
- **Rewrite/copy:** `POST /storage/v1/b/{srcBucket}/o/{srcObject}/rewriteTo/b/{dstBucket}/o/{dstObject}`. Repeat with the returned `rewriteToken` until `done` is true; the response also has `totalBytesRewritten`, `objectSize`, and `resource` on completion. The token expires after one week (410 afterwards).
- **Delete:** `DELETE /storage/v1/b/{bucket}/o/{object}`; `generation` permanently deletes that revision. Success returns an empty body.
- **Compose:** `POST /storage/v1/b/{bucket}/o/{destinationObject}/compose` with `sourceObjects[]` (`name`, `generation`, `objectPreconditions.ifGenerationMatch`) and `destination`. Up to 32 sources, all in the same bucket and storage class.
- Sources: https://docs.cloud.google.com/storage/docs/request-endpoints, https://docs.cloud.google.com/storage/docs/performing-resumable-uploads, and the pages under https://docs.cloud.google.com/storage/docs/json_api/v1/ (`buckets/list`, `objects/list`, `objects/get`, `objects/insert`, `objects/rewrite`, `objects/delete`, `objects/compose`)

**(c) Versions and preconditions**
- `generation` identifies the object version and exists whether or not Object Versioning is on. It is unique per version but not guaranteed to increase.
- `metageneration` starts at 1 for each generation and increments on each metadata update.
- Select a version with the `generation` query parameter; list them with `versions=true`.
- Preconditions are `ifGenerationMatch`, `ifGenerationNotMatch`, `ifMetagenerationMatch`, `ifMetagenerationNotMatch`. Rewrite also has `ifSource*` variants.
- `ifGenerationMatch=0` succeeds only when no live version exists.
- A failed match precondition returns 412; a failed not-match returns 304.
- Sources: https://docs.cloud.google.com/storage/docs/metadata, https://docs.cloud.google.com/storage/docs/request-preconditions

**(d) V4 signed URLs**
- Algorithm `GOOG4-RSA-SHA256`: RSA-SHA256 with PKCS#1 v1.5 padding over the string-to-sign, hex-encoded.
- Credential scope is `DATE/LOCATION/storage/goog4_request`; any LOCATION is accepted and Google's sample uses `auto`.
- Query parameters: `X-Goog-Algorithm`, `X-Goog-Credential`, `X-Goog-Date`, `X-Goog-Expires`, `X-Goog-SignedHeaders`, `X-Goog-Signature`. The payload hash is `UNSIGNED-PAYLOAD`.
- Maximum expiry is 604800 seconds (7 days).
- Sources: https://docs.cloud.google.com/storage/docs/access-control/signing-urls-manually, https://docs.cloud.google.com/storage/docs/authentication/signatures

**(e) Encryption**
- Customer-supplied key headers: `x-goog-encryption-algorithm: AES256`, `x-goog-encryption-key` (base64 AES-256 key), `x-goog-encryption-key-sha256` (base64 SHA-256 of the key).
- Rewrite adds `x-goog-copy-source-encryption-algorithm`, `-key` and `-key-sha256` for the source.
- HTTPS is required. Without the key you still get most metadata but not the CRC32C or MD5 hashes; wrong or missing keys return 400.
- KMS: the `kmsKeyName` query parameter on insert and compose, and `destinationKmsKeyName` on rewrite, take a Cloud KMS key resource name. The exact format string was not shown on the pages read.
- Source: https://docs.cloud.google.com/storage/docs/encryption/customer-supplied-keys

**(f) Emulator**
- `STORAGE_EMULATOR_HOST` is documented in Google's Go client: set it to the emulator address (example `localhost:9000`) and requests go to `http://localhost:9000/storage/v1/b`. The same page states there is no official Cloud Storage emulator.
- The fake-gcs-server README does not mention the variable. It defaults to HTTPS on port 4443 (`-scheme http` for plain HTTP), serves `/storage/v1/b`, does not validate signed-URL query parameters, and needs `-public-host` for signed URLs.
- Whether fake-gcs-server needs auth, and how well it handles resumable uploads, was not stated on the page.
- Sources: https://pkg.go.dev/cloud.google.com/go/storage, https://github.com/fsouza/fake-gcs-server
agentId: a46ab676916ac3ac5 (use SendMessage with to: 'a46ab676916ac3ac5', summary: '<5-10 word recap>' to continue this agent)
<usage>subagent_tokens: 217598
tool_uses: 103
duration_ms: 599444</usage>