use super::{
    digest_body, Bytes, Capture, Completion, ConformanceClient, Input, Instant, SidecarError,
};
use crate::object_encryption::Encryption;
use aws_sdk_s3::primitives::{DateTime, DateTimeFormat};
use aws_sdk_s3::types::Error as DeleteError;
use aws_sdk_s3::types::*;
use aws_sdk_s3::{error::BuildError, primitives::ByteStream};
use serde::Serialize;
use serde_json::{json, Map, Value};

pub(super) enum InputError {
    Shape(SidecarError),
    Build,
}

impl From<BuildError> for InputError {
    fn from(_: BuildError) -> Self {
        Self::Build
    }
}

type Parsed<T> = Result<T, InputError>;

fn shape_error(expected: &str) -> InputError {
    InputError::Shape(SidecarError::new(
        "invalid_request",
        format!("Expected {expected} in the S3 conformance input."),
    ))
}

pub(super) fn member<T>(
    input: &Input,
    name: &str,
    parse: impl FnOnce(&Value) -> Parsed<T>,
) -> Parsed<Option<T>> {
    input
        .get(name)
        .map(parse)
        .transpose()
        .map_err(|error| match error {
            InputError::Shape(error) => InputError::Shape(SidecarError::new(
                "invalid_request",
                format!("{name}: {}", error.message),
            )),
            other => other,
        })
}

fn object(value: &Value) -> Parsed<&Input> {
    value.as_object().ok_or_else(|| shape_error("an object"))
}

pub(super) fn string(value: &Value) -> Parsed<String> {
    value
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| shape_error("a string"))
}

fn integer(value: &Value) -> Parsed<i32> {
    value
        .as_i64()
        .and_then(|v| i32::try_from(v).ok())
        .ok_or_else(|| shape_error("a 32-bit integer"))
}

// ListParts uses a string marker in the SDK. Integer part numbers are
// accepted on input while returned tokens keep their original string value.
fn part_number_marker(value: &Value) -> Parsed<String> {
    value
        .as_i64()
        .map(|value| value.to_string())
        .map_or_else(|| string(value), Ok)
}

fn boolean(value: &Value) -> Parsed<bool> {
    value.as_bool().ok_or_else(|| shape_error("a boolean"))
}

fn enumeration<T: for<'a> From<&'a str>>(value: &Value) -> Parsed<T> {
    value
        .as_str()
        .map(T::from)
        .ok_or_else(|| shape_error("a string"))
}

fn datetime(value: &Value) -> Parsed<DateTime> {
    value
        .as_str()
        .and_then(|v| DateTime::from_str(v, DateTimeFormat::DateTime).ok())
        .ok_or_else(|| shape_error("an ISO-8601 timestamp"))
}

fn list<T>(parse: impl Fn(&Value) -> Parsed<T>) -> impl FnOnce(&Value) -> Parsed<Vec<T>> {
    move |value| {
        value
            .as_array()
            .ok_or_else(|| shape_error("an array"))?
            .iter()
            .map(parse)
            .collect()
    }
}

fn metadata(value: &Value) -> Parsed<std::collections::HashMap<String, String>> {
    object(value)?
        .iter()
        .map(|(key, value)| Ok((key.clone(), string(value)?)))
        .collect()
}

fn copy_source(value: &Value) -> Parsed<String> {
    let input = object(value)?;
    let bucket =
        member(input, "Bucket", string)?.ok_or_else(|| shape_error("a CopySource bucket"))?;
    let key = member(input, "Key", string)?.ok_or_else(|| shape_error("a CopySource key"))?;
    let version = member(input, "VersionId", string)?;
    // The Rust SDK takes an already encoded header string. Match server_copy
    // and encode each value exactly once, leaving the version delimiter intact.
    let mut source = urlencoding::encode(&format!("{bucket}/{key}")).into_owned();
    if let Some(version) = version {
        source.push_str("?versionId=");
        source.push_str(&urlencoding::encode(&version));
    }
    Ok(source)
}

macro_rules! set_members {
    ($builder:expr, $input:ident; $( $setter:ident($name:literal, $parse:expr); )*) => {
        $builder$(.$setter(member($input, $name, $parse)?))*
    };
}

macro_rules! shape_result {
    (direct, $value:expr) => {
        Ok($value)
    };
    (checked, $value:expr) => {
        Ok($value?)
    };
}

macro_rules! input_shapes {
    ($( $function:ident => $shape:ident $kind:ident {
        $( $setter:ident($name:literal, $parse:expr); )*
    } )*) => {
        $(fn $function(value: &Value) -> Parsed<$shape> {
            let _input = object(value)?;
            shape_result!($kind, set_members!($shape::builder(), _input; $(
                $setter($name, $parse);
            )*).build())
        })*
    };
}

fn scalar(value: &impl Serialize) -> Value {
    json!(value)
}

fn enum_value(value: &impl AsRef<str>) -> Value {
    json!(value.as_ref())
}

fn timestamp(value: &DateTime) -> Value {
    value
        .fmt(DateTimeFormat::DateTime)
        .map_or(Value::Null, Value::String)
}

fn items<T>(project: impl Fn(&T) -> Value) -> impl FnOnce(&Vec<T>) -> Value {
    move |values| Value::Array(values.iter().map(project).collect())
}

macro_rules! project_member {
    ($value:expr, required, $convert:expr) => {
        Some($convert(&$value))
    };
    ($value:expr, optional, $convert:expr) => {
        $value.as_ref().map($convert)
    };
}

macro_rules! project {
    ($value:ident; $( $name:literal => $field:ident $presence:ident $convert:expr, )*) => {{
        let mut fields = Map::new();
        $(if let Some(member) = project_member!($value.$field, $presence, $convert) {
            if !member.is_null() {
                fields.insert($name.into(), member);
            }
        })*
        Value::Object(fields)
    }};
}

