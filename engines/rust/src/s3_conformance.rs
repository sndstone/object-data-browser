use super::*;
use aws_sdk_s3::config::interceptors::{
    BeforeDeserializationInterceptorContextRef, BeforeTransmitInterceptorContextRef,
};
use aws_sdk_s3::config::{RequestChecksumCalculation, ResponseChecksumValidation};
use aws_sdk_s3::error::SdkError;
use aws_smithy_http_client::{
    proxy::ProxyConfig,
    tls::{rustls_provider::CryptoMode, Provider, TlsContext, TrustStore},
    Connector,
};
use aws_smithy_runtime_api::client::{
    http::{http_client_fn, HttpConnector, HttpConnectorSettings, SharedHttpConnector},
    orchestrator::{HttpRequest, HttpResponse},
};
use aws_smithy_types::{base64, body::SdkBody};
use rustls::pki_types::{pem::PemObject, CertificateDer};
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;

#[path = "s3_conformance_ops.rs"]
mod ops;
#[cfg(test)]
#[path = "s3_conformance_tests.rs"]
mod tests;

const MIB: usize = 1024 * 1024;
const RESPONSE_LIMIT: usize = 32 * MIB;

type Input = Map<String, Value>;

fn is_s3_profile(profile: &Value) -> bool {
    matches!(
        profile["endpointType"].as_str().unwrap_or("").trim(),
        "" | "s3Compatible" | "awsS3"
    )
}

pub(super) fn capability(profile: &Value) -> Value {
    let mut item =
        json!({"key":"conformance.s3", "label":"S3 API conformance", "state":"unsupported"});
    if is_s3_profile(profile) {
        item["state"] = json!("supported");
        item["version"] = json!(1);
        item["sdk"] = json!(format!("aws-sdk-s3 {}", aws_sdk_s3::meta::PKG_VERSION));
        item["client"] = json!({
            "maxAttempts": 1,
            "requestChecksumCalculation": "when_required",
            "responseChecksumValidation": "when_required",
        });
        item["ops"] = json!(ops::OPERATIONS);
    }
    item
}

#[derive(Clone)]
struct ConformanceClient {
    sdk: Client,
    http: SharedHttpConnector,
    read_timeout: Duration,
}

#[derive(PartialEq, Eq)]
struct ClientKey {
    profile: Profile,
    ca_bundle: Option<(String, [u8; 32])>,
}

static CLIENTS: OnceLock<tokio::sync::Mutex<Vec<(ClientKey, ConformanceClient)>>> = OnceLock::new();

fn ca_tls_context(pem: Vec<u8>) -> Result<TlsContext, SidecarError> {
    let invalid = || {
        SidecarError::new(
            "invalid_config",
            "The configured CA bundle is not a valid PEM certificate bundle.",
        )
    };
    // Smithy's rustls provider panics on malformed PEM or unparseable DER.
    // Validate every certificate with the same parser before building it.
    let mut roots = rustls::RootCertStore::empty();
    for cert in CertificateDer::pem_slice_iter(&pem) {
        roots
            .add(cert.map_err(|_| invalid())?)
            .map_err(|_| invalid())?;
    }
    if roots.is_empty() {
        return Err(invalid());
    }
    TlsContext::builder()
        .with_trust_store(TrustStore::default().with_pem_certificate(pem))
        .build()
        .map_err(|_| invalid())
}

