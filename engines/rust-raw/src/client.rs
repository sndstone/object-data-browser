use crate::benchmark_runtime::Metrics;
use crate::signing::{canonical_query, encode, header_value, Signer, EMPTY_SHA256};
use crate::source_snapshot::SourceSnapshot;
use crate::SidecarError;
use base64::{engine::general_purpose::STANDARD, Engine};
use bytes::{Bytes, BytesMut};
use chrono::Utc;
use http::{header, HeaderMap, Method, Request, StatusCode, Uri};
use http_body::{Body, Frame, SizeHint};
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Full};
use hyper::body::Incoming;
use hyper_rustls::{HttpsConnector, HttpsConnectorBuilder, MaybeHttpsStream};
use hyper_util::client::legacy::{connect::HttpConnector, Client as HttpClient};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use md5::Md5;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{
    ring::default_provider, verify_tls12_signature, verify_tls13_signature,
    WebPkiSupportedAlgorithms,
};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::Digest;
use std::collections::VecDeque;
use std::future::Future;
use std::io;
use std::net::IpAddr;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncSeekExt, ReadBuf};
use tokio::sync::{watch, OwnedSemaphorePermit, Semaphore};
use tower_service::Service;

const IO_CHUNK: usize = 256 * 1024;
const MAX_CONTROL_BYTES: usize = 16 * 1024 * 1024;
type BoxError = Box<dyn std::error::Error + Send + Sync>;
type RequestBody = UnsyncBoxBody<Bytes, SidecarError>;

#[derive(Clone, Copy)]
pub enum Retry {
    /// Use only for requests whose replay cannot introduce additional writes.
    Safe,
    /// Replay only when the service explicitly reports a pre-execution rejection.
    Rejected,
    Never,
}

#[derive(Clone)]
pub struct Client {
    endpoint: Endpoint,
    signer: Arc<Signer>,
    transport: Arc<Transport>,
    read_timeout: Duration,
    attempts: u64,
    requester_pays: bool,
    expected_owner: Option<String>,
    enable_api_logging: bool,
    metrics: Option<Arc<Metrics>>,
    pub region: String,
    pub max_connections: usize,
}

#[derive(Clone)]
struct Endpoint {
    scheme: String,
    host: String,
    port: Option<u16>,
    base: String,
    path_style: bool,
}

impl Endpoint {
    fn parse(text: &str, path_style: bool) -> Result<Self, SidecarError> {
        let invalid = || {
            SidecarError::new(
                "invalid_config",
                "Enter an HTTP(S) endpoint without user info, query or fragment.",
            )
        };
        let uri: Uri = text.parse().map_err(|_| invalid())?;
        let scheme = uri
            .scheme_str()
            .filter(|s| matches!(*s, "http" | "https"))
            .ok_or_else(invalid)?;
        let authority = uri
            .authority()
            .filter(|a| !a.as_str().contains('@'))
            .ok_or_else(invalid)?;
        if text.contains('#') || uri.query().is_some() {
            return Err(invalid());
        }
        let host = authority.host();
        let port = authority.port_u16();
        if port.is_none() && authority.as_str() != host {
            return Err(invalid());
        }
        let port = port.filter(|p| !matches!((scheme, *p), ("http", 80) | ("https", 443)));
        let base = uri
            .path()
            .strip_suffix('/')
            .unwrap_or(uri.path())
            .to_owned();
        Ok(Self {
            scheme: scheme.into(),
            host: host.to_ascii_lowercase(),
            port,
            base,
            path_style,
        })
    }

    fn target(
        &self,
        bucket: Option<&str>,
        key: Option<&str>,
    ) -> Result<(String, String), SidecarError> {
        if key.is_some_and(|key| key.is_empty() || key.len() > 1024) {
            return Err(SidecarError::new(
                "invalid_config",
                "An S3 object key must contain 1–1024 UTF-8 bytes.",
            ));
        }
        if bucket.is_some_and(|b| {
            b.is_empty()
                || !b
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b".-_$".contains(&byte))
                || matches!(b, "." | "..")
        }) {
            return Err(SidecarError::new(
                "invalid_config",
                "Enter a valid S3 bucket name.",
            ));
        }
        let dns_compatible = bucket.is_some_and(|name| {
            (3..=63).contains(&name.len())
                && name.parse::<IpAddr>().is_err()
                && name.split('.').all(|label| {
                    !label.is_empty()
                        && !label.starts_with('-')
                        && !label.ends_with('-')
                        && label
                            .bytes()
                            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                })
        });
        let virtual_host = !self.path_style
            && dns_compatible
            && self
                .host
                .trim_matches(['[', ']'])
                .parse::<IpAddr>()
                .is_err()
            && self.host != "localhost"
            && !(self.scheme == "https" && bucket.is_some_and(|name| name.contains('.')));
        let mut authority = if virtual_host {
            format!("{}.{host}", bucket.unwrap_or_default(), host = self.host)
        } else {
            self.host.clone()
        };
        if let Some(port) = self.port {
            authority.push_str(&format!(":{port}"));
        }
        let mut path = self.base.clone();
        path.push('/');
        if let Some(bucket) = bucket.filter(|_| !virtual_host) {
            path.push_str(&encode(bucket, false));
            if key.is_some() {
                path.push('/');
            }
        }
        if let Some(key) = key {
            path.push_str(&encode(key, true));
        }
        Ok((authority, path))
    }
}

