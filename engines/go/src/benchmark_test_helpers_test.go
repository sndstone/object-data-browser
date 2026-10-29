package main

import (
	"os"
	"runtime"
	"testing"
)

func isolateBenchmarkTempDir(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	// Go uses TMP/TEMP on Windows and TMPDIR on Unix.
	for _, name := range []string{"TMPDIR", "TMP", "TEMP"} {
		t.Setenv(name, dir)
	}
}

func assertPrivateBenchmarkFile(t *testing.T, info os.FileInfo, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	// Windows FileMode describes read-only attributes, not Unix permissions.
	// This assertion does not qualify Windows ACL privacy.
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("benchmark file must remain private: mode %v", info.Mode())
	}
}