async fn client(
    profile: Profile,
    ca_bundle_path: Option<&str>,
) -> Result<ConformanceClient, SidecarError> {
    let https = profile
        .endpoint_url
        .split_once("://")
        .is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case("https"));
    if !profile.verify_tls && (https || ca_bundle_path.is_some()) {
        return Err(SidecarError::new(
            "unsupported_feature",
            "The Rust conformance client requires TLS certificate verification for HTTPS.",
        ));
    }
    // Re-read on each call so replacing or removing a bundle also affects cache hits.
    let (ca_bundle, pem) = if let Some(path) = ca_bundle_path {
        let bytes = tokio::fs::read(path).await.map_err(|_| {
            SidecarError::new(
                "invalid_config",
                "The configured CA bundle could not be read.",
            )
        })?;
        let digest = Sha256::digest(&bytes).into();
        (Some((path.to_owned(), digest)), Some(bytes))
    } else {
        (None, None)
    };
    let key = ClientKey { profile, ca_bundle };
    let mut clients = CLIENTS.get_or_init(Default::default).lock().await;
    if let Some((_, cached)) = clients.iter().find(|(cached_key, _)| cached_key == &key) {
        return Ok(cached.clone());
    }

    let profile = &key.profile;
    let tls_context = pem.map(ca_tls_context).transpose()?;
    let shared = load_profile_config(profile).await?;
    let timeout = profile_timeout_config(profile);
    let connector_settings = HttpConnectorSettings::builder()
        .connect_timeout(timeout.connect_timeout().expect("profile connect timeout"))
        .read_timeout(timeout.read_timeout().expect("profile read timeout"))
        .build();
    // Use the same Smithy HTTPS transport and trust roots as the SDK. The
    // connector sends raw HTTP without redirect or decompression middleware.
    let mut connector = Connector::builder()
        .connector_settings(connector_settings)
        .proxy_config(ProxyConfig::from_env())
        .tls_provider(Provider::Rustls(CryptoMode::AwsLc));
    if let Some(context) = tls_context {
        connector.set_tls_context(context);
    }
    connector.set_sleep_impl(shared.sleep_impl());
    let http = SharedHttpConnector::new(connector.build());
    let sdk_http = http.clone();
    let sdk = Client::from_conf(
        aws_sdk_s3::config::Builder::from(&shared)
            .endpoint_url(profile.endpoint_url.clone())
            .force_path_style(profile.path_style)
            .retry_config(RetryConfig::disabled())
            // Keep directory-bucket requests from implicitly calling CreateSession.
            .disable_s3_express_session_auth(true)
            .http_client(http_client_fn(move |_, _| sdk_http.clone()))
            .request_checksum_calculation(RequestChecksumCalculation::WhenRequired)
            .response_checksum_validation(ResponseChecksumValidation::WhenRequired)
            .timeout_config(timeout)
            .interceptor(ProfileHeaders {
                requester_pays: profile.requester_pays,
                expected_bucket_owner: profile.expected_bucket_owner.clone(),
            })
            .build(),
    );
    let result = ConformanceClient {
        sdk,
        http,
        read_timeout: Duration::from_secs(profile.read_timeout_seconds as u64),
    };
    if clients.len() >= 16 {
        clients.remove(0);
    }
    clients.push((key, result.clone()));
    Ok(result)
}

fn invalid_request(message: &'static str) -> SidecarError {
    SidecarError::new("invalid_request", message)
}

fn forbidden_sse_input(value: &Value) -> bool {
    match value {
        Value::Object(fields) => fields.iter().any(|(name, value)| {
            let name = name.to_ascii_lowercase();
            name.starts_with("ssecustomer")
                || name.starts_with("copysourcessecustomer")
                || forbidden_sse_input(value)
        }),
        Value::Array(items) => items.iter().any(forbidden_sse_input),
        _ => false,
    }
}

fn customer_encryption(
    value: &Value,
    profile: &Value,
    source: bool,
    supported: bool,
) -> Result<Encryption, SidecarError> {
    if !value.is_null() && (!supported || value["mode"] != "sse-c") {
        return Err(invalid_request(
            "Only SSE-C is accepted on operations that support it.",
        ));
    }
    Encryption::parse(value, profile, source)
}