#[derive(Clone, PartialEq, Eq)]
struct TransportOptions {
    verify_tls: bool,
    ca_bundle: Option<PathBuf>,
    connect_timeout: Duration,
    pool_size: usize,
}

struct Transport {
    client: HttpClient<Connector, RequestBody>,
    active: Arc<Semaphore>,
}

type TransportCache = Mutex<VecDeque<(TransportOptions, Arc<Transport>)>>;
static TRANSPORTS: OnceLock<TransportCache> = OnceLock::new();
static NATIVE_ROOTS: OnceLock<RootCertStore> = OnceLock::new();

fn transport(options: TransportOptions) -> Result<Arc<Transport>, SidecarError> {
    let cache = TRANSPORTS.get_or_init(Default::default);
    // A custom CA file can be replaced between requests. Reload it so a
    // removed trust root never survives in an idle connection pool.
    let cacheable = options.ca_bundle.is_none();
    if cacheable {
        let mut entries = cache.lock().unwrap();
        if let Some(index) = entries.iter().position(|(entry, _)| *entry == options) {
            let pair = entries.remove(index).unwrap();
            let pool = pair.1.clone();
            entries.push_front(pair);
            return Ok(pool);
        }
    }

    let provider = Arc::new(default_provider());
    let builder = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .map_err(|_| SidecarError::new("tls_error", "Could not initialize TLS."))?;
    let config = if options.verify_tls {
        let mut roots = NATIVE_ROOTS
            .get_or_init(|| {
                let mut native = RootCertStore::empty();
                native.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
                if native.is_empty() {
                    native.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
                }
                native
            })
            .clone();
        if let Some(path) = &options.ca_bundle {
            let file = std::fs::File::open(path).map_err(|_| {
                SidecarError::new("invalid_config", "Could not open the TLS CA bundle.")
            })?;
            let certificates = rustls_pemfile::certs(&mut io::BufReader::new(file))
                .collect::<Result<Vec<_>, _>>()
                .map_err(|_| {
                    SidecarError::new("invalid_config", "The TLS CA bundle is invalid.")
                })?;
            if roots.add_parsable_certificates(certificates).0 == 0 {
                return Err(SidecarError::new(
                    "invalid_config",
                    "The TLS CA bundle has no valid certificates.",
                ));
            }
        }
        builder.with_root_certificates(roots).with_no_client_auth()
    } else {
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification(
                provider.signature_verification_algorithms,
            )))
            .with_no_client_auth()
    };
    let mut http = HttpConnector::new();
    http.enforce_http(false);
    http.set_connect_timeout(Some(options.connect_timeout));
    http.set_nodelay(true);
    let https = HttpsConnectorBuilder::new()
        .with_tls_config(config)
        .https_or_http()
        .enable_http1()
        .wrap_connector(http);
    let connector = Connector {
        https,
        timeout: options.connect_timeout,
    };
    let client = HttpClient::builder(TokioExecutor::new())
        .pool_timer(TokioTimer::new())
        .pool_idle_timeout(Duration::from_secs(30))
        .pool_max_idle_per_host(options.pool_size)
        .retry_canceled_requests(false)
        .build(connector);
    let pool = Arc::new(Transport {
        client,
        active: Arc::new(Semaphore::new(options.pool_size)),
    });
    if cacheable {
        let mut entries = cache.lock().unwrap();
        if let Some((_, existing)) = entries.iter().find(|(entry, _)| *entry == options) {
            return Ok(existing.clone());
        }
        entries.push_front((options, pool.clone()));
        entries.truncate(8);
    }
    Ok(pool)
}

#[derive(Clone)]
struct Connector {
    https: HttpsConnector<HttpConnector>,
    timeout: Duration,
}

impl Service<Uri> for Connector {
    type Response = MaybeHttpsStream<TokioIo<tokio::net::TcpStream>>;
    type Error = BoxError;
    type Future = Pin<Box<dyn Future<Output = Result<Self::Response, Self::Error>> + Send>>;
    fn poll_ready(&mut self, cx: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
        self.https.poll_ready(cx)
    }
    fn call(&mut self, uri: Uri) -> Self::Future {
        let future = self.https.call(uri);
        let timeout = self.timeout;
        Box::pin(async move {
            tokio::time::timeout(timeout, future)
                .await
                .map_err(|_| -> BoxError {
                    Box::new(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "Connection setup timed out",
                    ))
                })?
        })
    }
}

#[derive(Debug)]
struct NoCertificateVerification(WebPkiSupportedAlgorithms);

impl ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(message, cert, signature, &self.0)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(message, cert, signature, &self.0)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.supported_schemes()
    }
}