macro_rules! output_shapes {
    ($( $function:ident => $shape:ident { $( $fields:tt )* } )*) => {
        $(fn $function(value: &$shape) -> Value { project!(value; $($fields)*) })*
    };
}

struct Call<'a> {
    client: &'a ConformanceClient,
    input: &'a Input,
    body: Bytes,
    encryption: &'a Encryption,
    source_encryption: &'a Encryption,
    capture: &'a Capture,
}

macro_rules! option {
    (body, $request:expr, $call:ident) => {
        $request.body(ByteStream::from($call.body))
    };
    (customer, $request:expr, $call:ident) => {
        encryption_customer!($request, $call.encryption)
    };
    (source, $request:expr, $call:ident) => {
        encryption_source!($request, $call.source_encryption)
    };
}

macro_rules! complete {
    ([], $start:ident, $response:ident, $call:ident) => {
        Completion::new("service", $start)
    };
    ([{ $($fields:tt)* }], $start:ident, $response:ident, $call:ident) => {
        Completion::new("service", $start).output(project!($response; $($fields)*))
    };
    ([stream], $start:ident, $response:ident, $call:ident) => {
        match digest_body($response.body, $call.client.read_timeout).await {
            Ok(body) => Completion::new("service", $start).output(json!({"Body": body})),
            Err(error) => error.complete($start),
        }
    };
}

macro_rules! invoke {
    ($call:ident, $method:ident, { $( $setters:tt )* } [ $( $option:ident ),* ] $projection:tt) => {
        Box::pin(async {
            let input = $call.input;
            let request = set_members!($call.client.sdk.$method(), input; $($setters)*);
            $(let request = option!($option, request, $call);)*
            let start = Instant::now();
            Ok(match request.customize().interceptor($call.capture.clone()).send().await {
                Ok(_response) => complete!($projection, start, _response, $call),
                Err(error) => Completion::sdk_error($call.capture, start, error),
            })
        }).await
    };
}

macro_rules! invoke_group {
    ($op:ident, $call:ident; [$($name:literal => $method:ident),+ $(,)?] $fields:tt $options:tt $projection:tt) => {
        match $op {
            $($name => invoke!($call, $method, $fields $options $projection),)+
            _ => unreachable!("operation is in this group"),
        }
    };
}

macro_rules! operations {
    ($( [$($name:literal => $method:ident),+ $(,)?] $fields:tt $options:tt $projection:tt; )*) => {
        pub(super) const OPERATIONS: &[&str] = &[$($($name,)+)* "PresignedRequest"];

        pub(super) async fn run(
            client: &ConformanceClient,
            op: &str,
            input: &Input,
            body: Bytes,
            encryption: &Encryption,
            source_encryption: &Encryption,
            capture: &Capture,
        ) -> Parsed<Completion> {
            let call = Call { client, input, body, encryption, source_encryption, capture };
            match op {
                $($($name)|+ => invoke_group!(op, call; [$($name => $method),+] $fields $options $projection),)*
                _ => unreachable!("operation was checked against the allowlist"),
            }
        }
    };
}
// Each entry pairs an AWS API member name with its typed Rust SDK setter.