fn request_body(value: Option<&Value>) -> Result<Bytes, SidecarError> {
    let Some(value) = value else {
        return Ok(Bytes::new());
    };
    let invalid = || invalid_request("Invalid S3 conformance body or body size exceeds its limit.");
    let fields = value
        .as_object()
        .filter(|v| v.len() == 1)
        .ok_or_else(invalid)?;
    if let Some(spec) = fields.get("generate") {
        let spec = spec
            .as_object()
            .filter(|v| v.len() == 2)
            .ok_or_else(invalid)?;
        let size = spec
            .get("size")
            .and_then(Value::as_u64)
            .filter(|&n| n <= (16 * MIB) as u64)
            .ok_or_else(invalid)?;
        let seed = spec
            .get("seed")
            .and_then(Value::as_u64)
            .filter(|&n| n <= 65535)
            .ok_or_else(invalid)?;
        let bytes: Vec<_> = (0..size)
            .map(|i| ((seed * 131 + i * 7 + (i >> 10)) & 0xff) as u8)
            .collect();
        return Ok(bytes.into());
    }
    if let Some(encoded) = fields.get("base64") {
        let text = encoded
            .as_str()
            .filter(|v| v.len() <= 4 * MIB.div_ceil(3))
            .ok_or_else(invalid)?;
        let bytes = base64::decode(text).map_err(|_| invalid())?;
        return (bytes.len() <= MIB)
            .then(|| bytes.into())
            .ok_or_else(invalid);
    }
    fields
        .get("text")
        .and_then(Value::as_str)
        .filter(|v| v.len() <= 64 * 1024)
        .map(|v| Bytes::copy_from_slice(v.as_bytes()))
        .ok_or_else(invalid)
}

pub(super) async fn run(params: Value) -> SidecarResult {
    let op = params["op"]
        .as_str()
        .ok_or_else(|| invalid_request("An operation name is required."))?;
    if !ops::OPERATIONS.contains(&op) {
        return Err(SidecarError::new(
            "unsupported_feature",
            "Unsupported S3 conformance operation.",
        ));
    }
    if !is_s3_profile(&params["profile"]) {
        return Err(SidecarError::new(
            "unsupported_feature",
            "S3 conformance requires an S3 profile.",
        ));
    }
    // The dedicated connector below validates TLS options for conformance.
    let profile = parse_profile_inner(&params["profile"], false)?;
    let ca_bundle_path = params["profile"]["caBundlePath"]
        .as_str()
        .filter(|path| !path.is_empty());
    let input = params["input"]
        .as_object()
        .ok_or_else(|| invalid_request("input must be an object."))?;
    if forbidden_sse_input(&params["input"]) {
        return Err(invalid_request(
            "Pass SSE-C keys via encryption or sourceEncryption.",
        ));
    }
    let encryption = customer_encryption(
        &params["encryption"],
        &params["profile"],
        false,
        matches!(
            op,
            "PutObject"
                | "GetObject"
                | "HeadObject"
                | "CopyObject"
                | "CreateMultipartUpload"
                | "UploadPart"
                | "UploadPartCopy"
                | "CompleteMultipartUpload"
                | "GetObjectAttributes"
        ),
    )?;
    let source_encryption = customer_encryption(
        &params["sourceEncryption"],
        &params["profile"],
        true,
        matches!(op, "CopyObject" | "UploadPartCopy"),
    )?;
    let body = params.get("body");
    let accepts_body = matches!(op, "PutObject" | "UploadPart")
        || (op == "PresignedRequest" && input.get("Method").and_then(Value::as_str) == Some("PUT"));
    if body.is_some() && !accepts_body {
        return Err(invalid_request("This operation does not accept a body."));
    }
    let body = request_body(body)?;
    let client = client(profile, ca_bundle_path).await?;
    let capture = Capture::default();
    let completion = if op == "PresignedRequest" {
        presign(&client, input, body, &capture).await?
    } else {
        match ops::run(
            &client,
            op,
            input,
            body,
            &encryption,
            &source_encryption,
            &capture,
        )
        .await
        {
            Ok(completion) => completion,
            Err(ops::InputError::Shape(error)) => return Err(error),
            Err(ops::InputError::Build) => Completion::new("sdk_validation", Instant::now())
                .message("The SDK rejected the input structure."),
        }
    };
    Ok(capture.finish(op, completion))
}

