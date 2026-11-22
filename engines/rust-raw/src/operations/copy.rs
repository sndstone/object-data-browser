//! Server-side copy and move.
//!
//! The source is pinned to the version and ETag read by HEAD. A move deletes
//! the source only after the destination has been confirmed, and only with a
//! safe condition: the exact selected version, or an `If-Match` delete on AWS.
//! Other endpoints keep the source and say so.

use super::*;
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use std::pin::Pin;
use std::task::Poll;

const MAX_SINGLE_COPY: u64 = 5 * 1024 * 1024 * 1024;
const MAX_PART: u64 = 5 * 1024 * 1024 * 1024;
const COPY_PART: u64 = 128 * 1024 * 1024;
const MAX_PARTS: u64 = 10_000;

/// Unreserved characters stay literal; `/` stays a separator. A literal `+`
/// is escaped so no endpoint can read it as a space.
const COPY_SOURCE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~')
    .remove(b'/');
const FORM_VALUE: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'~');

const CUSTOMER_PREFIX: &str = "x-amz-server-side-encryption-customer-";
const COPY_SOURCE_CUSTOMER_PREFIX: &str = "x-amz-copy-source-server-side-encryption-customer-";

pub(crate) fn copy_source(bucket: &str, key: &str, version: Option<&str>) -> String {
    let mut source = format!(
        "{}/{}",
        utf8_percent_encode(bucket, COPY_SOURCE),
        utf8_percent_encode(key, COPY_SOURCE)
    );
    if let Some(version) = version {
        source.push_str("?versionId=");
        source.extend(utf8_percent_encode(version, FORM_VALUE));
    }
    source
}

/// SSE-C headers only: these must accompany every request that touches the
/// destination object (UploadPartCopy, CompleteMultipartUpload, HEAD).
fn customer_headers(headers: &HeaderMap) -> HeaderMap {
    headers
        .iter()
        .filter(|(name, _)| name.as_str().starts_with(CUSTOMER_PREFIX))
        .map(|(name, value)| (name.clone(), value.clone()))
        .collect()
}

/// The source's SSE-C read headers, renamed for `x-amz-copy-source-*`.
fn copy_source_customer_headers(read: &HeaderMap) -> Result<HeaderMap, SidecarError> {
    let mut headers = HeaderMap::new();
    for (name, value) in read {
        if let Some(rest) = name.as_str().strip_prefix(CUSTOMER_PREFIX) {
            let renamed =
                HeaderName::from_bytes(format!("{COPY_SOURCE_CUSTOMER_PREFIX}{rest}").as_bytes())
                    .map_err(|_| invalid_config("Invalid source encryption header."))?;
            headers.insert(renamed, value.clone());
        }
    }
    Ok(headers)
}

fn has_server_side_encryption(headers: &HeaderMap) -> bool {
    headers
        .keys()
        .any(|name| name.as_str().starts_with("x-amz-server-side-encryption"))
}

fn tagging_header(tags: &[(String, String)]) -> String {
    tags.iter()
        .map(|(key, value)| {
            format!(
                "{}={}",
                utf8_percent_encode(key, FORM_VALUE),
                utf8_percent_encode(value, FORM_VALUE)
            )
        })
        .collect::<Vec<_>>()
        .join("&")
}

