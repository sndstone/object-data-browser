use super::*;
use aws_smithy_types::{base64, body::SdkBody};
use ring::{
    aead::{Aad, LessSafeKey, Nonce, UnboundKey, CHACHA20_POLY1305},
    hkdf::{Salt, HKDF_SHA256},
};
use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::AsyncReadExt;

pub(super) const CHUNK: u64 = 65536;
pub(super) const SEALED: u64 = CHUNK + 16;

// Deliberately no Debug/Serialize: the unwrapped file key stays in memory only.
#[derive(Clone)]
pub(super) struct ClientEncryption {
    file_key: [u8; 16],
    pub header_length: u64,
    pub file_name: Option<String>,
    header: Vec<u8>,
    nonce: [u8; 16],
}

fn invalid() -> SidecarError {
    SidecarError::new("invalid_config", "Invalid client encryption configuration.")
}
pub(super) fn failed(chunk: u64) -> SidecarError {
    SidecarError::with_details(
        "decryption_failed",
        "Client-encrypted payload authentication failed.",
        json!({"chunk":chunk}),
    )
}
impl ClientEncryption {
    pub fn parse(value: &Value, upload: bool, count: usize) -> Result<Option<Self>, SidecarError> {
        if value.is_null() {
            return Ok(None);
        }
        let fields = value.as_object().ok_or_else(invalid)?;
        if count != 1
            || value["format"] != "age-v1"
            || fields.keys().any(|name| {
                !matches!(name.as_str(), "format" | "fileKey")
                    && !(if upload {
                        matches!(name.as_str(), "header" | "payloadNonce")
                    } else {
                        matches!(name.as_str(), "headerLength" | "fileName")
                    })
            })
        {
            return Err(invalid());
        }
        let decode = |name: &str| {
            base64::decode(value[name].as_str().ok_or_else(invalid)?).map_err(|_| invalid())
        };
        let file_key = decode("fileKey")?.try_into().map_err(|_| invalid())?;
        let (header, header_length, nonce) = if upload {
            let header = decode("header")?;
            let length = header.len() as u64;
            (
                header,
                length,
                decode("payloadNonce")?.try_into().map_err(|_| invalid())?,
            )
        } else {
            (
                Vec::new(),
                value["headerLength"].as_u64().ok_or_else(invalid)?,
                [0; 16],
            )
        };
        if !(1..=CHUNK).contains(&header_length) {
            return Err(invalid());
        }
        let file_name = if let Some(value) = fields.get("fileName") {
            let name = value.as_str().ok_or_else(invalid)?;
            if name.is_empty() || matches!(name, "." | "..") || name.contains(['/', '\\', '\0']) {
                return Err(invalid());
            }
            Some(name.to_owned())
        } else { None };
        Ok(Some(Self {
            file_name,
            file_key,
            header_length,
            header,
            nonce,
        }))
    }
    pub fn object_length(&self, plaintext: u64) -> Result<u64, SidecarError> {
        plaintext
            .checked_add(16 * chunk_count(plaintext))
            .and_then(|n| n.checked_add(self.header_length + 16))
            .ok_or_else(invalid)
    }
    pub fn plaintext_length(&self, object: u64) -> Result<u64, SidecarError> {
        let payload = object
            .checked_sub(self.header_length + 16)
            .ok_or_else(|| failed(0))?;
        let count = payload.div_ceil(SEALED).max(1);
        let plain = payload
            .checked_sub(count * 16)
            .ok_or_else(|| failed(count - 1))?;
        if chunk_count(plain) != count || self.object_length(plain).ok() != Some(object) {
            return Err(failed(count - 1));
        }
        Ok(plain)
    }
    pub fn cipher(&self, nonce: &[u8; 16]) -> LessSafeKey {
        let prk = Salt::new(HKDF_SHA256, nonce).extract(&self.file_key);
        let info = [b"payload".as_slice()];
        let okm = prk
            .expand(&info, &CHACHA20_POLY1305)
            .expect("fixed HKDF length");
        let mut key = [0; 32];
        okm.fill(&mut key).expect("fixed HKDF output");
        LessSafeKey::new(UnboundKey::new(&CHACHA20_POLY1305, &key).expect("32-byte key"))
    }
    pub fn seal(cipher: &LessSafeKey, index: u64, last: bool, mut plain: Vec<u8>) -> Vec<u8> {
        cipher
            .seal_in_place_append_tag(chunk_nonce(index, last), Aad::empty(), &mut plain)
            .expect("bounded chunk");
        plain
    }
    pub fn open<'a>(
        cipher: &LessSafeKey,
        index: u64,
        last: bool,
        sealed: &'a mut [u8],
    ) -> Result<&'a mut [u8], SidecarError> {
        cipher
            .open_in_place(chunk_nonce(index, last), Aad::empty(), sealed)
            .map_err(|_| failed(index))
    }
    // Recreate a retryable body for every SDK attempt. A frame contains at most
    // one sealed chunk, even for multi-GiB provider parts or a large single PUT.
    pub fn body(
        &self,
        path: &Path,
        snapshot: &SourceSnapshot,
        plain: u64,
        start: u64,
        length: u64,
    ) -> ByteStream {
        let config = self.clone();
        let path = path.to_path_buf();
        let snapshot = snapshot.clone();
        ByteStream::new(SdkBody::retryable(move || {
            SdkBody::from_body_1_x(RangeBody {
                config: config.clone(),
                cipher: Arc::new(config.cipher(&config.nonce)),
                path: path.clone(),
                snapshot: snapshot.clone(),
                plain,
                offset: start,
                end: start + length,
                pending: None,
            })
        }))
    }
}
pub(super) fn chunk_count(plain: u64) -> u64 {
    plain.div_ceil(CHUNK).max(1)
}
fn chunk_nonce(index: u64, last: bool) -> Nonce {
    let mut nonce = [0; 12];
    nonce[3..11].copy_from_slice(&index.to_be_bytes());
    nonce[11] = u8::from(last);
    Nonce::assume_unique_for_key(nonce)
}