impl Client {
    pub fn new(profile: &Value) -> Result<Self, SidecarError> {
        match profile["endpointType"].as_str().unwrap_or("s3Compatible") {
            "s3Compatible" | "awsS3" | "" => {}
            "azureBlob" | "googleCloudStorage" => {
                return Err(SidecarError::new(
                    "unsupported_feature",
                    "The raw Rust engine supports S3 endpoints.",
                ))
            }
            _ => {
                return Err(SidecarError::new(
                    "invalid_config",
                    "Unknown endpoint type.",
                ))
            }
        }
        if profile["authMode"].as_str().unwrap_or("static") != "static" {
            return Err(SidecarError::new("unsupported_feature", "The raw Rust engine requires an access key and secret key. Use an SDK engine for AWS credential providers."));
        }
        if !matches!(
            profile["signerOverride"].as_str(),
            None | Some("" | "default" | "auto" | "s3v4" | "sigv4" | "v4")
        ) {
            return Err(SidecarError::new(
                "unsupported_feature",
                "The raw Rust engine uses S3 Signature Version 4.",
            ));
        }
        let access = crate::required_text(profile, "accessKey", "An access key is required.")?;
        let secret = crate::required_text(profile, "secretKey", "A secret key is required.")?;
        if !access
            .bytes()
            .all(|byte| byte.is_ascii_graphic() && !b"/,=".contains(&byte))
        {
            return Err(SidecarError::new(
                "invalid_config",
                "Invalid access key format.",
            ));
        }
        let region = profile["region"]
            .as_str()
            .map(str::trim)
            .filter(|r| !r.is_empty())
            .unwrap_or("us-east-1")
            .to_owned();
        if !region
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err(SidecarError::new("invalid_config", "Invalid S3 region."));
        }
        let token = profile["sessionToken"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_owned);
        let endpoint = Endpoint::parse(
            profile["endpointUrl"].as_str().unwrap_or_default().trim(),
            profile["pathStyle"].as_bool().unwrap_or(false),
        )?;
        let max_connections = profile["maxPoolConnections"]
            .as_u64()
            .or_else(|| profile["maxConcurrentRequests"].as_u64())
            .unwrap_or(10)
            .clamp(1, 128) as usize;
        let transport = transport(TransportOptions {
            verify_tls: profile["verifyTls"].as_bool().unwrap_or(true),
            ca_bundle: profile["caBundlePath"]
                .as_str()
                .filter(|p| !p.is_empty())
                .map(PathBuf::from),
            connect_timeout: Duration::from_secs(
                profile["connectTimeoutSeconds"]
                    .as_u64()
                    .unwrap_or(5)
                    .clamp(1, 600),
            ),
            pool_size: max_connections,
        })?;
        Ok(Self {
            endpoint,
            transport,
            max_connections,
            signer: Arc::new(Signer::new(access, secret, token, region.clone())),
            region,
            read_timeout: Duration::from_secs(
                profile["readTimeoutSeconds"]
                    .as_u64()
                    .unwrap_or(60)
                    .clamp(1, 3600),
            ),
            attempts: profile["maxAttempts"].as_u64().unwrap_or(5).clamp(1, 20),
            requester_pays: profile["requesterPays"].as_bool().unwrap_or(false),
            expected_owner: profile["expectedBucketOwner"]
                .as_str()
                .filter(|owner| !owner.is_empty())
                .map(str::to_owned),
            enable_api_logging: profile["diagnostics"]["enableApiLogging"] == true,
            metrics: None,
        })
    }

    pub fn with_metrics(mut self, metrics: Arc<Metrics>) -> Self {
        self.metrics = Some(metrics);
        self
    }

    pub fn presign(
        &self,
        bucket: &str,
        key: &str,
        version: Option<&str>,
        expiration: u64,
    ) -> Result<String, SidecarError> {
        let (host, path) = self.endpoint.target(Some(bucket), Some(key))?;
        let mut query = Vec::new();
        if let Some(version) = version {
            query.push(("versionId", version));
        }
        if self.requester_pays {
            query.push(("x-amz-request-payer", "requester"));
        }
        if let Some(owner) = self.expected_owner.as_deref() {
            query.push(("x-amz-expected-bucket-owner", owner));
        }
        let query = self.signer.presign(
            &host,
            &path,
            &query,
            expiration.clamp(1, 604800),
            Utc::now(),
        );
        Ok(format!("{}://{host}{path}?{query}", self.endpoint.scheme))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn send(
        &self,
        method: Method,
        bucket: Option<&str>,
        key: Option<&str>,
        query: &[(&str, &str)],
        mut headers: HeaderMap,
        payload: Payload,
        retry: Retry,
    ) -> Result<Response, SidecarError> {
        let (authority, path) = self.endpoint.target(bucket, key)?;
        let query = canonical_query(query);
        let target = if query.is_empty() {
            path.clone()
        } else {
            format!("{path}?{query}")
        };
        let uri = Uri::builder()
            .scheme(self.endpoint.scheme.as_str())
            .authority(authority.as_str())
            .path_and_query(target)
            .build()
            .map_err(|_| SidecarError::new("invalid_config", "Invalid S3 request URI."))?;
        headers.insert(header::HOST, header_value(&authority)?);
        if bucket.is_some() {
            if self.requester_pays {
                headers.insert("x-amz-request-payer", header_value("requester")?);
            }
            if let Some(owner) = self.expected_owner.as_deref() {
                headers.insert("x-amz-expected-bucket-owner", header_value(owner)?);
            }
        }

        let prepared = payload.prepare().await?;
        if matches!(method, Method::PUT | Method::POST) {
            headers.insert(
                header::CONTENT_LENGTH,
                header_value(&prepared.len.to_string())?,
            );
        }
        if let Some(md5) = &prepared.md5 {
            headers.entry("content-md5").or_insert(header_value(md5)?);
        }
        let attempts = if matches!(retry, Retry::Never) {
            1
        } else {
            self.attempts
        };
        for attempt in 1..=attempts {
            let result = self
                .send_once(
                    &method,
                    &path,
                    &query,
                    uri.clone(),
                    headers.clone(),
                    &prepared,
                )
                .await;
            match result {
                Err(error) if attempt < attempts && retryable(retry, &error) => {
                    if let Some(metrics) = &self.metrics {
                        metrics.retries.fetch_add(1, Ordering::Relaxed);
                    }
                    let base = 25_u64 << attempt.min(7);
                    let jitter = u64::from(UuidFragment::random()) % base;
                    tokio::time::sleep(Duration::from_millis(base + jitter)).await;
                }
                Err(error) => {
                    if let Some(metrics) = &self.metrics {
                        metrics.errors.fetch_add(1, Ordering::Relaxed);
                    }
                    return Err(error);
                }
                Ok(response) => return Ok(response),
            }
        }
        unreachable!("at least one HTTP attempt")
    }

    #[allow(clippy::too_many_arguments)]
    async fn send_once(
        &self,
        method: &Method,
        path: &str,
        query: &str,
        uri: Uri,
        mut headers: HeaderMap,
        payload: &Prepared,
    ) -> Result<Response, SidecarError> {
        let permit = self
            .transport
            .active
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| SidecarError::new("engine_unavailable", "HTTP pool is closed."))?;
        self.signer.sign(
            method,
            path,
            query,
            &mut headers,
            &payload.sha256,
            Utc::now(),
        )?;
        let authorization = headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok());
        let signature =
            authorization.and_then(|a| a.rsplit_once("Signature=").map(|(_, s)| s.to_owned()));
        let (activity, mut progress) = watch::channel(());
        let (body, sent) = payload.body(activity.clone()).await?;
        let started = std::time::Instant::now();
        if self.enable_api_logging {
            let query_names: Vec<_> = query
                .split('&')
                .filter_map(|pair| pair.split_once('=').map(|(key, _)| key))
                .collect();
            crate::emit_structured_log(
                "API",
                "HttpSend",
                format!(
                    "SEND {method} {path} query names [{}], {} body byte(s).",
                    query_names.join(", "),
                    payload.len
                ),
                "api",
            );
        }
        let mut request = Request::new(body);
        *request.method_mut() = method.clone();
        *request.uri_mut() = uri;
        *request.headers_mut() = headers;

        let request = self.transport.client.request(request);
        tokio::pin!(request);
        let timer = tokio::time::sleep(self.read_timeout);
        tokio::pin!(timer);
        let incoming = loop {
            tokio::select! {
                biased;
                response = &mut request => break response.map_err(network_error)?,
                Ok(()) = progress.changed() => timer.as_mut().reset(tokio::time::Instant::now() + self.read_timeout),
                () = &mut timer => return Err(SidecarError::new("timeout", "Timed out waiting for the S3 response.")),
            }
        };

        let (head, body) = incoming.into_parts();
        if self.enable_api_logging {
            crate::emit_structured_log(
                "API",
                "HttpReceive",
                format!(
                    "RECV HTTP {} after {:.1} ms.",
                    head.status.as_u16(),
                    started.elapsed().as_secs_f64() * 1_000.0
                ),
                "api",
            );
        }
        let mut response = Response {
            status: head.status,
            headers: head.headers,
            body,
            read_timeout: self.read_timeout,
            _permit: permit,
            signature,
            metrics: self.metrics.clone(),
        };
        if response.status.is_success() {
            if sent.is_some_and(|sent| !sent.load(Ordering::Acquire)) {
                return Err(SidecarError::new(
                    "invalid_response",
                    "S3 responded before it consumed the complete upload body.",
                ));
            }
            return Ok(response);
        }
        // Keep the HTTP status if an upstream proxy returns HTML, or if an
        // error body is incomplete. Never expose unparsed upstream content.
        let body = response.collect_control().await.unwrap_or_default();
        Err(response.service_error(&body))
    }
}