/// Content headers, metadata and storage class for a REPLACE copy, a multipart
/// copy or an empty conditional PUT: taken from the source HEAD, then overridden
/// by `options`. Without an explicit destination mode, a source SSE-S3/KMS
/// setting is inherited (SSE-C needs a key and is never inherited).
fn object_headers(
    head: &HeaderMap,
    options: &Value,
    write: &HeaderMap,
) -> Result<HeaderMap, SidecarError> {
    let mut headers = HeaderMap::new();
    for name in [
        "content-type",
        "cache-control",
        "content-disposition",
        "content-encoding",
        "content-language",
        "expires",
        "x-amz-website-redirect-location",
        "x-amz-storage-class",
    ] {
        if let Some(value) = head.get(name) {
            headers.insert(HeaderName::from_static(name), value.clone());
        }
    }
    if let Some(metadata) = options["metadata"].as_object() {
        for (field, value) in metadata {
            set_header(
                &mut headers,
                &format!("x-amz-meta-{}", field.to_ascii_lowercase()),
                value.as_str().unwrap_or_default(),
            )?;
        }
    } else {
        for (name, value) in head {
            if name.as_str().starts_with("x-amz-meta-") {
                headers.append(name.clone(), value.clone());
            }
        }
    }
    if let Some(overrides) = options["headers"].as_object() {
        for (field, value) in overrides {
            let name = match field.as_str() {
                "ContentType" | "Content-Type" => "content-type",
                "CacheControl" | "Cache-Control" => "cache-control",
                "ContentDisposition" | "Content-Disposition" => "content-disposition",
                "ContentEncoding" | "Content-Encoding" => "content-encoding",
                "ContentLanguage" | "Content-Language" => "content-language",
                "Expires" => "expires",
                _ => {
                    return Err(invalid_config(format!(
                        "Header {field} cannot be set on a copy."
                    )))
                }
            };
            match value.as_str() {
                Some(text) if !text.is_empty() => set_header(&mut headers, name, text)?,
                _ => {
                    headers.remove(name);
                }
            }
        }
    }
    if let Some(class) = options["storageClass"]
        .as_str()
        .filter(|class| !class.is_empty())
    {
        set_header(&mut headers, "x-amz-storage-class", class)?;
    }
    if !has_server_side_encryption(write)
        && !head.contains_key("x-amz-server-side-encryption-customer-algorithm")
    {
        for name in [
            "x-amz-server-side-encryption",
            "x-amz-server-side-encryption-aws-kms-key-id",
            "x-amz-server-side-encryption-bucket-key-enabled",
        ] {
            if let Some(value) = head.get(name) {
                headers.insert(HeaderName::from_static(name), value.clone());
            }
        }
    }
    headers.extend(write.clone());
    Ok(headers)
}

fn has_options(options: &Value) -> bool {
    options.as_object().is_some_and(|map| {
        ["metadata", "headers", "storageClass", "tags"]
            .iter()
            .any(|field| map.get(*field).is_some_and(|value| !value.is_null()))
    })
}

fn is_precondition_failure(error: &SidecarError) -> bool {
    error_status(error) == Some(412)
        || matches!(
            aws_code(error).as_deref(),
            Some("PreconditionFailed" | "ConditionalRequestConflict")
        )
}

pub(crate) type PartFuture<'a, T> =
    Pin<Box<dyn Future<Output = Result<T, SidecarError>> + Send + 'a>>;

/// Runs `count` futures with at most `limit` in flight; the first error wins
/// and drops (cancels) the rest. Futures may borrow from the caller.
pub(crate) async fn run_bounded<'a, T, F>(
    count: usize,
    limit: usize,
    mut make: F,
) -> Result<Vec<T>, SidecarError>
where
    T: Send + 'a,
    F: FnMut(usize) -> PartFuture<'a, T> + Send,
{
    let limit = limit.max(1);
    let mut results: Vec<Option<T>> = (0..count).map(|_| None).collect();
    let mut active: Vec<(usize, PartFuture<'a, T>)> = Vec::new();
    let mut next = 0usize;
    std::future::poll_fn(|context| loop {
        while active.len() < limit && next < count {
            active.push((next, make(next)));
            next += 1;
        }
        if active.is_empty() {
            return Poll::Ready(Ok(()));
        }
        let mut progressed = false;
        let mut index = 0;
        while index < active.len() {
            match active[index].1.as_mut().poll(context) {
                Poll::Ready(Ok(value)) => {
                    let (slot, _) = active.swap_remove(index);
                    results[slot] = Some(value);
                    progressed = true;
                }
                Poll::Ready(Err(error)) => return Poll::Ready(Err(error)),
                Poll::Pending => index += 1,
            }
        }
        if !progressed {
            return Poll::Pending;
        }
    })
    .await?;
    Ok(results
        .into_iter()
        .map(|value| value.expect("every part completed"))
        .collect())
}

struct Copied {
    etag: Option<String>,
    version: Option<String>,
    strategy: &'static str,
}

enum Conditional {
    Done(Copied),
    Exists,
}

struct Plan<'a> {
    client: &'a Client,
    source_bucket: &'a str,
    source_key: &'a str,
    bucket: &'a str,
    key: &'a str,
    source: String,
    source_version: Option<&'a str>,
    etag: &'a str,
    size: u64,
    head: &'a HeaderMap,
    options: &'a Value,
    write: &'a HeaderMap,
    destination_customer: HeaderMap,
    source_customer: HeaderMap,
    read: &'a HeaderMap,
    limit: usize,
}