const HEADERS: &[&str] = &[
    "etag",
    "content-type",
    "content-length",
    "content-range",
    "content-encoding",
    "content-disposition",
    "content-language",
    "cache-control",
    "expires",
    "last-modified",
    "date",
    "accept-ranges",
    "location",
    "x-amz-request-id",
    "x-amz-version-id",
    "x-amz-delete-marker",
    "x-amz-tagging-count",
    "x-amz-mp-parts-count",
    "x-amz-storage-class",
    "x-amz-expiration",
    "x-amz-replication-status",
    "x-amz-copy-source-version-id",
    "x-amz-bucket-region",
    "x-amz-website-redirect-location",
    "x-amz-missing-meta",
    "x-amz-restore",
    "x-amz-abort-date",
    "x-amz-abort-rule-id",
    "x-amz-server-side-encryption",
    "x-amz-server-side-encryption-aws-kms-key-id",
    "x-amz-server-side-encryption-bucket-key-enabled",
    "x-amz-server-side-encryption-customer-algorithm",
    "x-amz-object-lock-mode",
    "x-amz-object-lock-retain-until-date",
    "x-amz-object-lock-legal-hold",
    "access-control-allow-origin",
    "access-control-allow-methods",
    "access-control-expose-headers",
];

#[derive(Default)]
struct Wire {
    attempts: usize,
    status: u16,
    headers: BTreeMap<String, String>,
    private: Vec<String>,
}

fn without_url_queries(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest
        .find("https://")
        .into_iter()
        .chain(rest.find("http://"))
        .min()
    {
        let (before, url) = rest.split_at(start);
        out.push_str(before);
        let end = url
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '<' | '>'))
            .unwrap_or(url.len());
        let (url, tail) = url.split_at(end);
        out.push_str(url.split_once('?').map_or(url, |(path, _)| path));
        rest = tail;
    }
    out.push_str(rest);
    out
}

impl Wire {
    fn remember(&mut self, value: &str) {
        if !value.is_empty() {
            self.private.push(value.to_owned());
        }
    }

    fn record_response(&mut self, response: &HttpResponse) {
        self.status = response.status().as_u16();
        self.headers.clear();
        let mut metadata = 0;
        for (name, value) in response.headers().iter() {
            let name = name.to_ascii_lowercase();
            let meta = name.starts_with("x-amz-meta-");
            if !(meta || name.starts_with("x-amz-checksum-") || HEADERS.contains(&name.as_str())) {
                continue;
            }
            if let Some(previous) = self.headers.get_mut(&name) {
                previous.push_str(", ");
                previous.push_str(value);
            } else if self.headers.len() < 48 && (!meta || metadata < 16) {
                self.headers.insert(name, value.to_owned());
                metadata += usize::from(meta);
            }
        }
    }

    fn redact(&self, value: &str) -> String {
        let value = self.private.iter().fold(value.to_owned(), |text, secret| {
            text.replace(secret, "[redacted]")
        });
        secret_hygiene::text(&value)
    }

    fn redact_diagnostic(&self, value: &str) -> String {
        without_url_queries(&self.redact(value))
    }

    fn redact_output(&self, value: &mut Value) {
        match value {
            Value::String(text) => *text = self.redact(text),
            Value::Object(fields) => fields.values_mut().for_each(|v| self.redact_output(v)),
            Value::Array(items) => items.iter_mut().for_each(|v| self.redact_output(v)),
            _ => {}
        }
    }
}

#[derive(Default, Clone)]
struct Capture(Arc<Mutex<Wire>>);

impl std::fmt::Debug for Capture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ConformanceCapture")
    }
}

