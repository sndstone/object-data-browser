use super::*;
use aws_sdk_s3::config::interceptors::{
    BeforeSerializationInterceptorContextRef, BeforeTransmitInterceptorContextRef,
    FinalizerInterceptorContextRef,
};
use aws_smithy_types::config_bag::{Storable, StoreReplace};
use std::collections::VecDeque;
use std::sync::atomic::AtomicU64;
use sha2::Digest;

pub enum SelectedDigest {
    Sha256(sha2::Sha256),
    Sha1(sha1::Sha1),
    Md5(md5::Md5),
    Crc(crc_fast::Digest),
}
impl SelectedDigest {
    pub fn new(algorithm: &str) -> Self {
        match algorithm {
            "crc32" => Self::Crc(crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32IsoHdlc)),
            "crc32c" => Self::Crc(crc_fast::Digest::new(crc_fast::CrcAlgorithm::Crc32Iscsi)),
            "md5" => Self::Md5(md5::Md5::new()),
            "sha1" => Self::Sha1(sha1::Sha1::new()),
            _ => Self::Sha256(sha2::Sha256::new()),
        }
    }
    pub fn update(&mut self, bytes: &[u8]) {
        match self {
            Self::Sha256(hash) => hash.update(bytes),
            Self::Sha1(hash) => hash.update(bytes),
            Self::Md5(hash) => hash.update(bytes),
            Self::Crc(hash) => { hash.update(bytes); },
        }
    }
    pub fn finish(self) -> String {
        let bytes = match self {
            Self::Sha256(hash) => hash.finalize().to_vec(),
            Self::Sha1(hash) => hash.finalize().to_vec(),
            Self::Md5(hash) => hash.finalize().to_vec(),
            Self::Crc(hash) => (hash.finalize() as u32).to_be_bytes().to_vec(),
        };
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }
}

