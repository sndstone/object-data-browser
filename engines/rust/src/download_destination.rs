use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub struct StagedDownload(pub PathBuf);
impl StagedDownload {
    pub fn new(directory: &Path) -> io::Result<Self> {
        let path = directory.join(format!(".odb-{}.part", uuid::Uuid::new_v4()));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        Ok(Self(path))
    }
    pub fn publish(&self, directory: &Path, key: &str, policy: &str) -> io::Result<PathBuf> {
        if policy != "keepBoth" && policy != "replace" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Unknown download conflict policy",
            ));
        }
        let normalized = key.replace('\\', "/");
        let mut name: String = normalized
            .rsplit('/')
            .next()
            .unwrap_or("download")
            .chars()
            .take(100)
            .map(|c| {
                if c < ' ' || "<>:\"/\\|?*".contains(c) {
                    '_'
                } else {
                    c
                }
            })
            .collect();
        name = name.trim_end_matches([' ', '.']).to_string();
        if name.is_empty() {
            name = "download".into();
        }
        let stem = name.split('.').next().unwrap_or("").to_uppercase();
        if ["CON", "PRN", "AUX", "NUL"].contains(&stem.as_str())
            || stem.starts_with("COM")
            || stem.starts_with("LPT")
        {
            name = format!("_{name}");
        }
        let base = Path::new(&name);
        for index in 0..100000 {
            let candidate = if index == 0 {
                name.clone()
            } else {
                let ext = base
                    .extension()
                    .and_then(|x| x.to_str())
                    .map(|x| format!(".{x}"))
                    .unwrap_or_default();
                format!(
                    "{} ({index}){ext}",
                    base.file_stem().unwrap_or_default().to_string_lossy()
                )
            };
            if policy == "replace" {
                let mut target = directory.join(&candidate);
                for entry in fs::read_dir(directory)? {
                    let entry = entry?;
                    if entry.file_name().to_string_lossy().to_lowercase()
                        == candidate.to_lowercase()
                    {
                        target = entry.path();
                        break;
                    }
                }
                fs::rename(&self.0, &target)?;
                return Ok(target);
            }
            if fs::read_dir(directory)?.any(|entry| {
                entry
                    .map(|e| {
                        e.file_name().to_string_lossy().to_lowercase() == candidate.to_lowercase()
                    })
                    .unwrap_or(false)
            }) {
                continue;
            }
            let target = directory.join(candidate);
            match fs::hard_link(&self.0, &target) {
                Ok(()) => return Ok(target),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Cannot allocate a unique download name",
        ))
    }
}
impl Drop for StagedDownload {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