impl Capture {
    fn finish(&self, op: &str, mut completion: Completion) -> Value {
        let wire = self.0.lock().unwrap();
        let headers: Map<_, _> = wire
            .headers
            .iter()
            .filter_map(|(name, value)| {
                if wire.redact(name) != *name {
                    return None;
                }
                let mut value = wire.redact_diagnostic(value);
                if matches!(
                    name.as_str(),
                    "location" | "x-amz-website-redirect-location"
                ) {
                    value.truncate(value.find('?').unwrap_or(value.len()));
                }
                Some((
                    name.clone(),
                    json!(value.chars().take(512).collect::<String>()),
                ))
            })
            .collect();
        let request_id = headers.get("x-amz-request-id");
        wire.redact_output(&mut completion.output);
        json!({
            "op": op,
            "outcome": completion.outcome,
            "httpStatus": wire.status,
            "errorCode": completion.code.map(|code| wire.redact_diagnostic(&code)),
            "errorMessage": completion.message.map(|message| wire.redact_diagnostic(&message).chars().take(256).collect::<String>()),
            "headers": headers,
            "output": completion.output,
            "latencyMs": completion.latency_ms,
            "attempts": wire.attempts,
            "requestId": request_id,
        })
    }
}

impl Intercept for Capture {
    fn name(&self) -> &'static str {
        "S3ConformanceCapture"
    }

    fn read_before_transmit(
        &self,
        context: &BeforeTransmitInterceptorContextRef<'_>,
        _: &RuntimeComponents,
        _: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        let mut wire = self.0.lock().unwrap();
        wire.attempts += 1;
        let request = context.request();
        if request.uri().contains('?') {
            wire.remember(request.uri());
        }
        let headers = request.headers();
        if let Some(auth) = headers.get("authorization") {
            wire.remember(auth);
            if let Some((_, signature)) = auth.rsplit_once("Signature=") {
                wire.remember(signature);
            }
        }
        for name in [
            "x-amz-security-token",
            "x-amz-server-side-encryption-customer-key",
            "x-amz-copy-source-server-side-encryption-customer-key",
            "x-amz-server-side-encryption-customer-key-md5",
            "x-amz-copy-source-server-side-encryption-customer-key-md5",
        ] {
            if let Some(secret) = headers.get(name) {
                wire.remember(secret);
                wire.remember(&urlencoding::encode(secret));
            }
        }
        Ok(())
    }

    fn read_after_transmit(
        &self,
        context: &BeforeDeserializationInterceptorContextRef<'_>,
        _: &RuntimeComponents,
        _: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        self.0.lock().unwrap().record_response(context.response());
        Ok(())
    }
}

struct Completion {
    outcome: &'static str,
    code: Option<String>,
    message: Option<String>,
    output: Value,
    latency_ms: f64,
}

fn elapsed_ms(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1000.0
}

impl Completion {
    fn new(outcome: &'static str, start: Instant) -> Self {
        Self {
            outcome,
            code: None,
            message: None,
            output: json!({}),
            latency_ms: elapsed_ms(start),
        }
    }

    fn message(mut self, message: &'static str) -> Self {
        self.message = Some(message.into());
        self
    }

    fn output(mut self, output: Value) -> Self {
        self.output = output;
        self
    }

    fn sdk_error<E: ProvideErrorMetadata + Error>(
        capture: &Capture,
        start: Instant,
        error: SdkError<E>,
    ) -> Self {
        if let Some(raw) = error.raw_response() {
            capture.0.lock().unwrap().record_response(raw);
        }
        match error {
            SdkError::ServiceError(context) => {
                // The Rust SDK wraps some generated deserialization failures
                // in a modeled operation error with no parsed S3 metadata.
                let error = context.err();
                if error.code().is_none()
                    && (context.raw().status().is_success()
                        || error.source().is_some_and(|source| {
                            source.is::<aws_smithy_xml::decode::XmlDecodeError>()
                        }))
                {
                    return Self::new("sdk_decode", start)
                        .message("The SDK could not decode the S3 response.");
                }
                let mut result = Self::new("service", start);
                result.code = context.err().code().map(str::to_owned);
                result.message = context.err().message().map(str::to_owned);
                result
            }
            SdkError::ResponseError(_) => {
                Self::new("sdk_decode", start).message("The SDK could not decode the S3 response.")
            }
            SdkError::ConstructionFailure(_) => Self::new("sdk_validation", start)
                .message("The SDK could not construct the S3 request."),
            SdkError::TimeoutError(_) => {
                Self::new("transport", start).message("The S3 request timed out.")
            }
            _ => Self::new("transport", start).message("The S3 HTTP request failed."),
        }
    }
}