struct UuidFragment;

impl UuidFragment {
    fn random() -> u16 {
        let id = uuid::Uuid::new_v4();
        u16::from_ne_bytes([id.as_bytes()[0], id.as_bytes()[1]])
    }
}

fn network_error(error: hyper_util::client::legacy::Error) -> SidecarError {
    let mut current: Option<&(dyn std::error::Error + 'static)> = Some(&error);
    while let Some(cause) = current {
        if let Some(local) = cause.downcast_ref::<SidecarError>() {
            return local.clone();
        }
        if cause.is::<rustls::Error>() {
            return SidecarError::new("tls_error", "S3 TLS verification or handshake failed.");
        }
        if let Some(io_error) = cause.downcast_ref::<io::Error>() {
            if io_error.kind() == io::ErrorKind::TimedOut {
                return SidecarError::with_details(
                    "timeout",
                    "Timed out connecting to the S3 endpoint.",
                    json!({"beforeSend":error.is_connect()}),
                );
            }
            if let Some(inner) = io_error.get_ref() {
                current = Some(inner);
                continue;
            }
        }
        current = cause.source();
    }
    SidecarError::with_details(
        "engine_unavailable",
        if error.is_connect() {
            "Could not connect to the S3 endpoint."
        } else {
            "The S3 HTTP request was interrupted."
        },
        json!({"beforeSend":error.is_connect()}),
    )
}

fn retryable(retry: Retry, error: &SidecarError) -> bool {
    if matches!(retry, Retry::Rejected) {
        return error.details["beforeSend"] == true
            || matches!(
                error.details["awsCode"].as_str(),
                Some("SlowDown" | "Throttling" | "ThrottlingException")
            );
    }
    is_transient(error)
}

pub fn is_transient(error: &SidecarError) -> bool {
    let status = error.details["statusCode"].as_u64();
    matches!(status, Some(408 | 429 | 500 | 502 | 503 | 504))
        || matches!(
            error.details["awsCode"].as_str(),
            Some("SlowDown" | "InternalError" | "RequestTimeout" | "ServiceUnavailable")
        )
        || (status.is_none() && matches!(error.code, "timeout" | "engine_unavailable"))
}

type UploadActivity = Arc<dyn Fn() + Send + Sync>;

pub enum Payload {
    Empty,
    Bytes(Bytes),
    File {
        path: PathBuf,
        offset: u64,
        len: u64,
        snapshot: Option<SourceSnapshot>,
        activity: Option<UploadActivity>,
    },
}

impl Payload {
    pub fn file(path: PathBuf, offset: u64, len: u64, snapshot: Option<SourceSnapshot>) -> Self {
        Self::File {
            path,
            offset,
            len,
            snapshot,
            activity: None,
        }
    }

    pub fn on_upload_activity(mut self, callback: UploadActivity) -> Self {
        if let Self::File { activity, .. } = &mut self {
            *activity = Some(callback);
        }
        self
    }

    async fn prepare(self) -> Result<Prepared, SidecarError> {
        let (len, sha256, md5) = match &self {
            Self::Empty => (0, EMPTY_SHA256.to_owned(), None),
            Self::Bytes(bytes) => (
                bytes.len() as u64,
                hex::encode(ring::digest::digest(&ring::digest::SHA256, bytes)),
                None,
            ),
            Self::File {
                path,
                offset,
                len,
                snapshot,
                activity,
            } => {
                if let Some(snapshot) = snapshot {
                    snapshot.check(path)?;
                }
                let mut file = open_slice(path, *offset).await?;
                let mut remaining = *len;
                let mut buffer = vec![0; (*len).min(IO_CHUNK as u64) as usize];
                let mut sha = ring::digest::Context::new(&ring::digest::SHA256);
                let mut md5 = Md5::new();
                while remaining > 0 {
                    let count = remaining.min(buffer.len() as u64) as usize;
                    file.read_exact(&mut buffer[..count])
                        .await
                        .map_err(source_error)?;
                    sha.update(&buffer[..count]);
                    md5.update(&buffer[..count]);
                    remaining -= count as u64;
                    if let Some(activity) = activity {
                        activity();
                    }
                }
                if let Some(snapshot) = snapshot {
                    snapshot.check(path)?;
                }
                (
                    *len,
                    hex::encode(sha.finish()),
                    Some(STANDARD.encode(md5.finalize())),
                )
            }
        };
        Ok(Prepared {
            input: self,
            len,
            sha256,
            md5,
        })
    }
}

struct Prepared {
    input: Payload,
    len: u64,
    sha256: String,
    md5: Option<String>,
}

impl Prepared {
    async fn body(
        &self,
        activity: watch::Sender<()>,
    ) -> Result<(RequestBody, Option<Arc<AtomicBool>>), SidecarError> {
        let bytes = match &self.input {
            Payload::Empty => Bytes::new(),
            Payload::Bytes(bytes) => bytes.clone(),
            Payload::File {
                path,
                offset,
                len,
                snapshot,
                activity: on_activity,
            } => {
                let file = open_slice(path, *offset).await?;
                if let Some(snapshot) = snapshot {
                    snapshot.check(path)?;
                }
                let sent = Arc::new(AtomicBool::new(*len == 0));
                let body = FileBody {
                    file,
                    path: path.clone(),
                    snapshot: snapshot.clone(),
                    remaining: *len,
                    chunk: vec![0; (*len).min(IO_CHUNK as u64) as usize],
                    activity,
                    on_activity: on_activity.clone(),
                    checksum: Some(ring::digest::Context::new(&ring::digest::SHA256)),
                    expected_sha256: self.sha256.clone(),
                    sent: sent.clone(),
                }
                .boxed_unsync();
                return Ok((body, Some(sent)));
            }
        };
        Ok((
            Full::new(bytes)
                .map_err(|never| match never {})
                .boxed_unsync(),
            None,
        ))
    }
}

async fn open_slice(path: &std::path::Path, offset: u64) -> Result<tokio::fs::File, SidecarError> {
    let mut file = tokio::fs::File::open(path).await.map_err(source_error)?;
    if offset != 0 {
        file.seek(io::SeekFrom::Start(offset))
            .await
            .map_err(source_error)?;
    }
    Ok(file)
}

fn source_error(_: io::Error) -> SidecarError {
    SidecarError::new(
        "object_conflict",
        "The local upload source could not be read in full.",
    )
}

struct FileBody {
    file: tokio::fs::File,
    path: PathBuf,
    snapshot: Option<SourceSnapshot>,
    remaining: u64,
    chunk: Vec<u8>,
    activity: watch::Sender<()>,
    on_activity: Option<UploadActivity>,
    checksum: Option<ring::digest::Context>,
    expected_sha256: String,
    sent: Arc<AtomicBool>,
}

impl Body for FileBody {
    type Data = Bytes;
    type Error = SidecarError;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, SidecarError>>> {
        let this = &mut *self;
        if this.remaining == 0 {
            return Poll::Ready(None);
        }
        let count = this.remaining.min(this.chunk.len() as u64) as usize;
        let mut buffer = ReadBuf::new(&mut this.chunk[..count]);
        match Pin::new(&mut this.file).poll_read(cx, &mut buffer) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(Err(error)) => return Poll::Ready(Some(Err(source_error(error)))),
            Poll::Ready(Ok(())) => {}
        }
        let bytes = buffer.filled();
        if bytes.is_empty() {
            return Poll::Ready(Some(Err(SidecarError::new(
                "object_conflict",
                "The upload source ended before its declared size.",
            ))));
        }
        this.remaining -= bytes.len() as u64;
        this.checksum
            .as_mut()
            .expect("nonempty body has a checksum")
            .update(bytes);
        if this.remaining == 0 {
            if let Some(snapshot) = &this.snapshot {
                if let Err(error) = snapshot.check(&this.path) {
                    return Poll::Ready(Some(Err(error)));
                }
            }
            if hex::encode(this.checksum.take().expect("final upload chunk").finish())
                != this.expected_sha256
            {
                return Poll::Ready(Some(Err(SidecarError::new(
                    "object_conflict",
                    "The upload source changed after request signing.",
                ))));
            }
            this.sent.store(true, Ordering::Release);
        }
        this.activity.send_replace(());
        if let Some(activity) = &this.on_activity {
            activity();
        }
        Poll::Ready(Some(Ok(Frame::data(Bytes::copy_from_slice(bytes)))))
    }

    fn is_end_stream(&self) -> bool {
        self.remaining == 0
    }
    fn size_hint(&self) -> SizeHint {
        SizeHint::with_exact(self.remaining)
    }
}

