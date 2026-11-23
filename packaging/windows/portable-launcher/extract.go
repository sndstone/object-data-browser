package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	trailerMagic   = "ODBPORT1"
	trailerSize    = 120
	versionBufSize = 64
	readyFileName  = ".odb-portable-ready"
	appExeName     = "s3_browser_crossplat.exe"
)

type Trailer struct {
	PayloadOffset uint64
	PayloadSize   uint64
	SHA256        [32]byte
	Version       string
}

func (t Trailer) MarshalBinary() []byte {
	buf := make([]byte, trailerSize)
	copy(buf[0:8], trailerMagic)
	binary.LittleEndian.PutUint64(buf[8:16], t.PayloadOffset)
	binary.LittleEndian.PutUint64(buf[16:24], t.PayloadSize)
	copy(buf[24:56], t.SHA256[:])
	v := t.Version
	if len(v) > versionBufSize {
		v = v[:versionBufSize]
	}
	copy(buf[56:120], v)
	return buf
}

func ReadTrailer(r io.ReadSeeker, fileSize int64) (Trailer, error) {
	if fileSize < trailerSize {
		return Trailer{}, errors.New("portable executable is truncated (missing trailer)")
	}
	if _, err := r.Seek(fileSize-trailerSize, io.SeekStart); err != nil {
		return Trailer{}, fmt.Errorf("seek trailer: %w", err)
	}
	buf := make([]byte, trailerSize)
	if _, err := io.ReadFull(r, buf); err != nil {
		return Trailer{}, fmt.Errorf("read trailer: %w", err)
	}
	if string(buf[0:8]) != trailerMagic {
		return Trailer{}, errors.New("portable payload trailer not found in executable")
	}
	offset := binary.LittleEndian.Uint64(buf[8:16])
	size := binary.LittleEndian.Uint64(buf[16:24])
	if size == 0 || offset == 0 {
		return Trailer{}, errors.New("invalid portable payload bounds")
	}
	if offset > uint64(fileSize) || size > uint64(fileSize)-offset || offset+size+trailerSize != uint64(fileSize) {
		return Trailer{}, errors.New("portable payload size does not match executable size (download may be incomplete)")
	}
	var sum [32]byte
	copy(sum[:], buf[24:56])
	version := strings.TrimRight(string(buf[56:120]), "\x00 ")
	if version == "" {
		version = "portable"
	}
	return Trailer{
		PayloadOffset: offset,
		PayloadSize:   size,
		SHA256:        sum,
		Version:       version,
	}, nil
}

func (t Trailer) HexHash() string {
	return hex.EncodeToString(t.SHA256[:])
}

