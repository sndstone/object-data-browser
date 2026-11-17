use super::*;
use aws_smithy_types::base64;
use md5::{Digest, Md5};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum Mode {
    #[default]
    BucketDefault,
    S3,
    Kms,
    Dsse,
    Customer,
    AzureScope,
    AzureCustomer,
}

#[derive(Clone, Default)]
pub(super) struct Encryption {
    pub mode: Mode,
    pub kms_key_id: Option<String>,
    pub context: Option<String>,
    pub bucket_key: Option<bool>,
    pub customer_key: Option<String>,
    pub customer_md5: Option<String>,
}

impl Encryption {
    pub fn parse(value: &Value, profile: &Value, source: bool) -> Result<Self, SidecarError> {
        let invalid =
            || SidecarError::new("invalid_config", "Invalid object encryption configuration.");
        let mut result = Self {
            mode: Mode::BucketDefault,
            kms_key_id: None,
            context: None,
            bucket_key: None,
            customer_key: None,
            customer_md5: None,
        };
        if value.is_null() {
            return Ok(result);
        }
        let fields = value.as_object().ok_or_else(invalid)?;
        let mode = fields
            .get("mode")
            .and_then(Value::as_str)
            .ok_or_else(invalid)?;
        result.mode = match mode {
            "bucketDefault" => Mode::BucketDefault,
            "sse-s3" => Mode::S3,
            "sse-kms" => Mode::Kms,
            "dsse-kms" => Mode::Dsse,
            "sse-c" => Mode::Customer,
            "azure-scope" => Mode::AzureScope,
            "azure-cpk" => Mode::AzureCustomer,
            _ => return Err(invalid()),
        };
        let provider = profile["endpointType"]
            .as_str()
            .unwrap_or("s3Compatible")
            .trim();
        let azure = matches!(result.mode, Mode::AzureScope | Mode::AzureCustomer);
        if result.mode != Mode::BucketDefault
            && (if azure {
                provider != "azureBlob"
            } else {
                !matches!(provider, "awsS3" | "s3Compatible")
            })
        {
            return Err(invalid());
        }
        if source
            && !matches!(
                result.mode,
                Mode::Customer | Mode::AzureCustomer | Mode::BucketDefault
            )
        {
            return Err(invalid());
        }
        for (name, value) in fields {
            match name.as_str() {
                "mode" => {}
                "kmsKeyId" if matches!(result.mode, Mode::Kms | Mode::Dsse) => {
                    result.kms_key_id = Some(value.as_str().ok_or_else(invalid)?.to_owned());
                }
                "kmsEncryptionContext" if matches!(result.mode, Mode::Kms | Mode::Dsse) => {
                    let map = value.as_object().ok_or_else(invalid)?;
                    if map.values().any(|value| !value.is_string()) {
                        return Err(invalid());
                    }
                    result.context = Some(base64::encode(
                        serde_json::to_vec(map).map_err(|_| invalid())?,
                    ));
                }
                "bucketKeyEnabled" if result.mode == Mode::Kms => {
                    result.bucket_key = Some(value.as_bool().ok_or_else(invalid)?);
                }
                "customerKey" if matches!(result.mode, Mode::Customer | Mode::AzureCustomer) => {
                    let key = value.as_str().ok_or_else(invalid)?;
                    let decoded = base64::decode(key).map_err(|_| invalid())?;
                    if decoded.len() != 32 {
                        return Err(invalid());
                    }
                    result.customer_key = Some(key.to_owned());
                    result.customer_md5 = Some(base64::encode(Md5::digest(&decoded)));
                }
                "encryptionScope" if result.mode == Mode::AzureScope => {
                    if value.as_str().filter(|scope| !scope.is_empty()).is_none() {
                        return Err(invalid());
                    }
                }
                _ => return Err(invalid()),
            }
        }
        if result.mode == Mode::AzureScope && !fields.contains_key("encryptionScope") {
            return Err(invalid());
        }
        if matches!(result.mode, Mode::Customer | Mode::AzureCustomer) {
            if result.customer_key.is_none() {
                return Err(invalid());
            }
            let endpoint = url::Url::parse(profile["endpointUrl"].as_str().unwrap_or(""))
                .map_err(|_| invalid())?;
            let loopback = match endpoint.host() {
                Some(url::Host::Domain(host)) => host.eq_ignore_ascii_case("localhost"),
                Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
                Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
                _ => false,
            };
            if endpoint.scheme() != "https" && !(endpoint.scheme() == "http" && loopback) {
                return Err(SidecarError::new(
                    "invalid_config",
                    "Customer-provided object encryption requires HTTPS (or a loopback endpoint).",
                ));
            }
        }
        if azure {
            return Err(SidecarError::new(
                "unsupported_feature",
                "The Rust engine does not support Azure Blob encryption.",
            ));
        }
        Ok(result)
    }
    pub fn customer(&self) -> bool {
        self.mode == Mode::Customer
    }
}

