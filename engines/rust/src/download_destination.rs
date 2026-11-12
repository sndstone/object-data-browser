use std::{
    collections::HashMap,
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Clone, PartialEq, Eq)]
struct DirectoryStamp {
    modified: Option<std::time::SystemTime>,
    created: Option<std::time::SystemTime>,
    length: u64,
    #[cfg(unix)]
    identity: (u64, u64, i64, i64),
}
impl DirectoryStamp {
    fn read(directory: &Path) -> io::Result<Self> {
        let metadata = fs::metadata(directory)?;
        if !metadata.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotADirectory,
                "Download destination is not a directory",
            ));
        }
        #[cfg(unix)]
        use std::os::unix::fs::MetadataExt;
        Ok(Self {
            modified: metadata.modified().ok(),
            created: metadata.created().ok(),
            length: metadata.len(),
            #[cfg(unix)]
            identity: (
                metadata.dev(),
                metadata.ino(),
                metadata.ctime(),
                metadata.ctime_nsec(),
            ),
        })
    }
}

/// One index per download batch. External directory-entry changes invalidate
/// it; exact-name races remain protected by atomic no-replace publication.
/// Case-fold collisions, as before, are a best-effort directory observation,
/// not an atomic exclusion against unrelated writers on case-sensitive disks.
pub struct DestinationIndex {
    directory: PathBuf,
    occupied: HashMap<String, PathBuf>,
    stamp: Option<DirectoryStamp>,
    #[cfg(test)]
    scans: usize,
}
impl DestinationIndex {
    pub fn new(directory: &Path) -> io::Result<Self> {
        let mut index = Self {
            directory: directory.to_path_buf(),
            occupied: HashMap::new(),
            stamp: None,
            #[cfg(test)]
            scans: 0,
        };
        index.refresh()?;
        Ok(index)
    }
    fn refresh(&mut self) -> io::Result<()> {
        let observed = DirectoryStamp::read(&self.directory)?;
        let precise = observed
            .modified
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|time| time.subsec_nanos() != 0)
            .unwrap_or(false);
        // Coarse timestamp filesystems retain conservative enumeration rather
        // than risk missing case-variant additions between publications.
        if precise && self.stamp.as_ref() == Some(&observed) {
            return Ok(());
        }
        // Do not bless a scan whose directory changed while being enumerated.
        // Under sustained external writes a later operation must scan again.
        for _ in 0..3 {
            let before = DirectoryStamp::read(&self.directory)?;
            let mut occupied = HashMap::new();
            for entry in fs::read_dir(&self.directory)? {
                let entry = entry?;
                occupied
                    .entry(entry.file_name().to_string_lossy().to_lowercase())
                    .or_insert_with(|| entry.path());
            }
            #[cfg(test)]
            {
                self.scans += 1;
            }
            let after = DirectoryStamp::read(&self.directory)?;
            self.occupied = occupied;
            self.stamp = if before == after { Some(after) } else { None };
            if self.stamp.is_some() {
                break;
            }
        }
        Ok(())
    }
    pub fn stage(&mut self) -> io::Result<StagedDownload> {
        self.refresh()?;
        let staged = StagedDownload::new(&self.directory)?;
        self.stamp = Some(DirectoryStamp::read(&self.directory)?);
        Ok(staged)
    }
    fn published(&mut self, source: &Path, target: &Path) -> io::Result<()> {
        if let Some(name) = source.file_name() {
            self.occupied.remove(&name.to_string_lossy().to_lowercase());
        }
        self.occupied.insert(
            target.file_name().unwrap().to_string_lossy().to_lowercase(),
            target.to_path_buf(),
        );
        self.stamp = Some(DirectoryStamp::read(&self.directory)?);
        Ok(())
    }
}

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
    #[cfg(test)]
    pub fn publish(&self, directory: &Path, key: &str, policy: &str) -> io::Result<PathBuf> {
        let mut index = DestinationIndex::new(directory)?;
        self.publish_with_index(&mut index, key, policy)
    }
    pub fn publish_with_index(
        &self,
        index: &mut DestinationIndex,
        key: &str,
        policy: &str,
    ) -> io::Result<PathBuf> {
        index.refresh()?;
        let directory = index.directory.clone();
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
        for suffix in 0..100000 {
            let candidate = if suffix == 0 {
                name.clone()
            } else {
                let ext = base
                    .extension()
                    .and_then(|x| x.to_str())
                    .map(|x| format!(".{x}"))
                    .unwrap_or_default();
                format!(
                    "{} ({suffix}){ext}",
                    base.file_stem().unwrap_or_default().to_string_lossy()
                )
            };
            let existing = index.occupied.get(&candidate.to_lowercase());
            if policy == "replace" {
                let target = existing
                    .cloned()
                    .unwrap_or_else(|| directory.join(&candidate));
                fs::rename(&self.0, &target)?;
                index.published(&self.0, &target)?;
                return Ok(target);
            }
            if existing.is_some() {
                continue;
            }
            let target = directory.join(candidate);
            match publish_no_replace(&self.0, &target) {
                Ok(()) => {
                    // The fallback hard link leaves the staging name behind.
                    // Remove it before recording our directory mutation.
                    let _ = fs::remove_file(&self.0);
                    index.published(&self.0, &target)?;
                    return Ok(target);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    index.stamp = None;
                    index.refresh()?;
                    continue;
                }
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Cannot allocate a unique download name",
        ))
    }
}