#[derive(Debug)]
enum BodyFailure {
    Decode,
    Transport,
}

impl BodyFailure {
    fn from_read(error: io::Error) -> Self {
        use aws_smithy_checksums::body::validate::Error as ChecksumError;

        let mut cause: Option<&(dyn Error + 'static)> = error.get_ref().map(|error| error as _);
        while let Some(error) = cause {
            if error.is::<ChecksumError>() {
                return Self::Decode;
            }
            cause = error.source();
        }
        Self::Transport
    }

    fn complete(self, start: Instant) -> Completion {
        match self {
            Self::Decode => Completion::new("sdk_decode", start)
                .message("The SDK could not validate the S3 response body."),
            Self::Transport => {
                Completion::new("transport", start).message("Could not read the S3 response body.")
            }
        }
    }
}

async fn digest_body(body: ByteStream, read_timeout: Duration) -> Result<Value, BodyFailure> {
    consume_body(body, read_timeout, 0)
        .await
        .map(|(summary, _)| summary)
}

async fn consume_body(
    body: ByteStream,
    read_timeout: Duration,
    prefix_limit: usize,
) -> Result<(Value, Vec<u8>), BodyFailure> {
    let (_, upper) = body.size_hint();
    let mut body = body.into_async_read().take(RESPONSE_LIMIT as u64);
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 64 * 1024];
    let mut length = 0;
    let mut prefix = Vec::new();
    while body.limit() > 0 {
        let count = tokio::time::timeout(read_timeout, body.read(&mut buffer))
            .await
            .map_err(|_| BodyFailure::Transport)?
            .map_err(BodyFailure::from_read)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
        prefix.extend_from_slice(&buffer[..count.min(prefix_limit.saturating_sub(prefix.len()))]);
        length += count;
    }
    let mut summary = json!({"length":length, "sha256":format!("{:x}", hash.finalize())});
    // With unknown length, reaching the cap must end the read even if the
    // next chunk would be EOF.
    if length == RESPONSE_LIMIT && upper.is_none_or(|n| n > RESPONSE_LIMIT as u64) {
        summary["truncated"] = json!(true);
    }
    Ok((summary, prefix))
}

fn presigned_error(body: &[u8], completion: &mut Completion) {
    use aws_smithy_xml::decode::{try_data, Document};
    let Ok(mut document) = Document::try_from(body) else {
        return;
    };
    let Ok(mut root) = document.root_element() else {
        return;
    };
    if root.start_el().local() != "Error" {
        return;
    }
    while let Some(mut tag) = root.next_tag() {
        let target = match tag.start_el().local() {
            "Code" => &mut completion.code,
            "Message" => &mut completion.message,
            _ => continue,
        };
        if let Ok(value) = try_data(&mut tag) {
            *target = Some(value.into_owned());
        }
    }
}