type ReadFrame = Pin<Box<dyn Future<Output = Result<Bytes, SidecarError>> + Send + Sync>>;
struct RangeBody {
    config: ClientEncryption,
    cipher: Arc<LessSafeKey>,
    path: PathBuf,
    snapshot: SourceSnapshot,
    plain: u64,
    offset: u64,
    end: u64,
    pending: Option<ReadFrame>,
}
impl http_body::Body for RangeBody {
    type Data = Bytes;
    type Error = SidecarError;
    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, SidecarError>>> {
        let this = self.get_mut();
        if this.offset == this.end {
            return Poll::Ready(None);
        }
        if this.pending.is_none() {
            let config = this.config.clone();
            let cipher = this.cipher.clone();
            let path = this.path.clone();
            let snapshot = this.snapshot.clone();
            let (offset, end, plain) = (this.offset, this.end, this.plain);
            this.pending = Some(Box::pin(async move {
                snapshot.check(&path)?;
                let prefix = config.header_length + 16;
                let bytes = if offset < prefix {
                    let mut prefix_bytes = config.header;
                    prefix_bytes.extend_from_slice(&config.nonce);
                    prefix_bytes[offset as usize..end.min(prefix) as usize].to_vec()
                } else {
                    let index = (offset - prefix) / SEALED;
                    let chunk_start = prefix + index * SEALED;
                    let length = CHUNK.min(plain - index * CHUNK) as usize;
                    let mut file = tokio::fs::File::open(&path).await.map_err(file_error)?;
                    file.seek(SeekFrom::Start(index * CHUNK))
                        .await
                        .map_err(file_error)?;
                    let mut bytes = vec![0; length];
                    file.read_exact(&mut bytes).await.map_err(file_error)?;
                    snapshot.check(&path)?;
                    let sealed = ClientEncryption::seal(
                        &cipher,
                        index,
                        index + 1 == chunk_count(plain),
                        bytes,
                    );
                    sealed[(offset - chunk_start) as usize
                        ..(end - chunk_start).min(sealed.len() as u64) as usize]
                        .to_vec()
                };
                Ok(Bytes::from(bytes))
            }));
        }
        match this.pending.as_mut().unwrap().as_mut().poll(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(result) => {
                this.pending = None;
                match result {
                    Ok(bytes) => {
                        this.offset += bytes.len() as u64;
                        Poll::Ready(Some(Ok(http_body::Frame::data(bytes))))
                    }
                    Err(error) => {
                        this.offset = this.end;
                        Poll::Ready(Some(Err(error)))
                    }
                }
            }
        }
    }
    fn is_end_stream(&self) -> bool {
        self.offset == self.end
    }
    fn size_hint(&self) -> http_body::SizeHint {
        http_body::SizeHint::with_exact(self.end - self.offset)
    }
}
fn file_error(error: io::Error) -> SidecarError {
    SidecarError::new("invalid_config", error.to_string())
}

