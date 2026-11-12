use crate::SidecarError;
use std::{fs, path::Path, time::SystemTime};

#[derive(Clone, Debug, PartialEq)]
pub struct SourceSnapshot {
    length: u64,
    modified: SystemTime,
    #[cfg(unix)]
    identity: (u64, u64),
}
impl SourceSnapshot {
    pub fn capture(path: &Path) -> Result<Self, SidecarError> {
        let metadata =
            fs::metadata(path).map_err(|e| SidecarError::new("invalid_config", e.to_string()))?;
        if !metadata.is_file() {
            return Err(SidecarError::new(
                "invalid_config",
                "Upload source is not a file.",
            ));
        }
        Ok(Self {
            length: metadata.len(),
            modified: metadata
                .modified()
                .map_err(|e| SidecarError::new("invalid_config", e.to_string()))?,
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (metadata.dev(), metadata.ino())
            },
        })
    }
    pub fn check(&self, path: &Path) -> Result<(), SidecarError> {
        if Self::capture(path).as_ref().ok() != Some(self) {
            return Err(SidecarError::new("object_conflict", "Upload source changed while reading. Verify the destination and re-select the file before retrying."));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detects_replaced_truncated_and_grown_sources() {
        let path = std::env::temp_dir().join(format!("odb-source-{}", uuid::Uuid::new_v4()));
        fs::write(&path, b"original").unwrap();
        let snapshot = SourceSnapshot::capture(&path).unwrap();
        snapshot.check(&path).unwrap();
        fs::write(&path, b"x").unwrap();
        assert!(snapshot.check(&path).is_err());
        fs::write(&path, b"a much longer file").unwrap();
        assert!(snapshot.check(&path).is_err());
        let replacement = path.with_extension("replacement");
        fs::write(&replacement, b"original").unwrap();
        fs::rename(replacement, &path).unwrap();
        assert!(snapshot.check(&path).is_err());
        fs::remove_file(path).unwrap();
    }
}