async fn presign(
    client: &ConformanceClient,
    input: &Input,
    body: Bytes,
    capture: &Capture,
) -> Result<Completion, SidecarError> {
    let invalid = || invalid_request("Invalid presigned method, expiry, delay or input type.");
    let method = input
        .get("Method")
        .and_then(Value::as_str)
        .filter(|method| matches!(*method, "GET" | "PUT"))
        .ok_or_else(invalid)?;
    let expiry = input
        .get("ExpiresIn")
        .and_then(Value::as_u64)
        .filter(|v| (1..=3600).contains(v))
        .ok_or_else(invalid)?;
    let delay = input
        .get("DelayMs")
        .map_or(Some(0), Value::as_u64)
        .filter(|&v| v <= 5000)
        .ok_or_else(invalid)?;
    let config =
        PresigningConfig::expires_in(Duration::from_secs(expiry)).map_err(|_| invalid())?;
    let text = |name| ops::member(input, name, ops::string).map_err(|_| invalid());
    let bucket = text("Bucket")?;
    let key = text("Key")?;
    let version = text("VersionId")?;
    let content_type = text("ContentType")?;
    if (method == "GET" && content_type.is_some()) || (method == "PUT" && version.is_some()) {
        return Err(invalid());
    }

    let start = Instant::now();
    let signed = if method == "GET" {
        match client
            .sdk
            .get_object()
            .set_bucket(bucket)
            .set_key(key)
            .set_version_id(version)
            .presigned(config)
            .await
        {
            Ok(request) => request,
            Err(error) => return Ok(Completion::sdk_error(capture, start, error)),
        }
    } else {
        match client
            .sdk
            .put_object()
            .set_bucket(bucket)
            .set_key(key)
            .set_content_type(content_type)
            .presigned(config)
            .await
        {
            Ok(request) => request,
            Err(error) => return Ok(Completion::sdk_error(capture, start, error)),
        }
    };
    let presign_ms = elapsed_ms(start);
    let url = url::Url::parse(signed.uri()).map_err(|_| {
        SidecarError::new(
            "internal_error",
            "The SDK produced an invalid presigned URI.",
        )
    })?;
    let mut query_keys = Vec::new();
    let mut signed_headers = String::new();
    {
        let mut wire = capture.0.lock().unwrap();
        wire.remember(signed.uri());
        if let Some(query) = url.query() {
            wire.remember(query);
        }
        for (key, value) in url.query_pairs() {
            if key.eq_ignore_ascii_case("x-amz-signedheaders") {
                signed_headers = value.to_string();
            }
            if matches!(
                key.to_ascii_lowercase().as_str(),
                "x-amz-credential" | "x-amz-security-token" | "x-amz-signature"
            ) {
                wire.remember(&value);
                wire.remember(&urlencoding::encode(&value));
            }
            wire.remember(&format!("{key}={value}"));
            wire.remember(&format!("{key}={}", urlencoding::encode(&value)));
            query_keys.push(key.into_owned());
        }
    }
    query_keys.sort_unstable();
    query_keys.dedup();
    let mut output = json!({"Presign": {
        "Method": method, "Scheme": url.scheme(), "Host": &url[url::Position::BeforeHost..url::Position::AfterPort],
        "QueryKeys": query_keys, "PresignMs": presign_ms,
    }});
    let mut request = HttpRequest::try_from(signed.into_http_1x_request(SdkBody::from(body)))
        .map_err(|_| {
            SidecarError::new(
                "internal_error",
                "Could not prepare the presigned HTTP request.",
            )
        })?;
    let unsigned: Vec<_> = request
        .headers()
        .iter()
        .filter(|(name, _)| !signed_headers.split(';').any(|signed| signed == *name))
        .map(|(name, _)| name.to_owned())
        .collect();
    for name in unsigned {
        request.headers_mut().remove(name);
    }
    tokio::time::sleep(Duration::from_millis(delay)).await;
    // latencyMs covers the HTTP request only; PresignMs reports signing.
    let start = Instant::now();
    capture.0.lock().unwrap().attempts += 1;
    let response = match client.http.call(request).await {
        Ok(response) => response,
        Err(_) => {
            return Ok(Completion::new("transport", start)
                .message("The presigned HTTP request failed.")
                .output(output))
        }
    };
    capture.0.lock().unwrap().record_response(&response);
    let prefix_limit = if response.status().is_success() {
        0
    } else {
        64 * 1024
    };
    match consume_body(
        ByteStream::new(response.into_body()),
        client.read_timeout,
        prefix_limit,
    )
    .await
    {
        Ok((body, prefix)) => {
            output["Body"] = body;
            let mut completion = Completion::new("service", start).output(output);
            if prefix_limit != 0 {
                presigned_error(&prefix, &mut completion);
            }
            Ok(completion)
        }
        Err(error) => Ok(error.complete(start).output(output)),
    }
}