pub struct Response {
    pub status: StatusCode,
    pub headers: HeaderMap,
    body: Incoming,
    read_timeout: Duration,
    _permit: OwnedSemaphorePermit,
    signature: Option<String>,
    metrics: Option<Arc<Metrics>>,
}

impl Response {
    pub async fn next_chunk(&mut self) -> Result<Option<Bytes>, SidecarError> {
        loop {
            let frame = tokio::time::timeout(self.read_timeout, self.body.frame())
                .await
                .map_err(|_| {
                    SidecarError::new("timeout", "Timed out reading the S3 response body.")
                })?
                .transpose()
                .map_err(|_| {
                    SidecarError::new(
                        "engine_unavailable",
                        "The S3 response body was interrupted.",
                    )
                })?;
            match frame {
                Some(frame) => {
                    if let Ok(data) = frame.into_data() {
                        return Ok(Some(data));
                    }
                }
                None => return Ok(None),
            }
        }
    }

    async fn collect_control(&mut self) -> Result<Bytes, SidecarError> {
        let mut buffer = BytesMut::new();
        while let Some(chunk) = self.next_chunk().await? {
            if chunk.len() > MAX_CONTROL_BYTES - buffer.len() {
                return Err(SidecarError::new(
                    "invalid_response",
                    "The S3 control response exceeded the 16 MiB limit.",
                ));
            }
            buffer.extend_from_slice(&chunk);
        }
        Ok(buffer.freeze())
    }