// Leave builders untouched in the default case, including optional SDK fields.
macro_rules! encryption_customer {
    ($request:expr, $encryption:expr) => {{
        let e = &$encryption;
        let mut request = $request;
        if e.customer() {
            request = request
                .sse_customer_algorithm("AES256")
                .set_sse_customer_key(e.customer_key.clone())
                .set_sse_customer_key_md5(e.customer_md5.clone());
        }
        request
    }};
}
macro_rules! encryption_write {
    ($request:expr, $encryption:expr) => {{
        let e = &$encryption;
        let mut request = encryption_customer!($request, e);
        if let Some(algorithm) = match e.mode {
            object_encryption::Mode::S3 => Some("AES256"),
            object_encryption::Mode::Kms => Some("aws:kms"),
            object_encryption::Mode::Dsse => Some("aws:kms:dsse"),
            _ => None,
        } {
            request = request
                .server_side_encryption(ServerSideEncryption::from(algorithm))
                .set_ssekms_key_id(e.kms_key_id.clone())
                .set_ssekms_encryption_context(e.context.clone())
                .set_bucket_key_enabled(e.bucket_key);
        }
        request
    }};
}
macro_rules! encryption_source {
    ($request:expr, $encryption:expr) => {{
        let e = &$encryption;
        let mut request = $request;
        if e.customer() {
            request = request
                .copy_source_sse_customer_algorithm("AES256")
                .set_copy_source_sse_customer_key(e.customer_key.clone())
                .set_copy_source_sse_customer_key_md5(e.customer_md5.clone());
        }
        request
    }};
}

pub(super) fn reported(
    head: &aws_sdk_s3::operation::head_object::HeadObjectOutput,
) -> Option<Value> {
    let mode = if head.sse_customer_algorithm().is_some() {
        "sse-c"
    } else {
        match head.server_side_encryption()?.as_str() {
            "AES256" => "sse-s3",
            "aws:kms" => "sse-kms",
            "aws:kms:dsse" => "dsse-kms",
            _ => return None,
        }
    };
    let mut result = json!({"mode":mode});
    if let Some(value) = head.ssekms_key_id() {
        result["kmsKeyId"] = json!(value);
    }
    if let Some(value) = head.bucket_key_enabled() {
        result["bucketKeyEnabled"] = json!(value);
    }
    if let Some(value) = head.sse_customer_key_md5() {
        result["customerKeyMd5"] = json!(value);
    }
    Some(result)
}

pub(super) fn hint(code: &str, message: &str) -> Option<&'static str> {
    let text = format!("{code} {message}").to_ascii_lowercase();
    if text.contains("kms.") || text.contains("kms:") {
        if text.contains("accessdenied")
            || text.contains("access denied")
            || text.contains("not authorized")
        {
            return Some("kms_access_denied");
        }
        if text.contains("disabled")
            || text.contains("notfound")
            || text.contains("unavailable")
            || text.contains("invalidstate")
        {
            return Some("kms_key_unavailable");
        }
    }
    let customer =
        text.contains("sse-c") || text.contains("customer") || text.contains("encryption-c");
    if customer {
        if text.contains("block") && text.contains("accessdenied") {
            return Some("sse_c_blocked");
        }
        if text.contains("mismatch") || text.contains("does not match") {
            return Some("sse_c_key_mismatch");
        }
        if text.contains("required") || text.contains("must provide") || text.contains("missing") {
            return Some("sse_c_key_required");
        }
    }
    if text.contains("encryption") && text.contains("required") && text.contains("policy") {
        return Some("encryption_required_by_policy");
    }
    if text.contains("encryption")
        && (text.contains("not supported") || text.contains("unsupported"))
    {
        return Some("unsupported_by_endpoint");
    }
    None
}

pub(super) fn read_error<E>(error: aws_sdk_s3::error::SdkError<E>, has_key: bool) -> SidecarError
where
    aws_sdk_s3::error::SdkError<E>: Into<aws_sdk_s3::Error>,
{
    let bad_request = error
        .raw_response()
        .is_some_and(|response| response.status().as_u16() == 400);
    let mut mapped = map_sdk_error(error);
    // HEAD often has no response body. Keep the existing error code and supply
    // only a best-effort diagnostic, without trying another encryption mode.
    let bare_error = matches!(
        mapped.details["awsCode"].as_str(),
        Some("Unknown" | "BadRequest" | "400")
    );
    if bad_request && bare_error && !has_key && mapped.details.get("encryptionHint").is_none() {
        mapped.details["encryptionHint"] = json!("sse_c_key_required");
    }
    mapped
}
