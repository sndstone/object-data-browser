package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"os"
	"path/filepath"
	"testing"
)

func buildFakePortableExe(t *testing.T, files map[string]string, version string) string {
	t.Helper()
	var zipBuf bytes.Buffer
	zw := zip.NewWriter(&zipBuf)
	for name, content := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("zip create %s: %v", name, err)
		}
		if _, err := w.Write([]byte(content)); err != nil {
			t.Fatalf("zip write %s: %v", name, err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("zip close: %v", err)
	}

	stub := []byte("MZ-FAKE-PE-STUB-DATA-0123456789")
	payload := zipBuf.Bytes()
	sum := sha256.Sum256(payload)
	trailer := Trailer{
		PayloadOffset: uint64(len(stub)),
		PayloadSize:   uint64(len(payload)),
		SHA256:        sum,
		Version:       version,
	}

	outPath := filepath.Join(t.TempDir(), "object-data-browser-portable.exe")
	var full bytes.Buffer
	full.Write(stub)
	full.Write(payload)
	full.Write(trailer.MarshalBinary())
	if err := os.WriteFile(outPath, full.Bytes(), 0o755); err != nil {
		t.Fatalf("write fake exe: %v", err)
	}
	return outPath
}

func TestExtractCacheHitAndPrune(t *testing.T) {
	exe := buildFakePortableExe(t, map[string]string{
		appExeName:                "fake-app",
		"engines/manifest.json":   `{"engines":[]}`,
		"engines/rust-raw/ok.txt": "raw-ok",
	}, "2.4.0-build5")
	cacheRoot := filepath.Join(t.TempDir(), "cache")
	staleDir := filepath.Join(cacheRoot, "2.3.0-oldhash000000")
	if err := os.MkdirAll(staleDir, 0o755); err != nil {
		t.Fatal(err)
	}

	var calls int
	dir1, hit1, err := EnsureExtracted(exe, cacheRoot, func(done, total int) {
		calls++
	})
	if err != nil {
		t.Fatalf("first extract failed: %v", err)
	}
	if hit1 {
		t.Fatalf("expected cache miss on first run")
	}
	if calls != 3 {
		t.Fatalf("expected 3 progress updates, got %d", calls)
	}
	if _, err := os.Stat(filepath.Join(dir1, "engines/rust-raw/ok.txt")); err != nil {
		t.Fatalf("extracted file missing: %v", err)
	}
	if _, err := os.Stat(staleDir); !os.IsNotExist(err) {
		t.Fatalf("expected stale cache dir to be pruned")
	}

	// Second run must hit cache instantly without re-extracting.
	calls = 0
	dir2, hit2, err := EnsureExtracted(exe, cacheRoot, func(done, total int) {
		calls++
	})
	if err != nil {
		t.Fatalf("second extract failed: %v", err)
	}
	if !hit2 || dir2 != dir1 || calls != 0 {
		t.Fatalf("expected instant cache hit (hit=%v dir=%s calls=%d)", hit2, dir2, calls)
	}
}

func TestRejectsCorruptChecksum(t *testing.T) {
	exe := buildFakePortableExe(t, map[string]string{
		appExeName: "fake-app",
	}, "2.4.0-build5")
	raw, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-trailerSize-5] ^= 0xFF
	if err := os.WriteFile(exe, raw, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, err := EnsureExtracted(exe, t.TempDir(), nil); err == nil {
		t.Fatalf("expected checksum mismatch error")
	}
}

func TestRejectsZipSlip(t *testing.T) {
	exe := buildFakePortableExe(t, map[string]string{
		appExeName:        "fake-app",
		"../evil-out.txt": "nope",
	}, "2.4.0-build5")
	if _, _, err := EnsureExtracted(exe, t.TempDir(), nil); err == nil {
		t.Fatalf("expected zip-slip error")
	}
}