input_shapes! {
    create_bucket_configuration => CreateBucketConfiguration direct {
        set_location_constraint("LocationConstraint", enumeration);
    }
    versioning_configuration => VersioningConfiguration direct {
        set_status("Status", enumeration);
    }
    tag => Tag checked {
        set_key("Key", string);
        set_value("Value", string);
    }
    tagging => Tagging checked {
        set_tag_set("TagSet", list(tag));
    }
    cors_rule => CorsRule checked {
        set_id("ID", string);
        set_allowed_headers("AllowedHeaders", list(string));
        set_allowed_methods("AllowedMethods", list(string));
        set_allowed_origins("AllowedOrigins", list(string));
        set_expose_headers("ExposeHeaders", list(string));
        set_max_age_seconds("MaxAgeSeconds", integer);
    }
    cors_configuration => CorsConfiguration checked {
        set_cors_rules("CORSRules", list(cors_rule));
    }
    lifecycle_rule_filter => LifecycleRuleFilter direct {
        set_prefix("Prefix", string);
    }
    lifecycle_expiration => LifecycleExpiration direct {
        set_days("Days", integer);
    }
    abort_incomplete_multipart_upload => AbortIncompleteMultipartUpload direct {
        set_days_after_initiation("DaysAfterInitiation", integer);
    }
    lifecycle_rule => LifecycleRule checked {
        set_id("ID", string);
        set_status("Status", enumeration);
        set_filter("Filter", lifecycle_rule_filter);
        set_expiration("Expiration", lifecycle_expiration);
        set_abort_incomplete_multipart_upload("AbortIncompleteMultipartUpload", abort_incomplete_multipart_upload);
    }
    bucket_lifecycle_configuration => BucketLifecycleConfiguration checked {
        set_rules("Rules", list(lifecycle_rule));
    }
    server_side_encryption_by_default => ServerSideEncryptionByDefault checked {
        set_sse_algorithm("SSEAlgorithm", enumeration);
        set_kms_master_key_id("KMSMasterKeyID", string);
    }
    server_side_encryption_rule => ServerSideEncryptionRule direct {
        set_apply_server_side_encryption_by_default("ApplyServerSideEncryptionByDefault", server_side_encryption_by_default);
        set_bucket_key_enabled("BucketKeyEnabled", boolean);
    }
    server_side_encryption_configuration => ServerSideEncryptionConfiguration checked {
        set_rules("Rules", list(server_side_encryption_rule));
    }
    public_access_block_configuration => PublicAccessBlockConfiguration direct {
        set_block_public_acls("BlockPublicAcls", boolean);
        set_ignore_public_acls("IgnorePublicAcls", boolean);
        set_block_public_policy("BlockPublicPolicy", boolean);
        set_restrict_public_buckets("RestrictPublicBuckets", boolean);
    }
    ownership_controls_rule => OwnershipControlsRule checked {
        set_object_ownership("ObjectOwnership", enumeration);
    }
    ownership_controls => OwnershipControls checked {
        set_rules("Rules", list(ownership_controls_rule));
    }
    accelerate_configuration => AccelerateConfiguration direct {
        set_status("Status", enumeration);
    }
    request_payment_configuration => RequestPaymentConfiguration checked {
        set_payer("Payer", enumeration);
    }
    index_document => IndexDocument checked {
        set_suffix("Suffix", string);
    }
    error_document => ErrorDocument checked {
        set_key("Key", string);
    }
    website_configuration => WebsiteConfiguration direct {
        set_index_document("IndexDocument", index_document);
        set_error_document("ErrorDocument", error_document);
    }
    notification_configuration => NotificationConfiguration direct {
    }
    storage_class_analysis => StorageClassAnalysis direct {
    }
    analytics_configuration => AnalyticsConfiguration checked {
        set_id("Id", string);
        set_storage_class_analysis("StorageClassAnalysis", storage_class_analysis);
    }
    metrics_configuration => MetricsConfiguration checked {
        set_id("Id", string);
    }
    inventory_schedule => InventorySchedule checked {
        set_frequency("Frequency", enumeration);
    }
    inventory_s3_bucket_destination => InventoryS3BucketDestination checked {
        set_bucket("Bucket", string);
        set_format("Format", enumeration);
        set_prefix("Prefix", string);
    }
    inventory_destination => InventoryDestination direct {
        set_s3_bucket_destination("S3BucketDestination", inventory_s3_bucket_destination);
    }
    inventory_configuration => InventoryConfiguration checked {
        set_id("Id", string);
        set_is_enabled("IsEnabled", boolean);
        set_included_object_versions("IncludedObjectVersions", enumeration);
        set_schedule("Schedule", inventory_schedule);
        set_destination("Destination", inventory_destination);
    }
    tiering => Tiering checked {
        set_days("Days", integer);
        set_access_tier("AccessTier", enumeration);
    }
    intelligent_tiering_configuration => IntelligentTieringConfiguration checked {
        set_id("Id", string);
        set_status("Status", enumeration);
        set_tierings("Tierings", list(tiering));
    }
    default_retention => DefaultRetention direct {
        set_mode("Mode", enumeration);
        set_days("Days", integer);
    }
    object_lock_rule => ObjectLockRule direct {
        set_default_retention("DefaultRetention", default_retention);
    }
    object_lock_configuration => ObjectLockConfiguration direct {
        set_object_lock_enabled("ObjectLockEnabled", enumeration);
        set_rule("Rule", object_lock_rule);
    }
    object_identifier => ObjectIdentifier checked {
        set_key("Key", string);
        set_version_id("VersionId", string);
    }
    delete => Delete checked {
        set_objects("Objects", list(object_identifier));
        set_quiet("Quiet", boolean);
    }
    completed_part => CompletedPart direct {
        set_part_number("PartNumber", integer);
        set_e_tag("ETag", string);
    }
    completed_multipart_upload => CompletedMultipartUpload direct {
        set_parts("Parts", list(completed_part));
    }
    object_lock_retention => ObjectLockRetention direct {
        set_mode("Mode", enumeration);
        set_retain_until_date("RetainUntilDate", datetime);
    }
    object_lock_legal_hold => ObjectLockLegalHold direct {
        set_status("Status", enumeration);
    }
}

