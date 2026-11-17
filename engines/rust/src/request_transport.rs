use super::*;
use tokio::io::{AsyncBufRead, AsyncBufReadExt};
use tokio::sync::OwnedSemaphorePermit;

pub const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_ACTIVE_REQUESTS: usize = 8;
// Eight executing requests plus 32 waiting. The desktop host normally sends
// only one request per sidecar process, leaving ample room for bursts.
const MAX_ADMITTED_REQUESTS: usize = MAX_ACTIVE_REQUESTS + 32;

pub struct Admission(Arc<Semaphore>);

impl Admission {
    pub fn new() -> Self {
        Self(Arc::new(Semaphore::new(MAX_ADMITTED_REQUESTS)))
    }

    pub fn admit(&self, method: &str) -> Result<Option<OwnedSemaphorePermit>, SidecarError> {
        if matches!(method,
            "health" | "getCapabilities" | "getBenchmarkStatus" | "exportBenchmarkResults" |
            "pauseTransfer" | "resumeTransfer" | "cancelTransfer" |
            "cancelToolExecution" | "pauseBenchmark" | "resumeBenchmark" | "stopBenchmark"
        ) {
            return Ok(None);
        }
        self.0.clone().try_acquire_owned().map(Some).map_err(|_| {
            SidecarError::new("overloaded", "Rust engine request capacity reached (8 active and 32 waiting). Retry after a request completes.")
        })
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Frame {
    Data(Vec<u8>),
    Oversized,
}

// Retain at most `limit` input bytes, then discard through the next newline.
// Reading a frame without its trailing newline at EOF is also supported.
pub async fn read_frame<R: AsyncBufRead + Unpin>(reader: &mut R, limit: usize) -> io::Result<Option<Frame>> {
    let mut bytes = Vec::new();
    let mut oversized = false;
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return Ok(if oversized { Some(Frame::Oversized) }
                else if bytes.is_empty() { None } else { Some(Frame::Data(bytes)) });
        }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let count = newline.unwrap_or(chunk.len());
        if !oversized {
            if count > limit - bytes.len() {
                oversized = true;
                bytes = Vec::new();
            } else {
                bytes.extend_from_slice(&chunk[..count]);
            }
        }
        reader.consume(count + usize::from(newline.is_some()));
        if newline.is_some() {
            return Ok(Some(if oversized { Frame::Oversized } else { Frame::Data(bytes) }));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn frame_limit_accepts_boundary_and_resynchronizes_after_oversize() {
        let mut input = tokio::io::BufReader::with_capacity(3, &b"12345678\n123456789discard\nhealth\nlast"[..]);
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), Some(Frame::Data(b"12345678".to_vec())));
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), Some(Frame::Oversized));
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), Some(Frame::Data(b"health".to_vec())));
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), Some(Frame::Data(b"last".to_vec())));
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), None);
    }

    #[tokio::test]
    async fn oversized_unterminated_frame_is_reported_once() {
        let mut input = &b"123456789"[..];
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), Some(Frame::Oversized));
        assert_eq!(read_frame(&mut input, 8).await.unwrap(), None);
    }

    #[test]
    fn admission_bounds_bursts_and_keeps_controls_available() {
        let admission = Admission::new();
        let mut permits: Vec<_> = (0..MAX_ADMITTED_REQUESTS)
            .map(|_| admission.admit("startUpload").unwrap().unwrap()).collect();
        for _ in 0..10_000 {
            assert_eq!(admission.admit("listObjects").unwrap_err().code, "overloaded");
        }
        for method in ["health", "getCapabilities", "getBenchmarkStatus", "exportBenchmarkResults", "pauseTransfer",
            "resumeTransfer", "cancelTransfer", "cancelToolExecution", "pauseBenchmark",
            "resumeBenchmark", "stopBenchmark"] {
            assert!(admission.admit(method).unwrap().is_none(), "{method}");
        }
        permits.pop();
        assert!(admission.admit("startDownload").unwrap().is_some());
    }
}
