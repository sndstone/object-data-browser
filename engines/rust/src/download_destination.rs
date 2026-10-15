use std::{
    collections::HashMap,
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
        let mut occupied = HashMap::new();
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            occupied
                .entry(entry.file_name().to_string_lossy().to_lowercase())
                .or_insert_with(|| entry.path());
        }
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
            let existing = occupied.get(&candidate.to_lowercase());
            if policy == "replace" {
                let target = existing
                    .cloned()
                    .unwrap_or_else(|| directory.join(&candidate));
                fs::rename(&self.0, &target)?;
                return Ok(target);
            }
            if existing.is_some() {
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

#[cfg(test)]
mod tests {
    use super::*;

    struct Directory(PathBuf);
    impl Directory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("odb-test-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn staged(&self) -> StagedDownload {
            let staged = StagedDownload::new(&self.0).unwrap();
            fs::write(&staged.0, b"download").unwrap();
            staged
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn keep_both_skips_case_insensitive_collisions() {
        let directory = Directory::new();
        fs::write(directory.0.join("FILE.txt"), b"original").unwrap();
        for index in 1..=256 {
            fs::write(directory.0.join(format!("FILE ({index}).txt")), b"original").unwrap();
        }
        let staged = directory.staged();
        let target = staged
            .publish(&directory.0, "prefix/file.txt", "keepBoth")
            .unwrap();
        assert_eq!(target.file_name().unwrap(), "file (257).txt");
        assert_eq!(fs::read(target).unwrap(), b"download");
        assert_eq!(fs::read(directory.0.join("FILE.txt")).unwrap(), b"original");
        fs::write(directory.0.join("Ä.txt"), b"original").unwrap();
        assert_eq!(
            directory
                .staged()
                .publish(&directory.0, "ä.txt", "keepBoth")
                .unwrap()
                .file_name()
                .unwrap(),
            "ä (1).txt"
        );
    }

    #[test]
    fn replace_preserves_existing_case_and_refuses_directories() {
        let directory = Directory::new();
        let target = directory.0.join("FILE.txt");
        fs::write(&target, b"original").unwrap();
        assert_eq!(
            directory
                .staged()
                .publish(&directory.0, "file.txt", "replace")
                .unwrap(),
            target
        );
        assert_eq!(fs::read(target).unwrap(), b"download");
        fs::create_dir(directory.0.join("folder")).unwrap();
        let staged = directory.staged();
        assert!(staged.publish(&directory.0, "FOLDER", "replace").is_err());
        assert!(staged.0.exists());
        assert!(directory.0.join("folder").is_dir());
    }

    #[cfg(unix)]
    #[test]
    fn publication_never_follows_existing_symlinks() {
        use std::os::unix::fs::symlink;
        for dangling in [false, true] {
            for policy in ["keepBoth", "replace"] {
                let directory = Directory::new();
                let outside = Directory::new();
                let referent = outside.0.join("outside.txt");
                if !dangling {
                    fs::write(&referent, b"original").unwrap();
                }
                let link = directory.0.join("FILE.txt");
                symlink(&referent, &link).unwrap();
                let staged = directory.staged();
                let target = staged.publish(&directory.0, "file.txt", policy).unwrap();
                assert_eq!(fs::read(&target).unwrap(), b"download");
                assert_eq!(referent.exists(), !dangling);
                if !dangling {
                    assert_eq!(fs::read(&referent).unwrap(), b"original");
                }
                assert_eq!(
                    fs::symlink_metadata(link).unwrap().file_type().is_symlink(),
                    policy == "keepBoth"
                );
            }
        }
    }
}
