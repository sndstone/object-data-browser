use crate::benchmark::DeleteOutcome;
use crate::benchmark_runtime::{Metrics, Payload};
use crate::client::{Payload as HttpPayload, Response, Retry};
use crate::{operations, SidecarError};
use http::{HeaderMap, Method};
use serde_json::Value;
use std::sync::Arc;

pub(super) use crate::client::Client;
pub(super) const RUNTIME_NAME: &str = "object-data-browser-rust-raw-engine";
pub(super) const POOL_LIMIT_SUPPORTED: bool = true;

pub(super) fn validate_profile(profile: &Value) -> Result<(), SidecarError> {
    Client::new(profile).map(|_| ())
}

pub(super) async fn build(profile: &Value, metrics: Arc<Metrics>) -> Result<Client, SidecarError> {
    Ok(Client::new(profile)?.with_metrics(metrics))
}

pub(super) async fn put(
    client: &Client,
    bucket: &str,
    key: &str,
    payload: &Payload,
    size: usize,
) -> Result<(), SidecarError> {
    let mut headers = HeaderMap::new();
    let payload = match payload {
        Payload::Memory(bytes) => {
            // Object Lock requires an upload checksum. The client adds one for files.
            operations::set_header(&mut headers, "content-md5", &operations::content_md5(bytes))?;
            HttpPayload::Bytes(bytes.clone())
        }
        Payload::File(path) => HttpPayload::file(path.clone(), 0, size as u64, None),
    };
    client
        .send(
            Method::PUT,
            Some(bucket),
            Some(key),
            &[],
            headers,
            payload,
            Retry::Rejected,
        )
        .await?
        .bytes()
        .await?;
    Ok(())
}

pub(super) async fn get(
    client: &Client,
    bucket: &str,
    key: &str,
) -> Result<Response, SidecarError> {
    client
        .send(
            Method::GET,
            Some(bucket),
            Some(key),
            &[],
            HeaderMap::new(),
            HttpPayload::Empty,
            Retry::Safe,
        )
        .await
}

pub(super) async fn delete_single(
    client: &Client,
    bucket: &str,
    key: &str,
) -> Result<(), SidecarError> {
    client
        .send(
            Method::DELETE,
            Some(bucket),
            Some(key),
            &[],
            HeaderMap::new(),
            HttpPayload::Empty,
            Retry::Rejected,
        )
        .await?
        .bytes()
        .await?;
    Ok(())
}

pub(super) async fn delete_multi(
    client: &Client,
    bucket: &str,
    keys: &[String],
) -> Result<Vec<DeleteOutcome>, SidecarError> {
    let objects: Vec<_> = keys.iter().map(|key| (key.as_str(), None)).collect();
    Ok(operations::delete_batch(client, bucket, &objects, false)
        .await?
        .into_iter()
        .map(|item| DeleteOutcome {
            key: item.key,
            code: item.code,
            message: item.message,
        })
        .collect())
}