    pub async fn bytes(mut self) -> Result<Bytes, SidecarError> {
        let result = match self.collect_control().await {
            Ok(bytes) if parse_service_error(&bytes).is_some() => Err(self.service_error(&bytes)),
            other => other,
        };
        if result.is_err() {
            if let Some(metrics) = &self.metrics {
                metrics.errors.fetch_add(1, Ordering::Relaxed);
            }
        }
        result
    }

    fn service_error(&self, body: &[u8]) -> SidecarError {
        let service = parse_service_error(body).unwrap_or_default();
        let status = self.status.as_u16();
        let aws_code = service.code.as_deref().filter(|code| {
            !code.is_empty()
                && code.len() <= 96
                && code.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        });
        let code = match (status, aws_code) {
            (_, Some("SlowDown" | "Throttling" | "ThrottlingException")) | (429, _) => "throttled",
            (_, Some("RequestTimeout" | "RequestTimeoutException")) | (408 | 504, _) => "timeout",
            (_, Some("NoSuchBucket" | "NoSuchKey" | "NoSuchVersion" | "NotFound")) | (404, _) => {
                "not_found"
            }
            (
                _,
                Some(
                    "InvalidAccessKeyId"
                    | "SignatureDoesNotMatch"
                    | "ExpiredToken"
                    | "InvalidToken"
                    | "TokenRefreshRequired"
                    | "AccessDenied",
                ),
            )
            | (401 | 403, _) => "auth_failed",
            (_, Some("PreconditionFailed" | "ConditionalRequestConflict")) | (412, _) => {
                "object_conflict"
            }
            (_, Some("BucketAlreadyExists" | "BucketAlreadyOwnedByYou" | "BucketNotEmpty"))
            | (409, _) => "conflict",
            (_, Some("NotImplemented" | "UnsupportedOperation")) | (501, _) => {
                "unsupported_feature"
            }
            (400, _) => "invalid_config",
            (_, Some("InternalError" | "ServiceUnavailable")) | (500..=599, _) => {
                "engine_unavailable"
            }
            _ => "unknown",
        };
        let message = if code == "auth_failed" {
            "S3 rejected the request credentials or permissions.".to_owned()
        } else if let Some(message) = service.message.filter(|message| !message.is_empty()) {
            let message: String = message.chars().take(1024).collect();
            self.signature
                .as_ref()
                .map_or(message.clone(), |signature| {
                    message.replace(signature, "[redacted]")
                })
        } else {
            format!("S3 returned HTTP {status}.")
        };
        SidecarError::with_details(
            code,
            message,
            json!({"awsCode":aws_code,"serviceCode":aws_code,"statusCode":status,"status":status,
            "deleteMarker":self.headers.get("x-amz-delete-marker").is_some_and(|value| value == "true")}),
        )
    }
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ServiceError {
    code: Option<String>,
    message: Option<String>,
}

fn parse_service_error(input: &[u8]) -> Option<ServiceError> {
    use quick_xml::{events::Event, Reader};
    let mut reader = Reader::from_reader(input);
    reader.config_mut().trim_text(true);
    loop {
        match reader.read_event().ok()? {
            Event::Start(element) | Event::Empty(element)
                if element.local_name().as_ref() == b"Error" =>
            {
                return Some(quick_xml::de::from_reader(input).unwrap_or_default());
            }
            Event::Start(_) | Event::Empty(_) | Event::Eof => return None,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;

    #[test]
    fn endpoints_preserve_the_wire_path_and_canonical_host() {
        let endpoint = Endpoint::parse("https://S3.Example:443/base//", false).unwrap();
        assert_eq!(
            endpoint
                .target(Some("bucket"), Some(" a//./../x+%雪 "))
                .unwrap(),
            (
                "bucket.s3.example".into(),
                "/base//%20a//./../x%2B%25%E9%9B%AA%20".into()
            )
        );
        let endpoint = Endpoint::parse("http://[::1]:80", true).unwrap();
        assert_eq!(
            endpoint.target(Some("bucket"), Some("//x")).unwrap(),
            ("[::1]".into(), "/bucket///x".into())
        );
        let endpoint = Endpoint::parse("http://s3.example:9299", true).unwrap();
        assert_eq!(
            endpoint.target(Some("bucket"), None).unwrap(),
            ("s3.example:9299".into(), "/bucket".into())
        );
        assert!(Endpoint::parse("http://user:secret@example.test", true).is_err());
        assert!(Endpoint::parse("http://example.test/#fragment", true).is_err());
        assert!(Endpoint::parse("http://example.test/?secret=x", true).is_err());
    }

    async fn request_head(stream: &mut BufReader<tokio::net::TcpStream>) -> String {
        let mut text = String::new();
        loop {
            let start = text.len();
            assert_ne!(stream.read_line(&mut text).await.unwrap(), 0);
            if &text[start..] == "\r\n" {
                return text;
            }
        }
    }

    fn profile(address: impl std::fmt::Display) -> Value {
        json!({"accessKey":"wire-access-sentinel","secretKey":"wire-secret-sentinel",
               "sessionToken":"temp+/=token-sentinel","pathStyle":true,
               "endpointUrl":format!("http://{address}"),"maxAttempts":2,"maxPoolConnections":1,
               "readTimeoutSeconds":2})
    }

    #[tokio::test]
    async fn sends_the_signed_target_exactly_and_reuses_http_connection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = BufReader::new(stream);
            for _ in 0..2 {
                let head = request_head(&mut stream).await;
                assert!(head.starts_with(
                    "GET /bucket/%20a//../%2B%25%E9%9B%AA?versionId=null&x=%20&x=%2B HTTP/1.1\r\n"
                ));
                assert!(head.contains(&format!("host: {addr}\r\n")));
                assert!(head.contains("x-amz-security-token: temp+/=token-sentinel\r\n"));
                assert!(head.contains(
                    "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
                ));
                assert!(!head.contains("x-amz-server-side-encryption"));
                stream
                    .get_mut()
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                    .await
                    .unwrap();
            }
        });
        for _ in 0..2 {
            let client = Client::new(&profile(addr)).unwrap();
            let body = client
                .send(
                    Method::GET,
                    Some("bucket"),
                    Some(" a//../+%雪"),
                    &[("x", "+"), ("versionId", "null"), ("x", " ")],
                    HeaderMap::new(),
                    Payload::Empty,
                    Retry::Safe,
                )
                .await
                .unwrap()
                .bytes()
                .await
                .unwrap();
            assert_eq!(body, "OK");
        }
        server.await.unwrap();
    }