output_shapes! {
    project_bucket => Bucket {
        "Name" => name optional scalar,
        "CreationDate" => creation_date optional timestamp,
    }
    project_tag => Tag {
        "Key" => key required scalar,
        "Value" => value required scalar,
    }
    project_cors_rule => CorsRule {
        "ID" => id optional scalar,
        "AllowedHeaders" => allowed_headers optional items(scalar),
        "AllowedMethods" => allowed_methods required items(scalar),
        "AllowedOrigins" => allowed_origins required items(scalar),
        "ExposeHeaders" => expose_headers optional items(scalar),
        "MaxAgeSeconds" => max_age_seconds optional scalar,
    }
    project_lifecycle_rule_filter => LifecycleRuleFilter {
        "Prefix" => prefix optional scalar,
    }
    project_lifecycle_expiration => LifecycleExpiration {
        "Days" => days optional scalar,
    }
    project_abort_incomplete_multipart_upload => AbortIncompleteMultipartUpload {
        "DaysAfterInitiation" => days_after_initiation optional scalar,
    }
    project_lifecycle_rule => LifecycleRule {
        "ID" => id optional scalar,
        "Status" => status required enum_value,
        "Filter" => filter optional project_lifecycle_rule_filter,
        "Expiration" => expiration optional project_lifecycle_expiration,
        "AbortIncompleteMultipartUpload" => abort_incomplete_multipart_upload optional project_abort_incomplete_multipart_upload,
    }
    project_policy_status => PolicyStatus {
        "IsPublic" => is_public optional scalar,
    }
    project_server_side_encryption_by_default => ServerSideEncryptionByDefault {
        "SSEAlgorithm" => sse_algorithm required enum_value,
        "KMSMasterKeyID" => kms_master_key_id optional scalar,
    }
    project_server_side_encryption_rule => ServerSideEncryptionRule {
        "ApplyServerSideEncryptionByDefault" => apply_server_side_encryption_by_default optional project_server_side_encryption_by_default,
        "BucketKeyEnabled" => bucket_key_enabled optional scalar,
    }
    project_server_side_encryption_configuration => ServerSideEncryptionConfiguration {
        "Rules" => rules required items(project_server_side_encryption_rule),
    }
    project_public_access_block_configuration => PublicAccessBlockConfiguration {
        "BlockPublicAcls" => block_public_acls optional scalar,
        "IgnorePublicAcls" => ignore_public_acls optional scalar,
        "BlockPublicPolicy" => block_public_policy optional scalar,
        "RestrictPublicBuckets" => restrict_public_buckets optional scalar,
    }
    project_ownership_controls_rule => OwnershipControlsRule {
        "ObjectOwnership" => object_ownership required enum_value,
    }
    project_ownership_controls => OwnershipControls {
        "Rules" => rules required items(project_ownership_controls_rule),
    }
    project_owner => Owner {
        "ID" => id optional scalar,
        "DisplayName" => display_name optional scalar,
    }
    project_grantee => Grantee {
        "Type" => r#type required enum_value,
        "ID" => id optional scalar,
        "DisplayName" => display_name optional scalar,
        "URI" => uri optional scalar,
    }
    project_grant => Grant {
        "Grantee" => grantee optional project_grantee,
        "Permission" => permission optional enum_value,
    }
    project_logging_enabled => LoggingEnabled {
        "TargetBucket" => target_bucket required scalar,
        "TargetPrefix" => target_prefix required scalar,
    }
    project_index_document => IndexDocument {
        "Suffix" => suffix required scalar,
    }
    project_error_document => ErrorDocument {
        "Key" => key required scalar,
    }
    project_topic_configuration => TopicConfiguration {
        "Id" => id optional scalar,
    }
    project_queue_configuration => QueueConfiguration {
        "Id" => id optional scalar,
    }
    project_lambda_function_configuration => LambdaFunctionConfiguration {
        "Id" => id optional scalar,
    }
    project_replication_rule => ReplicationRule {
        "ID" => id optional scalar,
        "Status" => status required enum_value,
    }
    project_replication_configuration => ReplicationConfiguration {
        "Role" => role required scalar,
        "Rules" => rules required items(project_replication_rule),
    }
    project_analytics_configuration => AnalyticsConfiguration {
        "Id" => id required scalar,
    }
    project_metrics_configuration => MetricsConfiguration {
        "Id" => id required scalar,
    }
    project_inventory_configuration_summary => InventoryConfiguration {
        "Id" => id required scalar,
    }
    project_intelligent_tiering_configuration_summary => IntelligentTieringConfiguration {
        "Id" => id required scalar,
    }
    project_inventory_configuration => InventoryConfiguration {
        "Id" => id required scalar,
        "IsEnabled" => is_enabled required scalar,
    }
    project_intelligent_tiering_configuration => IntelligentTieringConfiguration {
        "Id" => id required scalar,
        "Status" => status required enum_value,
    }
    project_default_retention => DefaultRetention {
        "Mode" => mode optional enum_value,
        "Days" => days optional scalar,
        "Years" => years optional scalar,
    }
    project_object_lock_rule => ObjectLockRule {
        "DefaultRetention" => default_retention optional project_default_retention,
    }
    project_object_lock_configuration => ObjectLockConfiguration {
        "ObjectLockEnabled" => object_lock_enabled optional enum_value,
        "Rule" => rule optional project_object_lock_rule,
    }
    project_object_lock_retention => ObjectLockRetention {
        "Mode" => mode optional enum_value,
        "RetainUntilDate" => retain_until_date optional timestamp,
    }
    project_object_lock_legal_hold => ObjectLockLegalHold {
        "Status" => status optional enum_value,
    }
    project_copy_object_result => CopyObjectResult {
        "ETag" => e_tag optional scalar,
        "LastModified" => last_modified optional timestamp,
    }
    project_copy_part_result => CopyPartResult {
        "ETag" => e_tag optional scalar,
        "LastModified" => last_modified optional timestamp,
    }
    project_checksum => Checksum {
        "ChecksumCRC32" => checksum_crc32 optional scalar,
        "ChecksumCRC32C" => checksum_crc32_c optional scalar,
        "ChecksumSHA1" => checksum_sha1 optional scalar,
        "ChecksumSHA256" => checksum_sha256 optional scalar,
        "ChecksumType" => checksum_type optional enum_value,
    }
    project_get_object_attributes_parts => GetObjectAttributesParts {
        "TotalPartsCount" => total_parts_count optional scalar,
    }
    project_object => Object {
        "Key" => key optional scalar,
        "ETag" => e_tag optional scalar,
        "Size" => size optional scalar,
        "LastModified" => last_modified optional timestamp,
        "StorageClass" => storage_class optional enum_value,
    }
    project_common_prefix => CommonPrefix {
        "Prefix" => prefix optional scalar,
    }
    project_object_version => ObjectVersion {
        "Key" => key optional scalar,
        "VersionId" => version_id optional scalar,
        "IsLatest" => is_latest optional scalar,
        "ETag" => e_tag optional scalar,
        "Size" => size optional scalar,
        "LastModified" => last_modified optional timestamp,
    }
    project_delete_marker_entry => DeleteMarkerEntry {
        "Key" => key optional scalar,
        "VersionId" => version_id optional scalar,
        "IsLatest" => is_latest optional scalar,
        "LastModified" => last_modified optional timestamp,
    }
    project_deleted_object => DeletedObject {
        "Key" => key optional scalar,
        "VersionId" => version_id optional scalar,
        "DeleteMarker" => delete_marker optional scalar,
        "DeleteMarkerVersionId" => delete_marker_version_id optional scalar,
    }
    project_error => DeleteError {
        "Key" => key optional scalar,
        "VersionId" => version_id optional scalar,
        "Code" => code optional scalar,
        "Message" => message optional scalar,
    }
    project_part => Part {
        "PartNumber" => part_number optional scalar,
        "ETag" => e_tag optional scalar,
        "Size" => size optional scalar,
    }
    project_multipart_upload => MultipartUpload {
        "Key" => key optional scalar,
        "UploadId" => upload_id optional scalar,
        "Initiated" => initiated optional timestamp,
    }
}

