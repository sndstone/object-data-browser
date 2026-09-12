package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// A staged file is linked into place only after validation. Link fails rather
// than replacing a destination created concurrently (including a symlink).
func publishDownload(temporary, directory, key, policy string) (string, error) {
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
		entries, err := os.ReadDir(directory)
		if err != nil {
			return "", err
		}
		conflict := false
		for _, entry := range entries {
			if strings.EqualFold(entry.Name(), candidate) {
				if policy == "replace" {
					candidate = entry.Name()
				}
				conflict = true
				break
			}
		}
		if policy == "replace" {
			target := filepath.Join(directory, candidate)
			if err := os.Rename(temporary, target); err != nil {
				return "", err
			}
			return target, nil
		}
		if conflict {
			continue
		}
		target := filepath.Join(directory, candidate)
		if err = os.Link(temporary, target); os.IsExist(err) {
			continue
		} else if err != nil {
			return "", err
		}
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