pub const HISTORY_LIMIT: usize = 10_000;
#[derive(Clone, Debug)]
struct AttemptCount(u64);
impl Storable for AttemptCount {
    type Storer = StoreReplace<Self>;
}
#[derive(Debug, Default)]
pub struct Metrics {
    pub retries: AtomicU64,
    pub errors: AtomicU64,
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

#[derive(Default)]
struct Cache {
    entries: VecDeque<(String, Bytes)>,
    bytes: usize,
}
pub struct Resources {
    pub metrics: Arc<Metrics>,
    cache: Mutex<Cache>,
    budget: usize,
    max_entry: usize,
    in_memory: bool,
    pub csv: Mutex<Option<io::BufWriter<fs::File>>>,
}
impl Resources {
    pub fn new(config: &Value) -> Self {
        let budget = config["dataCacheMb"].as_u64().unwrap_or(64).min(1024) as usize * 1024 * 1024;
        let workers = config["concurrentThreads"]
            .as_u64()
            .unwrap_or(1)
            .clamp(1, 64)
            .min(config["maxPoolConnections"].as_u64().unwrap_or(10).max(1))
            as usize;
        Self {
            metrics: Arc::new(Metrics::default()),
            cache: Mutex::new(Cache::default()),
            csv: Mutex::new(None),
            budget,
            max_entry: (budget / workers).max(256 * 1024),
            in_memory: config["inMemoryData"].as_bool().unwrap_or(true),
        }
    }
    pub fn cache_bytes(&self) -> usize {
        self.cache.lock().unwrap().bytes
    }
    pub fn flush_records(&self) -> Result<(), SidecarError> {
        if let Some(writer) = self.csv.lock().unwrap().as_mut() {
            writer.flush().map_err(io_error)?;
        }
        Ok(())
    }
    pub async fn payload(
        &self,
        run: &str,
        key: &str,
        size: usize,
        random: bool,
    ) -> Result<Payload, SidecarError> {
        let identity = format!("{run}\0{key}\0{size}\0{random}");
        if self.in_memory && size <= self.max_entry {
            {
                let mut cache = self.cache.lock().unwrap();
                if let Some(index) = cache.entries.iter().position(|v| v.0 == identity) {
                    let entry = cache.entries.remove(index).unwrap();
                    let bytes = entry.1.clone();
                    cache.entries.push_back(entry);
                    return Ok(Payload::Memory(bytes));
                }
            }
            let bytes = Bytes::from(benchmark_payload(run, key, size, random));
            let mut cache = self.cache.lock().unwrap();
            if size <= self.budget {
                while cache.bytes + size > self.budget {
                    if let Some((_, old)) = cache.entries.pop_front() {
                        cache.bytes -= old.len();
                    } else {
                        break;
                    }
                }
                cache.bytes += size;
                cache.entries.push_back((identity, bytes.clone()));
            }
            return Ok(Payload::Memory(bytes));
        }
        let path = std::env::temp_dir().join(format!(
            "object-browser-benchmark-{}.payload",
            Uuid::new_v4()
        ));
        let payload = Payload::File(path.clone());
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .await
            .map_err(io_error)?;
        let pattern = pattern(run, key, size, random);
        let mut buffer = vec![0; 256 * 1024];
        let mut offset = 0;
        while offset < size {
            let count = buffer.len().min(size - offset);
            fill(&mut buffer[..count], &pattern, offset);
            file.write_all(&buffer[..count]).await.map_err(io_error)?;
            offset += count;
        }
        file.flush().await.map_err(io_error)?;
        Ok(payload)
    }
}
fn io_error(error: impl std::fmt::Display) -> SidecarError {
    SidecarError::new("engine_unavailable", error.to_string())
}
pub enum Payload {
    Memory(Bytes),
    File(PathBuf),
}
impl Payload {
    pub async fn body(&self) -> Result<ByteStream, SidecarError> {
        match self {
            Self::Memory(bytes) => Ok(ByteStream::from(bytes.clone())),
            Self::File(path) => ByteStream::read_from()
                .path(path)
                .buffer_size(UPLOAD_FILE_BUFFER_BYTES)
                .build()
                .await
                .map_err(io_error),
        }
    }
}
impl Drop for Payload {
    fn drop(&mut self) {
        if let Self::File(path) = self {
            let _ = fs::remove_file(path);
        }
    }
}
pub fn pattern(run: &str, key: &str, size: usize, random: bool) -> Vec<u8> {
    if !random {
        return vec![b'A'];
    }
    let seed = format!("{run}:{key}:{size}").into_bytes();
    (0..(seed.len() * 8).clamp(64, 4096))
        .map(|i| (seed[i % seed.len()] as usize + i * 17) as u8)
        .collect()
}
pub fn fill(bytes: &mut [u8], pattern: &[u8], offset: usize) {
    let mut written = 0;
    while written < bytes.len() {
        let start = (offset + written) % pattern.len();
        let count = (bytes.len() - written).min(pattern.len() - start);
        bytes[written..written + count].copy_from_slice(&pattern[start..start + count]);
        written += count;
    }
}
pub fn validate(config: &Value) -> Result<(), SidecarError> {
    if !matches!(config["checksumAlgorithm"].as_str().unwrap_or("sha256"), "sha256" | "sha1" | "md5" | "crc32" | "crc32c") {
        return Err(SidecarError::new("invalid_config", "Choose SHA256, SHA1, MD5, CRC32 or CRC32C for benchmark checksum validation."));
    }
    if !(1..=100_000).contains(&config["objectCount"].as_u64().unwrap_or(100))
        || !(1..=64).contains(&config["concurrentThreads"].as_u64().unwrap_or(1))
        || config["dataCacheMb"].as_i64().unwrap_or(64) < 0
        || config["dataCacheMb"].as_u64().unwrap_or(64) > 1024
    {
        return Err(SidecarError::new(
            "invalid_config",
            "Benchmark requires 1–100000 objects, 1–64 workers and 0–1024 MiB cache.",
        ));
    }
    if config["objectSizes"].as_array().is_some_and(|sizes| {
        sizes
            .iter()
            .any(|v| !(1..=512 * 1024 * 1024).contains(&v.as_u64().unwrap_or(0)))
    }) {
        return Err(SidecarError::new(
            "invalid_config",
            "Benchmark object sizes must be 1 byte–512 MiB.",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn disk_payload_is_repeatable_and_removed_after_use() {
        let resources = Resources::new(&json!({"inMemoryData":false,"dataCacheMb":1}));
        let payload = resources.payload("run", "key", 524301, true).await.unwrap();
        let path = match &payload {
            Payload::File(path) => path.clone(),
            _ => panic!("expected disk payload"),
        };
        let expected = benchmark_payload("run", "key", 524301, true);
        for _ in 0..2 {
            let bytes = payload
                .body()
                .await
                .unwrap()
                .collect()
                .await
                .unwrap()
                .into_bytes();
            assert_eq!(bytes.as_ref(), expected.as_slice());
        }
        assert_eq!(resources.cache_bytes(), 0);
        drop(payload);
        assert!(!path.exists());
    }
    #[tokio::test]
    async fn cache_evicts_entries_at_the_configured_byte_budget() {
        let resources =
            Resources::new(&json!({"inMemoryData":true,"dataCacheMb":1,"concurrentThreads":1}));
        for index in 0..4 {
            let payload = resources
                .payload("run", &format!("key-{index}"), 600_000, true)
                .await
                .unwrap();
            assert!(matches!(payload, Payload::Memory(_)));
            assert_eq!(resources.cache_bytes(), 600_000);
        }
    }
}
