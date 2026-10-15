package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func stageDownload(t *testing.T, directory string) string {
	t.Helper()
	file, err := os.CreateTemp(directory, ".odb-*.part")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.WriteString("NEW"); err != nil {
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(file.Name()) })
	return file.Name()
}

func TestPublishDownloadManyCaseInsensitiveCollisions(t *testing.T) {
	directory := t.TempDir()
	for i := 0; i < 1000; i++ {
		name := "REPORT.txt"
		if i > 0 {
			name = fmt.Sprintf("REPORT (%d).txt", i)
		}
		if err := os.WriteFile(filepath.Join(directory, name), []byte("LOCAL"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	temporary := stageDownload(t, directory)
	target, err := publishDownload(temporary, directory, "folder/report.txt", "keepBoth")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(target) != "report (1000).txt" {
		t.Fatalf("unexpected target: %s", target)
	}
	original, err := os.ReadFile(filepath.Join(directory, "REPORT.txt"))
	if err != nil || string(original) != "LOCAL" {
		t.Fatalf("original changed: %q %v", original, err)
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "NEW" {
		t.Fatalf("published bytes: %q %v", data, err)
	}
}

func TestPublishDownloadUnicodeFoldCollisions(t *testing.T) {
	// Simple folding includes characters not equivalent under strings.ToLower.
	for _, pair := range [][2]string{{"S.txt", "ſ.txt"}, {"K.txt", "K.txt"}, {"Σ.txt", "ς.txt"}} {
		t.Run(pair[1], func(t *testing.T) {
			directory := t.TempDir()
			if err := os.WriteFile(filepath.Join(directory, pair[0]), []byte("LOCAL"), 0600); err != nil {
				t.Fatal(err)
			}
			target, err := publishDownload(stageDownload(t, directory), directory, pair[1], "keepBoth")
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(filepath.Base(target), " (1)") {
				t.Fatalf("case-fold collision was not retained: %s", target)
			}
		})
	}
}

func TestPublishDownloadReplacementReplacesSymlinkNotReferent(t *testing.T) {
	directory := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.txt")
	if err := os.WriteFile(outside, []byte("LOCAL"), 0600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(directory, "EXISTING.txt")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	target, err := publishDownload(stageDownload(t, directory), directory, "a/existing.txt", "replace")
	if err != nil {
		t.Fatal(err)
	}
	if target != link {
		t.Fatalf("replacement did not match existing casing: %s", target)
	}
	original, err := os.ReadFile(outside)
	if err != nil || string(original) != "LOCAL" {
		t.Fatalf("symlink referent changed: %q %v", original, err)
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "NEW" {
		t.Fatalf("replacement bytes: %q %v", data, err)
	}
	info, err := os.Lstat(target)
	if err != nil || info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("replacement is still a symlink: %v", err)
	}
}

func TestPublishDownloadFlattensUnsafeKeys(t *testing.T) {
	for _, key := range []string{"../../escape.txt", `..\..\escape.txt`, "..", "a/", "NUL.txt"} {
		t.Run(key, func(t *testing.T) {
			directory := t.TempDir()
			target, err := publishDownload(stageDownload(t, directory), directory, key, "keepBoth")
			if err != nil {
				t.Fatal(err)
			}
			if filepath.Dir(target) != directory {
				t.Fatalf("escaped download directory: %s", target)
			}
			if filepath.Base(target) == "NUL.txt" {
				t.Fatal("reserved Windows basename was not escaped")
			}
		})
	}
}