    #[tokio::test]
    async fn distinguishes_rejections_from_ambiguous_mutations_and_redacts_errors() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            for (index, (status, body)) in [
                ("503 Service Unavailable", "<Error><Code>SlowDown</Code></Error>".to_owned()),
                ("200 OK", "<Status/>".to_owned()),
                ("503 Service Unavailable", "<Error><Code>InternalError</Code><Message>temp%2B%2F%3Dtoken-sentinel AUTH_SIG</Message></Error>".to_owned()),
            ].into_iter().enumerate() {
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = BufReader::new(stream);
                let head = request_head(&mut stream).await;
                let auth = head.lines().find(|line| line.starts_with("authorization:")).unwrap();
                let signature = auth.rsplit_once("Signature=").unwrap().1;
                assert_eq!(head.starts_with("PUT "), index == 2);
                let body = body.replace("AUTH_SIG", signature);
                stream.get_mut().write_all(format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
            }
        });
        let profile = profile(addr);
        let secrets = crate::secret_hygiene::collect(&profile);
        crate::secret_hygiene::SECRETS
            .scope(secrets, async {
                let client = Client::new(&profile).unwrap();
                let metrics = Arc::new(Metrics::default());
                let client = client.with_metrics(metrics.clone());
                client
                    .send(
                        Method::GET,
                        Some("bucket"),
                        Some("key"),
                        &[],
                        HeaderMap::new(),
                        Payload::Empty,
                        Retry::Safe,
                    )
                    .await
                    .unwrap()
                    .bytes()
                    .await
                    .unwrap();
                let start = Instant::now();
                let Err(error) = client
                    .send(
                        Method::PUT,
                        Some("bucket"),
                        Some("key"),
                        &[],
                        HeaderMap::new(),
                        Payload::Empty,
                        Retry::Rejected,
                    )
                    .await
                else {
                    panic!("ambiguous write was accepted")
                };
                assert_eq!(error.details["awsCode"], "InternalError");
                assert_eq!(error.message, "[redacted] [redacted]");
                assert!(start.elapsed() < Duration::from_secs(1));
                assert_eq!(metrics.retries.load(Ordering::Relaxed), 1);
                assert_eq!(metrics.errors.load(Ordering::Relaxed), 1);
            })
            .await;
        server.await.unwrap();
    }

    #[test]
    fn does_not_confuse_batch_failures_with_embedded_request_errors() {
        let body = br#" <s3:Error xmlns:s3="urn:s3"><s3:Code>SlowDown</s3:Code></s3:Error>"#;
        assert_eq!(
            parse_service_error(body).unwrap().code.as_deref(),
            Some("SlowDown")
        );
        assert!(parse_service_error(
            br#"<DeleteResult><Error><Code>AccessDenied</Code></Error></DeleteResult>"#
        )
        .is_none());
    }

    #[tokio::test]
    async fn streaming_refuses_bytes_that_differ_from_the_signed_file_slice() {
        let path = std::env::temp_dir().join(format!("odb-raw-payload-{}", uuid::Uuid::new_v4()));
        tokio::fs::write(&path, b"before").await.unwrap();
        let payload = Payload::file(path.clone(), 0, 6, None)
            .prepare()
            .await
            .unwrap();
        tokio::fs::write(&path, b"change").await.unwrap();
        let (activity, _receivers) = watch::channel(());
        let (body, sent) = payload.body(activity).await.unwrap();
        let result = body.collect().await;
        tokio::fs::remove_file(&path).await.unwrap();
        assert_eq!(result.unwrap_err().code, "object_conflict");
        assert!(!sent.unwrap().load(Ordering::Acquire));
    }
}