// The same range validators and retry policy as ordinary ranged downloads,
// with a strict bounded buffer so no unauthenticated bytes reach the file.
async fn fetch_range(
    client: &Client,
    bucket: &str,
    key: &str,
    start: u64,
    end: u64,
    size: u64,
    validator: &Option<String>,
    version: &Option<String>,
    attempts: u32,
    encryption: &Encryption,
    progress: &Arc<TransferProgress>,
) -> Result<Vec<u8>, SidecarError> {
    let mut attempt = 0;
    loop {
        let result = async {
            let output = encryption_customer!(
                client
                    .get_object()
                    .bucket(bucket)
                    .key(key)
                    .range(format!("bytes={start}-{end}"))
                    .set_if_match(validator.clone())
                    .set_version_id(version.clone()),
                encryption
            )
            .send()
            .await
            .map_err(|error| object_encryption::read_error(error, encryption.customer()))?;
            if validator
                .as_deref()
                .is_some_and(|etag| output.e_tag() != Some(etag))
                || output.content_range() != Some(format!("bytes {start}-{end}/{size}").as_str())
            {
                return Err(SidecarError::new(
                    "object_conflict",
                    "Download range or ETag mismatch; partial file discarded.",
                ));
            }
            let mut bytes = Vec::with_capacity((end - start + 1) as usize);
            let mut body = output.body;
            while let Some(chunk) = body
                .try_next()
                .await
                .map_err(|error| SidecarError::new("engine_unavailable", error.to_string()))?
            {
                if bytes.len() as u64 + chunk.len() as u64 > end - start + 1 {
                    return Err(SidecarError::new(
                        "object_conflict",
                        "Oversized range body.",
                    ));
                }
                bytes.extend_from_slice(&chunk);
                progress.note_activity();
            }
            if bytes.len() as u64 != end - start + 1 {
                return Err(SidecarError::new(
                    "engine_unavailable",
                    "Incomplete encrypted range body.",
                ));
            }
            Ok(bytes)
        }
        .await;
        match result {
            Ok(bytes) => return Ok(bytes),
            Err(error)
                if error.code == "engine_unavailable" && attempt < attempts.clamp(1, 10) - 1 =>
            {
                attempt += 1;
                tokio::time::sleep(Duration::from_millis(100 << attempt.min(4))).await;
            }
            Err(error) => return Err(error),
        }
    }
}

pub(super) async fn download(
    config: &ClientEncryption,
    client: &Client,
    bucket: &str,
    key: &str,
    target: &Path,
    size: u64,
    validator: Option<String>,
    version: Option<String>,
    concurrency: usize,
    attempts: u32,
    progress: &Arc<TransferProgress>,
    encryption: &Encryption,
) -> Result<(), SidecarError> {
    let plain = config.plaintext_length(size)?;
    let nonce = fetch_range(
        client,
        bucket,
        key,
        config.header_length,
        config.header_length + 15,
        size,
        &validator,
        &version,
        attempts,
        encryption,
        progress,
    )
    .await?;
    let cipher = Arc::new(config.cipher(&nonce.try_into().expect("validated 16-byte range")));
    let file = tokio::fs::OpenOptions::new()
        .write(true)
        .open(target)
        .await
        .map_err(file_error)?;
    file.set_len(plain).await.map_err(file_error)?;
    drop(file);
    // Include the header (HEAD-validated length) in ciphertext progress totals.
    progress.state.lock().unwrap().bytes_transferred += config.header_length + 16;
    let prefix = config.header_length + 16;
    run_bounded(
        chunk_count(plain),
        concurrency,
        |index| {
            let client = client.clone();
            let (bucket, key, target) = (bucket.to_owned(), key.to_owned(), target.to_path_buf());
            let (validator, version, cipher, progress, encryption) = (
                validator.clone(),
                version.clone(),
                cipher.clone(),
                progress.clone(),
                encryption.clone(),
            );
            async move {
                let start = prefix + index * SEALED;
                let end = (start + SEALED).min(size) - 1;
                let mut sealed = fetch_range(
                    &client,
                    &bucket,
                    &key,
                    start,
                    end,
                    size,
                    &validator,
                    &version,
                    attempts,
                    &encryption,
                    &progress,
                )
                .await?;
                let bytes = ClientEncryption::open(
                    &cipher,
                    index,
                    index + 1 == chunk_count(plain),
                    &mut sealed,
                )?;
                let mut file = tokio::fs::OpenOptions::new()
                    .write(true)
                    .open(&target)
                    .await
                    .map_err(file_error)?;
                file.seek(SeekFrom::Start(index * CHUNK))
                    .await
                    .map_err(file_error)?;
                file.write_all(bytes).await.map_err(file_error)?;
                file.flush().await.map_err(file_error)?;
                {
                    let mut state = progress.state.lock().unwrap();
                    state.bytes_transferred += end - start + 1;
                    state.parts_completed += 1;
                    state.push_part_line(format!("Authenticated chunk {index} for {key}."));
                }
                progress.emit("running", Some(key));
                Ok(())
            }
        },
        |()| {},
    )
    .await
}

#[cfg(test)]
pub(crate) mod tests;