func CacheDirName(t Trailer) string {
	var b strings.Builder
	for _, r := range t.Version {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '-' || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	ver := strings.Trim(b.String(), "._-")
	if ver == "" {
		ver = "portable"
	}
	return fmt.Sprintf("%s-%s", ver, t.HexHash()[:12])
}

func VerifyPayloadHash(r io.ReaderAt, t Trailer) error {
	sr := io.NewSectionReader(r, int64(t.PayloadOffset), int64(t.PayloadSize))
	h := sha256.New()
	if _, err := io.CopyBuffer(h, sr, make([]byte, 256*1024)); err != nil {
		return fmt.Errorf("hash payload: %w", err)
	}
	var got [32]byte
	copy(got[:], h.Sum(nil))
	if got != t.SHA256 {
		return errors.New("portable payload checksum mismatch (file may be corrupted)")
	}
	return nil
}

func isCacheReady(targetDir string, expectedHex string) bool {
	marker, err := os.ReadFile(filepath.Join(targetDir, readyFileName))
	if err != nil {
		return false
	}
	if strings.TrimSpace(string(marker)) != expectedHex {
		return false
	}
	if info, err := os.Stat(filepath.Join(targetDir, appExeName)); err != nil || info.IsDir() {
		return false
	}
	return true
}

func safeJoin(baseDir, entryName string) (string, error) {
	if entryName == "" || strings.HasPrefix(entryName, "/") || strings.HasPrefix(entryName, `\`) {
		return "", fmt.Errorf("invalid archive path: %q", entryName)
	}
	// Normalize zip forward slashes to OS path separators.
	rel := filepath.Clean(filepath.FromSlash(entryName))
	if rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) || filepath.IsAbs(rel) {
		return "", fmt.Errorf("archive path escapes target directory: %q", entryName)
	}
	// Guard against Windows drive letters like C:\foo inside zip entries.
	if len(rel) >= 2 && rel[1] == ':' {
		return "", fmt.Errorf("archive path contains drive prefix: %q", entryName)
	}
	dest := filepath.Join(baseDir, rel)
	baseClean := filepath.Clean(baseDir)
	if dest != baseClean && !strings.HasPrefix(dest, baseClean+string(os.PathSeparator)) {
		return "", fmt.Errorf("archive path escapes target directory: %q", entryName)
	}
	return dest, nil
}

func EnsureExtracted(exePath string, cacheRoot string, onProgress func(done, total int)) (string, bool, error) {
	f, err := os.Open(exePath)
	if err != nil {
		return "", false, fmt.Errorf("open portable executable: %w", err)
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return "", false, fmt.Errorf("stat portable executable: %w", err)
	}
	trailer, err := ReadTrailer(f, stat.Size())
	if err != nil {
		return "", false, err
	}

	dirName := CacheDirName(trailer)
	targetDir := filepath.Join(cacheRoot, dirName)
	expectedHex := trailer.HexHash()
	if isCacheReady(targetDir, expectedHex) {
		return targetDir, true, nil
	}

	if err := os.MkdirAll(cacheRoot, 0o755); err != nil {
		return "", false, fmt.Errorf("create cache directory: %w", err)
	}

	if err := VerifyPayloadHash(f, trailer); err != nil {
		return "", false, err
	}

	sr := io.NewSectionReader(f, int64(trailer.PayloadOffset), int64(trailer.PayloadSize))
	zr, err := zip.NewReader(sr, int64(trailer.PayloadSize))
	if err != nil {
		return "", false, fmt.Errorf("open embedded archive: %w", err)
	}

	stagingDir := filepath.Join(cacheRoot, fmt.Sprintf(".staging-%s-%d", expectedHex[:12], os.Getpid()))
	_ = os.RemoveAll(stagingDir)
	if err := os.MkdirAll(stagingDir, 0o755); err != nil {
		return "", false, fmt.Errorf("create staging directory: %w", err)
	}
	cleanupStaging := true
	defer func() {
		if cleanupStaging {
			_ = os.RemoveAll(stagingDir)
		}
	}()

	total := len(zr.File)
	copyBuf := make([]byte, 256*1024)
	for i, zf := range zr.File {
		dest, err := safeJoin(stagingDir, zf.Name)
		if err != nil {
			return "", false, err
		}
		if zf.FileInfo().IsDir() || strings.HasSuffix(zf.Name, "/") {
			if err := os.MkdirAll(dest, 0o755); err != nil {
				return "", false, fmt.Errorf("mkdir %s: %w", dest, err)
			}
		} else {
			if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
				return "", false, fmt.Errorf("mkdir parent %s: %w", dest, err)
			}
			rc, err := zf.Open()
			if err != nil {
				return "", false, fmt.Errorf("read %s from archive: %w", zf.Name, err)
			}
			out, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
			if err != nil {
				rc.Close()
				return "", false, fmt.Errorf("create %s: %w", dest, err)
			}
			_, copyErr := io.CopyBuffer(out, rc, copyBuf)
			closeOutErr := out.Close()
			rc.Close()
			if copyErr != nil {
				return "", false, fmt.Errorf("extract %s: %w", zf.Name, copyErr)
			}
			if closeOutErr != nil {
				return "", false, fmt.Errorf("close %s: %w", dest, closeOutErr)
			}
		}
		if onProgress != nil {
			onProgress(i+1, total)
		}
	}

	if err := os.WriteFile(filepath.Join(stagingDir, readyFileName), []byte(expectedHex+"\n"), 0o644); err != nil {
		return "", false, fmt.Errorf("write ready marker: %w", err)
	}

	if err := os.Rename(stagingDir, targetDir); err != nil {
		// Another instance may have extracted concurrently, or an incomplete old
		// target directory may exist.
		if isCacheReady(targetDir, expectedHex) {
			return targetDir, false, nil
		}
		_ = os.RemoveAll(targetDir)
		if err2 := os.Rename(stagingDir, targetDir); err2 != nil {
			return "", false, fmt.Errorf("finalize extraction to %s: %w", targetDir, err2)
		}
	}
	cleanupStaging = false

	pruneOldCaches(cacheRoot, dirName)
	return targetDir, false, nil
}

func pruneOldCaches(cacheRoot, keepName string) {
	entries, err := os.ReadDir(cacheRoot)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if name == keepName || strings.HasPrefix(name, ".staging-") {
			continue
		}
		_ = os.RemoveAll(filepath.Join(cacheRoot, name))
	}
}