operations! {
    ["CreateBucket" => create_bucket] {
        set_bucket("Bucket", string);
        set_create_bucket_configuration("CreateBucketConfiguration", create_bucket_configuration);
        set_object_lock_enabled_for_bucket("ObjectLockEnabledForBucket", boolean);
        set_object_ownership("ObjectOwnership", enumeration);
    } [] [];
    [
        "HeadBucket" => head_bucket,
        "DeleteBucket" => delete_bucket,
        "DeleteBucketTagging" => delete_bucket_tagging,
        "DeleteBucketCors" => delete_bucket_cors,
        "DeleteBucketLifecycle" => delete_bucket_lifecycle,
        "DeleteBucketPolicy" => delete_bucket_policy,
        "DeleteBucketEncryption" => delete_bucket_encryption,
        "DeletePublicAccessBlock" => delete_public_access_block,
        "DeleteBucketOwnershipControls" => delete_bucket_ownership_controls,
        "DeleteBucketWebsite" => delete_bucket_website,
        "DeleteBucketReplication" => delete_bucket_replication,
    ] {
        set_bucket("Bucket", string);
    } [] [];
    ["GetBucketLocation" => get_bucket_location] {
        set_bucket("Bucket", string);
    } [] [{
        "LocationConstraint" => location_constraint optional enum_value,
    }];
    ["GetBucketVersioning" => get_bucket_versioning] {
        set_bucket("Bucket", string);
    } [] [{
        "Status" => status optional enum_value,
        "MFADelete" => mfa_delete optional enum_value,
    }];
    ["GetBucketTagging" => get_bucket_tagging] {
        set_bucket("Bucket", string);
    } [] [{
        "TagSet" => tag_set required items(project_tag),
    }];
    ["GetBucketCors" => get_bucket_cors] {
        set_bucket("Bucket", string);
    } [] [{
        "CORSRules" => cors_rules optional items(project_cors_rule),
    }];
    ["GetBucketLifecycleConfiguration" => get_bucket_lifecycle_configuration] {
        set_bucket("Bucket", string);
    } [] [{
        "Rules" => rules optional items(project_lifecycle_rule),
    }];
    ["GetBucketPolicy" => get_bucket_policy] {
        set_bucket("Bucket", string);
    } [] [{
        "Policy" => policy optional scalar,
    }];
    ["GetBucketPolicyStatus" => get_bucket_policy_status] {
        set_bucket("Bucket", string);
    } [] [{
        "PolicyStatus" => policy_status optional project_policy_status,
    }];
    ["GetBucketEncryption" => get_bucket_encryption] {
        set_bucket("Bucket", string);
    } [] [{
        "ServerSideEncryptionConfiguration" => server_side_encryption_configuration optional project_server_side_encryption_configuration,
    }];
    ["GetPublicAccessBlock" => get_public_access_block] {
        set_bucket("Bucket", string);
    } [] [{
        "PublicAccessBlockConfiguration" => public_access_block_configuration optional project_public_access_block_configuration,
    }];
    ["GetBucketOwnershipControls" => get_bucket_ownership_controls] {
        set_bucket("Bucket", string);
    } [] [{
        "OwnershipControls" => ownership_controls optional project_ownership_controls,
    }];
    ["GetBucketAcl" => get_bucket_acl] {
        set_bucket("Bucket", string);
    } [] [{
        "Owner" => owner optional project_owner,
        "Grants" => grants optional items(project_grant),
    }];
    ["GetBucketAccelerateConfiguration" => get_bucket_accelerate_configuration] {
        set_bucket("Bucket", string);
    } [] [{
        "Status" => status optional enum_value,
    }];
    ["GetBucketRequestPayment" => get_bucket_request_payment] {
        set_bucket("Bucket", string);
    } [] [{
        "Payer" => payer optional enum_value,
    }];
    ["GetBucketLogging" => get_bucket_logging] {
        set_bucket("Bucket", string);
    } [] [{
        "LoggingEnabled" => logging_enabled optional project_logging_enabled,
    }];
    ["GetBucketWebsite" => get_bucket_website] {
        set_bucket("Bucket", string);
    } [] [{
        "IndexDocument" => index_document optional project_index_document,
        "ErrorDocument" => error_document optional project_error_document,
    }];
    ["GetBucketNotificationConfiguration" => get_bucket_notification_configuration] {
        set_bucket("Bucket", string);
    } [] [{
        "TopicConfigurations" => topic_configurations optional items(project_topic_configuration),
        "QueueConfigurations" => queue_configurations optional items(project_queue_configuration),
        "LambdaFunctionConfigurations" => lambda_function_configurations optional items(project_lambda_function_configuration),
    }];
    ["GetBucketReplication" => get_bucket_replication] {
        set_bucket("Bucket", string);
    } [] [{
        "ReplicationConfiguration" => replication_configuration optional project_replication_configuration,
    }];
    ["GetObjectLockConfiguration" => get_object_lock_configuration] {
        set_bucket("Bucket", string);
    } [] [{
        "ObjectLockConfiguration" => object_lock_configuration optional project_object_lock_configuration,
    }];
    ["ListBuckets" => list_buckets] {
        set_max_buckets("MaxBuckets", integer);
        set_continuation_token("ContinuationToken", string);
        set_prefix("Prefix", string);
    } [] [{
        "Buckets" => buckets optional items(project_bucket),
        "ContinuationToken" => continuation_token optional scalar,
    }];
    ["PutBucketVersioning" => put_bucket_versioning] {
        set_bucket("Bucket", string);
        set_versioning_configuration("VersioningConfiguration", versioning_configuration);
    } [] [];
    ["PutBucketTagging" => put_bucket_tagging] {
        set_bucket("Bucket", string);
        set_tagging("Tagging", tagging);
    } [] [];
    ["PutBucketCors" => put_bucket_cors] {
        set_bucket("Bucket", string);
        set_cors_configuration("CORSConfiguration", cors_configuration);
    } [] [];
    ["PutBucketLifecycleConfiguration" => put_bucket_lifecycle_configuration] {
        set_bucket("Bucket", string);
        set_lifecycle_configuration("LifecycleConfiguration", bucket_lifecycle_configuration);
    } [] [];
    ["PutBucketPolicy" => put_bucket_policy] {
        set_bucket("Bucket", string);
        set_policy("Policy", string);
    } [] [];
    ["PutBucketEncryption" => put_bucket_encryption] {
        set_bucket("Bucket", string);
        set_server_side_encryption_configuration("ServerSideEncryptionConfiguration", server_side_encryption_configuration);
    } [] [];
    ["PutPublicAccessBlock" => put_public_access_block] {
        set_bucket("Bucket", string);
        set_public_access_block_configuration("PublicAccessBlockConfiguration", public_access_block_configuration);
    } [] [];
    ["PutBucketOwnershipControls" => put_bucket_ownership_controls] {
        set_bucket("Bucket", string);
        set_ownership_controls("OwnershipControls", ownership_controls);
    } [] [];
    ["PutBucketAcl" => put_bucket_acl] {
        set_bucket("Bucket", string);
        set_acl("ACL", enumeration);
    } [] [];
    ["PutBucketAccelerateConfiguration" => put_bucket_accelerate_configuration] {
        set_bucket("Bucket", string);
        set_accelerate_configuration("AccelerateConfiguration", accelerate_configuration);
    } [] [];
    ["PutBucketRequestPayment" => put_bucket_request_payment] {
        set_bucket("Bucket", string);
        set_request_payment_configuration("RequestPaymentConfiguration", request_payment_configuration);
    } [] [];
    ["PutBucketWebsite" => put_bucket_website] {
        set_bucket("Bucket", string);
        set_website_configuration("WebsiteConfiguration", website_configuration);
    } [] [];
    ["PutBucketNotificationConfiguration" => put_bucket_notification_configuration] {
        set_bucket("Bucket", string);
        set_notification_configuration("NotificationConfiguration", notification_configuration);
    } [] [];
    ["ListBucketAnalyticsConfigurations" => list_bucket_analytics_configurations] {
        set_bucket("Bucket", string);
        set_continuation_token("ContinuationToken", string);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "NextContinuationToken" => next_continuation_token optional scalar,
        "AnalyticsConfigurationList" => analytics_configuration_list optional items(project_analytics_configuration),
    }];
    ["ListBucketMetricsConfigurations" => list_bucket_metrics_configurations] {
        set_bucket("Bucket", string);
        set_continuation_token("ContinuationToken", string);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "NextContinuationToken" => next_continuation_token optional scalar,
        "MetricsConfigurationList" => metrics_configuration_list optional items(project_metrics_configuration),
    }];
    ["ListBucketInventoryConfigurations" => list_bucket_inventory_configurations] {
        set_bucket("Bucket", string);
        set_continuation_token("ContinuationToken", string);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "NextContinuationToken" => next_continuation_token optional scalar,
        "InventoryConfigurationList" => inventory_configuration_list optional items(project_inventory_configuration_summary),
    }];
    ["ListBucketIntelligentTieringConfigurations" => list_bucket_intelligent_tiering_configurations] {
        set_bucket("Bucket", string);
        set_continuation_token("ContinuationToken", string);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "NextContinuationToken" => next_continuation_token optional scalar,
        "IntelligentTieringConfigurationList" => intelligent_tiering_configuration_list optional items(project_intelligent_tiering_configuration_summary),
    }];
    ["GetBucketAnalyticsConfiguration" => get_bucket_analytics_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
    } [] [{
        "AnalyticsConfiguration" => analytics_configuration optional project_analytics_configuration,
    }];
    [
        "DeleteBucketAnalyticsConfiguration" => delete_bucket_analytics_configuration,
        "DeleteBucketMetricsConfiguration" => delete_bucket_metrics_configuration,
        "DeleteBucketInventoryConfiguration" => delete_bucket_inventory_configuration,
        "DeleteBucketIntelligentTieringConfiguration" => delete_bucket_intelligent_tiering_configuration,
    ] {
        set_bucket("Bucket", string);
        set_id("Id", string);
    } [] [];
    ["GetBucketMetricsConfiguration" => get_bucket_metrics_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
    } [] [{
        "MetricsConfiguration" => metrics_configuration optional project_metrics_configuration,
    }];
    ["GetBucketInventoryConfiguration" => get_bucket_inventory_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
    } [] [{
        "InventoryConfiguration" => inventory_configuration optional project_inventory_configuration,
    }];
    ["GetBucketIntelligentTieringConfiguration" => get_bucket_intelligent_tiering_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
    } [] [{
        "IntelligentTieringConfiguration" => intelligent_tiering_configuration optional project_intelligent_tiering_configuration,
    }];
    ["PutBucketAnalyticsConfiguration" => put_bucket_analytics_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
        set_analytics_configuration("AnalyticsConfiguration", analytics_configuration);
    } [] [];
    ["PutBucketMetricsConfiguration" => put_bucket_metrics_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
        set_metrics_configuration("MetricsConfiguration", metrics_configuration);
    } [] [];
    ["PutBucketInventoryConfiguration" => put_bucket_inventory_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
        set_inventory_configuration("InventoryConfiguration", inventory_configuration);
    } [] [];
    ["PutBucketIntelligentTieringConfiguration" => put_bucket_intelligent_tiering_configuration] {
        set_bucket("Bucket", string);
        set_id("Id", string);
        set_intelligent_tiering_configuration("IntelligentTieringConfiguration", intelligent_tiering_configuration);
    } [] [];
    ["PutObjectLockConfiguration" => put_object_lock_configuration] {
        set_bucket("Bucket", string);
        set_object_lock_configuration("ObjectLockConfiguration", object_lock_configuration);
    } [] [];
    ["PutObject" => put_object] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_content_type("ContentType", string);
        set_content_disposition("ContentDisposition", string);
        set_content_encoding("ContentEncoding", string);
        set_content_language("ContentLanguage", string);
        set_cache_control("CacheControl", string);
        set_metadata("Metadata", metadata);
        set_content_md5("ContentMD5", string);
        set_checksum_algorithm("ChecksumAlgorithm", enumeration);
        set_checksum_crc32("ChecksumCRC32", string);
        set_checksum_crc32_c("ChecksumCRC32C", string);
        set_checksum_sha1("ChecksumSHA1", string);
        set_checksum_sha256("ChecksumSHA256", string);
        set_if_match("IfMatch", string);
        set_if_none_match("IfNoneMatch", string);
        set_tagging("Tagging", string);
        set_storage_class("StorageClass", enumeration);
        set_server_side_encryption("ServerSideEncryption", enumeration);
        set_ssekms_key_id("SSEKMSKeyId", string);
        set_object_lock_mode("ObjectLockMode", enumeration);
        set_object_lock_retain_until_date("ObjectLockRetainUntilDate", datetime);
        set_object_lock_legal_hold_status("ObjectLockLegalHoldStatus", enumeration);
    } [body, customer] [];
    ["GetObject" => get_object] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_range("Range", string);
        set_part_number("PartNumber", integer);
        set_if_match("IfMatch", string);
        set_if_none_match("IfNoneMatch", string);
        set_if_modified_since("IfModifiedSince", datetime);
        set_if_unmodified_since("IfUnmodifiedSince", datetime);
        set_checksum_mode("ChecksumMode", enumeration);
    } [customer] [stream];
    ["HeadObject" => head_object] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_range("Range", string);
        set_part_number("PartNumber", integer);
        set_if_match("IfMatch", string);
        set_if_none_match("IfNoneMatch", string);
        set_if_modified_since("IfModifiedSince", datetime);
        set_if_unmodified_since("IfUnmodifiedSince", datetime);
        set_checksum_mode("ChecksumMode", enumeration);
    } [customer] [];
    ["DeleteObject" => delete_object] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_bypass_governance_retention("BypassGovernanceRetention", boolean);
    } [] [];
    ["DeleteObjects" => delete_objects] {
        set_bucket("Bucket", string);
        set_delete("Delete", delete);
        set_bypass_governance_retention("BypassGovernanceRetention", boolean);
    } [] [{
        "Deleted" => deleted optional items(project_deleted_object),
        "Errors" => errors optional items(project_error),
    }];
    ["CopyObject" => copy_object] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_copy_source("CopySource", copy_source);
        set_metadata_directive("MetadataDirective", enumeration);
        set_metadata("Metadata", metadata);
        set_content_type("ContentType", string);
        set_tagging_directive("TaggingDirective", enumeration);
        set_tagging("Tagging", string);
        set_copy_source_if_match("CopySourceIfMatch", string);
        set_copy_source_if_none_match("CopySourceIfNoneMatch", string);
        set_server_side_encryption("ServerSideEncryption", enumeration);
    } [customer, source] [{
        "CopyObjectResult" => copy_object_result optional project_copy_object_result,
    }];
    ["GetObjectAttributes" => get_object_attributes] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_object_attributes("ObjectAttributes", list(enumeration));
    } [customer] [{
        "ETag" => e_tag optional scalar,
        "ObjectSize" => object_size optional scalar,
        "StorageClass" => storage_class optional enum_value,
        "Checksum" => checksum optional project_checksum,
        "ObjectParts" => object_parts optional project_get_object_attributes_parts,
    }];
    ["ListObjects" => list_objects] {
        set_bucket("Bucket", string);
        set_prefix("Prefix", string);
        set_delimiter("Delimiter", string);
        set_marker("Marker", string);
        set_max_keys("MaxKeys", integer);
        set_encoding_type("EncodingType", enumeration);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "Marker" => marker optional scalar,
        "NextMarker" => next_marker optional scalar,
        "Prefix" => prefix optional scalar,
        "Delimiter" => delimiter optional scalar,
        "MaxKeys" => max_keys optional scalar,
        "EncodingType" => encoding_type optional enum_value,
        "Contents" => contents optional items(project_object),
        "CommonPrefixes" => common_prefixes optional items(project_common_prefix),
    }];
    ["ListObjectsV2" => list_objects_v2] {
        set_bucket("Bucket", string);
        set_prefix("Prefix", string);
        set_delimiter("Delimiter", string);
        set_continuation_token("ContinuationToken", string);
        set_start_after("StartAfter", string);
        set_max_keys("MaxKeys", integer);
        set_encoding_type("EncodingType", enumeration);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "KeyCount" => key_count optional scalar,
        "MaxKeys" => max_keys optional scalar,
        "Prefix" => prefix optional scalar,
        "Delimiter" => delimiter optional scalar,
        "StartAfter" => start_after optional scalar,
        "EncodingType" => encoding_type optional enum_value,
        "ContinuationToken" => continuation_token optional scalar,
        "NextContinuationToken" => next_continuation_token optional scalar,
        "Contents" => contents optional items(project_object),
        "CommonPrefixes" => common_prefixes optional items(project_common_prefix),
    }];
    ["ListObjectVersions" => list_object_versions] {
        set_bucket("Bucket", string);
        set_prefix("Prefix", string);
        set_delimiter("Delimiter", string);
        set_key_marker("KeyMarker", string);
        set_version_id_marker("VersionIdMarker", string);
        set_max_keys("MaxKeys", integer);
        set_encoding_type("EncodingType", enumeration);
    } [] [{
        "IsTruncated" => is_truncated optional scalar,
        "KeyMarker" => key_marker optional scalar,
        "VersionIdMarker" => version_id_marker optional scalar,
        "NextKeyMarker" => next_key_marker optional scalar,
        "NextVersionIdMarker" => next_version_id_marker optional scalar,
        "Prefix" => prefix optional scalar,
        "Delimiter" => delimiter optional scalar,
        "MaxKeys" => max_keys optional scalar,
        "EncodingType" => encoding_type optional enum_value,
        "Versions" => versions optional items(project_object_version),
        "DeleteMarkers" => delete_markers optional items(project_delete_marker_entry),
        "CommonPrefixes" => common_prefixes optional items(project_common_prefix),
    }];
    ["GetObjectTagging" => get_object_tagging] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
    } [] [{
        "TagSet" => tag_set required items(project_tag),
    }];
    ["DeleteObjectTagging" => delete_object_tagging] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
    } [] [];
    ["PutObjectTagging" => put_object_tagging] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_tagging("Tagging", tagging);
    } [] [];
    ["GetObjectAcl" => get_object_acl] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
    } [] [{
        "Owner" => owner optional project_owner,
        "Grants" => grants optional items(project_grant),
    }];
    ["PutObjectAcl" => put_object_acl] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_acl("ACL", enumeration);
    } [] [];
    ["CreateMultipartUpload" => create_multipart_upload] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_content_type("ContentType", string);
        set_metadata("Metadata", metadata);
        set_checksum_algorithm("ChecksumAlgorithm", enumeration);
        set_server_side_encryption("ServerSideEncryption", enumeration);
    } [customer] [{
        "Bucket" => bucket optional scalar,
        "Key" => key optional scalar,
        "UploadId" => upload_id optional scalar,
    }];
    ["UploadPart" => upload_part] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_upload_id("UploadId", string);
        set_part_number("PartNumber", integer);
        set_content_md5("ContentMD5", string);
        set_checksum_algorithm("ChecksumAlgorithm", enumeration);
    } [body, customer] [];
    ["UploadPartCopy" => upload_part_copy] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_upload_id("UploadId", string);
        set_part_number("PartNumber", integer);
        set_copy_source("CopySource", copy_source);
        set_copy_source_range("CopySourceRange", string);
    } [customer, source] [{
        "CopyPartResult" => copy_part_result optional project_copy_part_result,
    }];
    ["ListParts" => list_parts] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_upload_id("UploadId", string);
        set_max_parts("MaxParts", integer);
        set_part_number_marker("PartNumberMarker", part_number_marker);
    } [] [{
        "UploadId" => upload_id optional scalar,
        "PartNumberMarker" => part_number_marker optional scalar,
        "NextPartNumberMarker" => next_part_number_marker optional scalar,
        "MaxParts" => max_parts optional scalar,
        "IsTruncated" => is_truncated optional scalar,
        "Parts" => parts optional items(project_part),
    }];
    ["ListMultipartUploads" => list_multipart_uploads] {
        set_bucket("Bucket", string);
        set_prefix("Prefix", string);
        set_key_marker("KeyMarker", string);
        set_upload_id_marker("UploadIdMarker", string);
        set_max_uploads("MaxUploads", integer);
    } [] [{
        "KeyMarker" => key_marker optional scalar,
        "UploadIdMarker" => upload_id_marker optional scalar,
        "NextKeyMarker" => next_key_marker optional scalar,
        "NextUploadIdMarker" => next_upload_id_marker optional scalar,
        "Prefix" => prefix optional scalar,
        "MaxUploads" => max_uploads optional scalar,
        "IsTruncated" => is_truncated optional scalar,
        "Uploads" => uploads optional items(project_multipart_upload),
    }];
    ["CompleteMultipartUpload" => complete_multipart_upload] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_upload_id("UploadId", string);
        set_multipart_upload("MultipartUpload", completed_multipart_upload);
    } [customer] [{
        "Location" => location optional scalar,
        "Bucket" => bucket optional scalar,
        "Key" => key optional scalar,
        "ETag" => e_tag optional scalar,
    }];
    ["AbortMultipartUpload" => abort_multipart_upload] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_upload_id("UploadId", string);
    } [] [];
    ["GetObjectRetention" => get_object_retention] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
    } [] [{
        "Retention" => retention optional project_object_lock_retention,
    }];
    ["GetObjectLegalHold" => get_object_legal_hold] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
    } [] [{
        "LegalHold" => legal_hold optional project_object_lock_legal_hold,
    }];
    ["PutObjectRetention" => put_object_retention] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_retention("Retention", object_lock_retention);
        set_bypass_governance_retention("BypassGovernanceRetention", boolean);
    } [] [];
    ["PutObjectLegalHold" => put_object_legal_hold] {
        set_bucket("Bucket", string);
        set_key("Key", string);
        set_version_id("VersionId", string);
        set_legal_hold("LegalHold", object_lock_legal_hold);
    } [] [];
}