impl Plan<'_> {
    async fn source_tags(&self) -> Result<Vec<(String, String)>, SidecarError> {
        if let Some(tags) = self.options["tags"].as_object() {
            return Ok(tags
                .iter()
                .map(|(key, value)| {
                    (
                        key.clone(),
                        value
                            .as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| value.to_string()),
                    )
                })
                .collect());
        }
        if self.options["preserveTags"].as_bool() == Some(false) {
            return Ok(Vec::new());
        }
        let mut query: Vec<(&str, &str)> = vec![("tagging", "")];
        if let Some(version) = self.source_version {
            query.push(("versionId", version));
        }
        let result = call(
            self.client,
            Method::GET,
            Some(self.source_bucket),
            Some(self.source_key),
            &query,
            self.read.clone(),
            Payload::Empty,
            Retry::Safe,
        )
        .await;
        let (_, body) = match result {
            Ok(response) => response,
            Err(error) if aws_code(&error).as_deref() == Some("NoSuchTagSet") => {
                return Ok(Vec::new())
            }
            Err(error) => return Err(error),
        };
        let document = xml::to_json(Doc::Tagging, &parse_document(&body, "Tagging")?);
        Ok(document["TagSet"]
            .as_array()
            .map(|tags| {
                tags.iter()
                    .map(|tag| {
                        (
                            tag["Key"].as_str().unwrap_or_default().to_string(),
                            tag["Value"].as_str().unwrap_or_default().to_string(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    /// CopyObject for objects up to 5 GiB. Without options the provider copies
    /// metadata and tags itself (COPY directives).
    async fn single(&self) -> Result<Copied, SidecarError> {
        let mut headers = if has_options(self.options) {
            let mut headers = object_headers(self.head, self.options, self.write)?;
            set_header(&mut headers, "x-amz-metadata-directive", "REPLACE")?;
            if self.options["tags"].is_object() {
                set_header(&mut headers, "x-amz-tagging-directive", "REPLACE")?;
                set_header(
                    &mut headers,
                    "x-amz-tagging",
                    &tagging_header(&self.source_tags().await?),
                )?;
            }
            headers
        } else {
            self.write.clone()
        };
        set_header(&mut headers, "x-amz-copy-source", &self.source)?;
        set_header(&mut headers, "x-amz-copy-source-if-match", self.etag)?;
        headers.extend(self.source_customer.clone());
        let (response, body) = call(
            self.client,
            Method::PUT,
            Some(self.bucket),
            Some(self.key),
            &[],
            headers,
            Payload::Empty,
            Retry::Rejected,
        )
        .await
        .map_err(|error| crate::uncertain_mutation(error, "Copy"))?;
        let result = parse_document(&body, "CopyObjectResult")
            .map_err(|error| crate::uncertain_mutation(error, "Copy"))?;
        Ok(Copied {
            etag: result
                .text_of("ETag")
                .filter(|etag| !etag.is_empty())
                .map(str::to_owned),
            version: header_text(&response, "x-amz-version-id"),
            strategy: "server-side copy",
        })
    }

    /// Multipart copy with UploadPartCopy. `exclusive` adds `If-None-Match: *`
    /// to the completion so an existing destination is never replaced.
    async fn multipart(&self, exclusive: bool) -> Result<Conditional, SidecarError> {
        let part = COPY_PART.max(self.size.div_ceil(MAX_PARTS));
        if part > MAX_PART {
            return Err(invalid_config("Object exceeds multipart copy limits."));
        }
        let mut create = object_headers(self.head, self.options, self.write)?;
        let tags = self.source_tags().await?;
        if !tags.is_empty() {
            set_header(&mut create, "x-amz-tagging", &tagging_header(&tags))?;
        }
        let (_, body) = call(
            self.client,
            Method::POST,
            Some(self.bucket),
            Some(self.key),
            &[("uploads", "")],
            create,
            Payload::Empty,
            Retry::Never,
        )
        .await?;
        let upload = parse_document(&body, "InitiateMultipartUploadResult")?
            .text_of("UploadId")
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| {
                SidecarError::new(
                    "unknown_outcome",
                    "Multipart copy did not return an upload ID.",
                )
            })?;
        let result = self.copy_parts(&upload, part, exclusive).await;
        if !matches!(result, Ok(Conditional::Done(_))) {
            let _ = call(
                self.client,
                Method::DELETE,
                Some(self.bucket),
                Some(self.key),
                &[("uploadId", upload.as_str())],
                HeaderMap::new(),
                Payload::Empty,
                Retry::Safe,
            )
            .await;
        }
        result
    }

    async fn copy_parts(
        &self,
        upload: &str,
        part: u64,
        exclusive: bool,
    ) -> Result<Conditional, SidecarError> {
        let count = self.size.div_ceil(part) as usize;
        let etags = run_bounded(count, self.limit, |index| {
            Box::pin(async move {
                let start = index as u64 * part;
                let end = (start + part).min(self.size) - 1;
                let number = (index + 1).to_string();
                let mut headers = self.destination_customer.clone();
                headers.extend(self.source_customer.clone());
                set_header(&mut headers, "x-amz-copy-source", &self.source)?;
                set_header(
                    &mut headers,
                    "x-amz-copy-source-range",
                    &format!("bytes={start}-{end}"),
                )?;
                set_header(&mut headers, "x-amz-copy-source-if-match", self.etag)?;
                let query = [("partNumber", number.as_str()), ("uploadId", upload)];
                let (_, body) = call(
                    self.client,
                    Method::PUT,
                    Some(self.bucket),
                    Some(self.key),
                    &query,
                    headers,
                    Payload::Empty,
                    Retry::Safe,
                )
                .await?;
                parse_document(&body, "CopyPartResult")?
                    .text_of("ETag")
                    .filter(|etag| !etag.is_empty())
                    .map(str::to_owned)
                    .ok_or_else(|| {
                        SidecarError::new("unknown_outcome", "Copy part returned no ETag.")
                    })
            })
        })
        .await?;
        let mut body = String::from(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload xmlns=\"",
        );
        body.push_str(xml::S3_NAMESPACE);
        body.push_str("\">");
        for (index, etag) in etags.iter().enumerate() {
            body.push_str("<Part>");
            xml::text_element("PartNumber", &(index + 1).to_string(), &mut body)?;
            xml::text_element("ETag", etag, &mut body)?;
            body.push_str("</Part>");
        }
        body.push_str("</CompleteMultipartUpload>");
        let mut headers = xml_headers(body.as_bytes());
        headers.extend(self.destination_customer.clone());
        if exclusive {
            set_header(&mut headers, "if-none-match", "*")?;
        }
        match call(
            self.client,
            Method::POST,
            Some(self.bucket),
            Some(self.key),
            &[("uploadId", upload)],
            headers,
            Payload::Bytes(Bytes::from(body)),
            Retry::Never,
        )
        .await
        {
            Ok((response, body)) => {
                let result =
                    parse_document(&body, "CompleteMultipartUploadResult").map_err(|error| {
                        crate::uncertain_mutation(error, "Multipart copy completion")
                    })?;
                Ok(Conditional::Done(Copied {
                    etag: result
                        .text_of("ETag")
                        .filter(|etag| !etag.is_empty())
                        .map(str::to_owned),
                    version: header_text(&response, "x-amz-version-id"),
                    strategy: "multipart server-side copy",
                }))
            }
            Err(error) if exclusive && is_precondition_failure(&error) => Ok(Conditional::Exists),
            Err(error) => Err(crate::uncertain_mutation(
                error,
                "Multipart copy completion",
            )),
        }
    }

    /// A zero-byte object has no copy range; publish it with one conditional PUT.
    async fn empty_exclusive(&self) -> Result<Conditional, SidecarError> {
        let mut headers = object_headers(self.head, self.options, self.write)?;
        let tags = self.source_tags().await?;
        if !tags.is_empty() {
            set_header(&mut headers, "x-amz-tagging", &tagging_header(&tags))?;
        }
        set_header(&mut headers, "if-none-match", "*")?;
        match call(
            self.client,
            Method::PUT,
            Some(self.bucket),
            Some(self.key),
            &[],
            headers,
            Payload::Empty,
            Retry::Never,
        )
        .await
        {
            Ok((response, _)) => Ok(Conditional::Done(Copied {
                etag: header_text(&response, "etag"),
                version: header_text(&response, "x-amz-version-id"),
                strategy: "conditional put",
            })),
            Err(error) if is_precondition_failure(&error) => Ok(Conditional::Exists),
            Err(error) => Err(error),
        }
    }
}

fn skipped() -> Value {
    json!({"successCount": 0, "failureCount": 0, "failures": [], "skipped": true, "bytesCopied": 0})
}

fn exists_error() -> SidecarError {
    SidecarError::new("object_conflict", "Destination object already exists.")
}

fn incomplete(outcome: &mut Value, target: &str, code: &str, message: &str, is_move: bool) {
    outcome["successCount"] = json!(0);
    outcome["failureCount"] = json!(1);
    outcome["requiresVerification"] = json!(true);
    outcome["failures"] = json!([{"target": target, "code": code, "message": message}]);
    if is_move {
        outcome["copiedCount"] = json!(1);
        outcome["sourceRetained"] = json!(true);
    }
}

pub(super) async fn copy_object(params: &Value, is_move: bool) -> SidecarResult {
    let source_bucket = required_text(params, "sourceBucketName", "Source bucket is required.")?;
    let source_key = required_text(params, "sourceKey", "Source key is required.")?;
    let bucket = required_text(
        params,
        "destinationBucketName",
        "Destination bucket is required.",
    )?;
    let key = required_text(params, "destinationKey", "Destination key is required.")?;
    let selected = params["sourceVersionId"]
        .as_str()
        .or_else(|| params["versionId"].as_str())
        .filter(|version| !version.is_empty())
        .map(str::to_owned);
    let same_object = source_bucket == bucket && source_key == key;
    if is_move && same_object {
        return Err(invalid_config(
            "A move requires different source and destination keys or buckets.",
        ));
    }
    if same_object && selected.is_none() {
        return Err(invalid_config(
            "Source and destination must differ unless restoring a selected version.",
        ));
    }
    let policy = params["conflictPolicy"].as_str().unwrap_or("replace");
    if !matches!(policy, "replace" | "overwrite" | "skip" | "fail") {
        return Err(invalid_config(
            "Copy conflict policy must be replace, skip, or fail.",
        ));
    }
    let exclusive = matches!(policy, "skip" | "fail");
    let aws = params["profile"]["endpointType"].as_str() == Some("awsS3");
    let null = Value::Null;
    let options = params
        .get("options")
        .filter(|value| value.is_object())
        .unwrap_or(&null);

    let write = encryption_headers(params, true)?;
    let source_read = encryption_headers(
        &json!({"profile": params["profile"], "encryption": params["sourceEncryption"]}),
        false,
    )?;
    let source_has_key = source_read.contains_key("x-amz-server-side-encryption-customer-key");
    let destination_customer = customer_headers(&write);
    let client = client_for(params)?;

    let mut head_query: Vec<(&str, &str)> = Vec::new();
    if let Some(version) = selected.as_deref() {
        head_query.push(("versionId", version));
    }
    let (head, _) = call(
        &client,
        Method::HEAD,
        Some(&source_bucket),
        Some(&source_key),
        &head_query,
        source_read.clone(),
        Payload::Empty,
        Retry::Safe,
    )
    .await
    .map_err(|error| with_read_hint(error, source_has_key))?;
    let etag = header_text(&head, "etag")
        .filter(|etag| !etag.trim().is_empty())
        .ok_or_else(|| {
            SidecarError::new(
                "unsupported_feature",
                "Source has no validator; a consistent copy cannot be guaranteed.",
            )
        })?;
    let size: u64 = header_text(&head, "content-length")
        .and_then(|length| length.trim().parse().ok())
        .ok_or_else(|| invalid_response("Source HEAD returned no valid Content-Length."))?;
    let version = selected
        .clone()
        .or_else(|| header_text(&head, "x-amz-version-id").filter(|version| !version.is_empty()));
    let expected = params["expectedSourceETag"]
        .as_str()
        .or_else(|| options["expectedETag"].as_str())
        .or_else(|| params["expectedETag"].as_str());
    if expected.is_some_and(|expected| trim_etag(expected) != trim_etag(&etag)) {
        return Err(SidecarError::new(
            "object_conflict",
            "Source object changed. Refresh before copying.",
        ));
    }

    if exclusive {
        match call(
            &client,
            Method::HEAD,
            Some(&bucket),
            Some(&key),
            &[],
            destination_customer.clone(),
            Payload::Empty,
            Retry::Safe,
        )
        .await
        {
            Ok(_) if policy == "fail" => return Err(exists_error()),
            Ok(_) => return Ok(skipped()),
            Err(error)
                if error_status(&error) == Some(404)
                    || matches!(aws_code(&error).as_deref(), Some("NoSuchKey" | "NotFound")) => {}
            Err(error) => return Err(error),
        }
    }

    if exclusive && !aws {
        return Err(SidecarError::new(
            "unsupported_feature",
            "This endpoint has no verified conditional copy support for skip or fail.",
        ));
    }

    let plan = Plan {
        client: &client,
        source_bucket: &source_bucket,
        source_key: &source_key,
        bucket: &bucket,
        key: &key,
        source: copy_source(&source_bucket, &source_key, version.as_deref()),
        source_version: version.as_deref(),
        etag: &etag,
        size,
        head: &head,
        options,
        write: &write,
        destination_customer: destination_customer.clone(),
        source_customer: copy_source_customer_headers(&source_read)?,
        read: &source_read,
        limit: client.max_connections.clamp(1, 8),
    };
    let copied = if exclusive {
        let outcome = if size == 0 {
            plan.empty_exclusive().await?
        } else {
            plan.multipart(true).await?
        };
        match outcome {
            Conditional::Done(copied) => copied,
            Conditional::Exists if policy == "fail" => return Err(exists_error()),
            Conditional::Exists => return Ok(skipped()),
        }
    } else if size <= MAX_SINGLE_COPY {
        plan.single().await?
    } else {
        match plan.multipart(false).await? {
            Conditional::Done(copied) => copied,
            Conditional::Exists => return Err(exists_error()),
        }
    };
    let Some(destination_etag) = copied.etag.clone() else {
        return Err(SidecarError::new(
            "unknown_outcome",
            "Copy completion returned no ETag; source retained and destination requires reconciliation.",
        ));
    };

    let mut outcome = json!({
        "successCount": 1,
        "failureCount": 0,
        "failures": [],
        "skipped": false,
        "bytesCopied": size,
        "sourceVersionId": version,
        "sourceETag": etag,
        "destinationVersionId": copied.version,
        "versionId": copied.version,
        "etag": destination_etag,
        "strategy": copied.strategy,
    });

    // Confirm the destination before reporting success or touching the source.
    let mut verify_query: Vec<(&str, &str)> = Vec::new();
    if let Some(version) = copied
        .version
        .as_deref()
        .filter(|version| !version.is_empty())
    {
        verify_query.push(("versionId", version));
    }
    let verified = match call(
        &client,
        Method::HEAD,
        Some(&bucket),
        Some(&key),
        &verify_query,
        destination_customer.clone(),
        Payload::Empty,
        Retry::Safe,
    )
    .await
    {
        Ok((headers, _)) => {
            let length = header_text(&headers, "content-length")
                .and_then(|length| length.trim().parse::<u64>().ok());
            let current = header_text(&headers, "etag").map(|value| trim_etag(&value));
            length == Some(size)
                && current.is_some_and(|current| current == trim_etag(&destination_etag))
        }
        Err(_) => false,
    };
    if !verified {
        incomplete(
            &mut outcome,
            &key,
            "destination_unverified",
            "The copy was written, but its destination could not be verified. Inspect it before retrying.",
            is_move,
        );
        return Ok(outcome);
    }
    if !is_move {
        return Ok(outcome);
    }

    if selected.is_none() && !aws {
        outcome["successCount"] = json!(0);
        outcome["failureCount"] = json!(1);
        outcome["copyCompleted"] = json!(true);
        outcome["sourceRetained"] = json!(true);
        outcome["failures"] = json!([{
            "target": source_key,
            "code": "source_delete_unsupported",
            "message": "Copy completed. Source retained because this endpoint has no verified conditional-delete capability.",
        }]);
        return Ok(outcome);
    }
    let mut delete_headers = HeaderMap::new();
    set_header(&mut delete_headers, "if-match", &etag)?;
    let mut delete_query: Vec<(&str, &str)> = Vec::new();
    if let Some(version) = selected.as_deref() {
        delete_query.push(("versionId", version));
    }
    if let Err(error) = call(
        &client,
        Method::DELETE,
        Some(&source_bucket),
        Some(&source_key),
        &delete_query,
        delete_headers,
        Payload::Empty,
        Retry::Never,
    )
    .await
    {
        outcome["successCount"] = json!(0);
        outcome["failureCount"] = json!(1);
        outcome["copiedCount"] = json!(1);
        outcome["requiresVerification"] = json!(true);
        outcome["failures"] = json!([{
            "target": source_key,
            "versionId": selected,
            "code": "source_delete_failed",
            "message": format!("Copy completed; source deletion was not confirmed: {}", error.message),
        }]);
        // A definite rejection (including a failed If-Match) left the source in place.
        if error_status(&error).is_some_and(|status| (400..500).contains(&status)) {
            outcome["sourceRetained"] = json!(true);
        }
    }
    Ok(outcome)
}
