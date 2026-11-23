use super::*;
use crate::benchmark_runtime::{Metrics, Payload};
use aws_sdk_s3::config::interceptors::{
    BeforeSerializationInterceptorContextRef, BeforeTransmitInterceptorContextRef,
    FinalizerInterceptorContextRef,
};
use aws_smithy_types::config_bag::{Storable, StoreReplace};
use std::sync::atomic::Ordering as AtomicOrdering;

pub(super) use aws_sdk_s3::Client;
pub(super) const RUNTIME_NAME: &str = "object-data-browser-rust-engine";
pub(super) const POOL_LIMIT_SUPPORTED: bool = false;

pub(super) fn validate_profile(profile: &Value) -> Result<(), SidecarError> {
    parse_profile(profile).map(|_| ())
}

pub(super) async fn build(profile: &Value, metrics: Arc<Metrics>) -> Result<Client, SidecarError> {
    let shared = build_client(&parse_profile(profile)?).await?;
    Ok(Client::from_conf(
        shared
            .config()
            .to_builder()
            .interceptor(MetricsInterceptor(metrics))
            .build(),
    ))
}

pub(super) struct BenchmarkBody(ByteStream);
impl BenchmarkBody {
    pub(super) async fn next_chunk(&mut self) -> Result<Option<Bytes>, SidecarError> {
        self.0
            .try_next()
            .await
            .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))
    }
}

async fn body(payload: &Payload) -> Result<ByteStream, SidecarError> {
    match payload {
        Payload::Memory(bytes) => Ok(ByteStream::from(bytes.clone())),
        Payload::File(path) => ByteStream::read_from()
            .path(path)
            .buffer_size(UPLOAD_FILE_BUFFER_BYTES)
            .build()
            .await
            .map_err(|error| SidecarError::new("engine_unavailable", error.to_string())),
    }
}

pub(super) async fn put(
    client: &Client,
    bucket: &str,
    key: &str,
    payload: &Payload,
    _: usize,
) -> Result<(), SidecarError> {
    client
        .put_object()
        .bucket(bucket)
        .key(key)
        .body(body(payload).await?)
        .send()
        .await
        .map(|_| ())
        .map_err(map_sdk_error)
}

pub(super) async fn get(
    client: &Client,
    bucket: &str,
    key: &str,
) -> Result<BenchmarkBody, SidecarError> {
    client
        .get_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await
        .map(|output| BenchmarkBody(output.body))
        .map_err(map_sdk_error)
}

pub(super) async fn delete_single(
    client: &Client,
    bucket: &str,
    key: &str,
) -> Result<(), SidecarError> {
    client
        .delete_object()
        .bucket(bucket)
        .key(key)
        .send()
        .await
        .map(|_| ())
        .map_err(map_sdk_error)
}

pub(super) async fn delete_multi(
    client: &Client,
    bucket: &str,
    keys: &[String],
) -> Result<Vec<crate::benchmark::DeleteOutcome>, SidecarError> {
    let objects: Vec<ObjectIdentifier> = keys
        .iter()
        .map(|key| {
            ObjectIdentifier::builder()
                .key(key)
                .build()
                .map_err(|error| SidecarError::new("invalid_config", error.to_string()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let delete = Delete::builder()
        .set_objects(Some(objects))
        .quiet(false)
        .build()
        .map_err(|error| SidecarError::new("invalid_config", error.to_string()))?;
    let output = client
        .delete_objects()
        .bucket(bucket)
        .delete(delete)
        .send()
        .await
        .map_err(map_sdk_error)?;
    Ok(output
        .deleted()
        .iter()
        .map(|item| crate::benchmark::DeleteOutcome {
            key: item.key().unwrap_or_default().to_owned(),
            code: None,
            message: None,
        })
        .chain(
            output
                .errors()
                .iter()
                .map(|item| crate::benchmark::DeleteOutcome {
                    key: item.key().unwrap_or_default().to_owned(),
                    code: Some(item.code().unwrap_or("Unknown").to_owned()),
                    message: item.message().map(str::to_owned),
                }),
        )
        .collect())
}

#[derive(Clone, Debug)]
struct AttemptCount(u64);
impl Storable for AttemptCount {
    type Storer = StoreReplace<Self>;
}
#[derive(Debug, Clone)]
pub struct MetricsInterceptor(pub Arc<Metrics>);
impl Intercept for MetricsInterceptor {
    fn name(&self) -> &'static str {
        "BenchmarkMetrics"
    }
    fn read_before_execution(
        &self,
        _: &BeforeSerializationInterceptorContextRef<'_>,
        cfg: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        cfg.interceptor_state().store_put(AttemptCount(0));
        Ok(())
    }
    fn read_before_transmit(
        &self,
        _: &BeforeTransmitInterceptorContextRef<'_>,
        _: &RuntimeComponents,
        cfg: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        let attempts = cfg.load::<AttemptCount>().map(|v| v.0).unwrap_or(0);
        if attempts > 0 {
            self.0.retries.fetch_add(1, AtomicOrdering::Relaxed);
        }
        cfg.interceptor_state()
            .store_put(AttemptCount(attempts + 1));
        Ok(())
    }
    fn read_after_execution(
        &self,
        context: &FinalizerInterceptorContextRef<'_>,
        _: &RuntimeComponents,
        _: &mut ConfigBag,
    ) -> Result<(), BoxError> {
        if context
            .output_or_error()
            .is_some_and(|result| result.is_err())
        {
            self.0.errors.fetch_add(1, AtomicOrdering::Relaxed);
        }
        Ok(())
    }
}