/// Publish a complete same-filesystem file without overwriting a concurrent
/// creator. Unlike hard links, these rename operations work on exFAT as well.
fn publish_no_replace(source: &Path, target: &Path) -> io::Result<()> {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let source_c = CString::new(source.as_os_str().as_bytes())?;
        let target_c = CString::new(target.as_os_str().as_bytes())?;
        #[cfg(target_os = "macos")]
        let result =
            unsafe { libc::renamex_np(source_c.as_ptr(), target_c.as_ptr(), libc::RENAME_EXCL) };
        #[cfg(target_os = "linux")]
        let result = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                libc::AT_FDCWD,
                source_c.as_ptr(),
                libc::AT_FDCWD,
                target_c.as_ptr(),
                libc::RENAME_NOREPLACE,
            ) as i32
        };
        if result == 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        // Older kernels/filesystems can still use the existing safe hard-link
        // path. Never fall back to an overwriting rename or visible partial copy.
        if matches!(
            error.raw_os_error(),
            Some(libc::ENOSYS | libc::EINVAL | libc::ENOTSUP)
        ) {
            return fs::hard_link(source, target);
        }
        return Err(error);
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        extern "system" {
            fn MoveFileExW(source: *const u16, target: *const u16, flags: u32) -> i32;
        }
        let source: Vec<_> = source.as_os_str().encode_wide().chain(Some(0)).collect();
        let target: Vec<_> = target.as_os_str().encode_wide().chain(Some(0)).collect();
        if unsafe { MoveFileExW(source.as_ptr(), target.as_ptr(), 0) } != 0 {
            return Ok(());
        }
        return Err(io::Error::last_os_error());
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
    fs::hard_link(source, target)
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
    fn batch_index_avoids_repeated_scans_and_invalidates_external_entries() {
        let directory = Directory::new();
        let mut index = DestinationIndex::new(&directory.0).unwrap();
        let initial_scans = index.scans;
        for number in 0..256 {
            let staged = index.stage().unwrap();
            fs::write(&staged.0, b"download").unwrap();
            staged
                .publish_with_index(&mut index, &format!("file-{number}.txt"), "keepBoth")
                .unwrap();
        }
        // Native test hosts have precise stamps. Coarse filesystems retain the
        // safe scan path, so assert the optimization only where supported.
        if index
            .stamp
            .as_ref()
            .unwrap()
            .modified
            .unwrap()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
            != 0
        {
            assert_eq!(index.scans, initial_scans);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
        fs::write(directory.0.join("EXTERNAL.txt"), b"external").unwrap();
        let staged = index.stage().unwrap();
        fs::write(&staged.0, b"download").unwrap();
        assert_eq!(
            staged
                .publish_with_index(&mut index, "external.txt", "keepBoth")
                .unwrap()
                .file_name()
                .unwrap(),
            "external (1).txt"
        );
        assert!(index.scans > initial_scans);
        assert_eq!(
            fs::read(directory.0.join("EXTERNAL.txt")).unwrap(),
            b"external"
        );
        let staged = index.stage().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        fs::write(directory.0.join("DURING.txt"), b"external").unwrap();
        assert_eq!(
            staged
                .publish_with_index(&mut index, "during.txt", "keepBoth")
                .unwrap()
                .file_name()
                .unwrap(),
            "during (1).txt"
        );
    }

    #[test]
    fn batch_replace_notices_external_case_variant_and_preserves_symlink_safety() {
        let directory = Directory::new();
        let mut index = DestinationIndex::new(&directory.0).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        fs::write(directory.0.join("EXTERNAL.txt"), b"external").unwrap();
        let staged = index.stage().unwrap();
        fs::write(&staged.0, b"download").unwrap();
        let target = staged
            .publish_with_index(&mut index, "external.txt", "replace")
            .unwrap();
        assert_eq!(target.file_name().unwrap(), "EXTERNAL.txt");
        assert_eq!(fs::read(target).unwrap(), b"download");
    }

    #[test]
    fn atomic_publication_refuses_concurrent_destination_and_preserves_source() {
        let directory = Directory::new();
        let staged = directory.staged();
        let target = directory.0.join("raced.txt");
        fs::write(&target, b"concurrent creator").unwrap();
        assert_eq!(
            publish_no_replace(&staged.0, &target).unwrap_err().kind(),
            io::ErrorKind::AlreadyExists
        );
        assert_eq!(fs::read(&target).unwrap(), b"concurrent creator");
        assert_eq!(fs::read(&staged.0).unwrap(), b"download");
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
