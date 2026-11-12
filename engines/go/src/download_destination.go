package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode"
)

// Use the same Unicode simple-fold equivalence as strings.EqualFold.
func downloadNameFold(name string) string {
	return strings.Map(func(r rune) rune {
		folded := r
		for next := unicode.SimpleFold(r); next != r; next = unicode.SimpleFold(next) {
			if next < folded {
				folded = next
			}
		}
		return folded
	}, name)
}

// A destination index is scoped to one batch. Atomic publication remains the
// authority for filenames created by another process after the initial scan.
type downloadDestination struct {
	directory string
	occupied  map[string]string
}

func newDownloadDestination(directory string) (*downloadDestination, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	occupied := make(map[string]string, len(entries))
	for _, entry := range entries {
		folded := downloadNameFold(entry.Name())
		if _, exists := occupied[folded]; !exists {
			occupied[folded] = entry.Name()
		}
	}
	return &downloadDestination{directory: directory, occupied: occupied}, nil
}
func publishDownload(temporary, directory, key, policy string) (string, error) {
	destination, err := newDownloadDestination(directory)
	if err != nil {
		return "", err
	}
	return destination.publish(temporary, key, policy)
}
func (destination *downloadDestination) publish(temporary, key, policy string) (string, error) {
	directory := destination.directory
	occupied := destination.occupied
	if policy != "" && policy != "keepBoth" && policy != "replace" {
		return "", fmt.Errorf("unknown download conflict policy")
	}
	name := filepath.Base(strings.ReplaceAll(key, "\\", "/"))
	name = strings.Map(func(r rune) rune {
		if r < 32 || strings.ContainsRune("<>:\"/\\|?*", r) {
			return '_'
		}
		return r
	}, name)
	name = strings.TrimRight(name, " .")
	if name == "" {
		name = "download"
	}
	if len(name) > 180 {
		name = string([]rune(name)[:min(len([]rune(name)), 60)])
	}
	stem := strings.ToUpper(strings.Split(name, ".")[0])
	if stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || (len(stem) == 4 && (strings.HasPrefix(stem, "COM") || strings.HasPrefix(stem, "LPT"))) {
		name = "_" + name
	}
	ext := filepath.Ext(name)
	for i := 0; i < 100000; i++ {
		candidate := name
		if i > 0 {
			candidate = fmt.Sprintf("%s (%d)%s", strings.TrimSuffix(name, ext), i, ext)
		}
		existing, conflict := occupied[downloadNameFold(candidate)]
		if policy == "replace" {
			if conflict {
				candidate = existing
			}
			target := filepath.Join(directory, candidate)
			if err := os.Rename(temporary, target); err != nil {
				return "", err
			}
			occupied[downloadNameFold(candidate)] = candidate
			return target, nil
		}
		if conflict {
			continue
		}
		target := filepath.Join(directory, candidate)
		if err := renameDownloadNoReplace(temporary, target); os.IsExist(err) {
			occupied[downloadNameFold(candidate)] = candidate
			continue
		} else if err != nil {
			return "", err
		}
		occupied[downloadNameFold(candidate)] = candidate
		return target, nil
	}
	return "", fmt.Errorf("cannot allocate a unique download name")
}

func optionalString(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}
