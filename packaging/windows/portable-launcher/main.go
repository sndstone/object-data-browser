package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func resolveCacheRoot() string {
	if custom := strings.TrimSpace(os.Getenv("ODB_PORTABLE_CACHE_DIR")); custom != "" {
		return custom
	}
	if localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); localAppData != "" {
		return filepath.Join(localAppData, "ObjectDataBrowserPortable")
	}
	if userCache, err := os.UserCacheDir(); err == nil && userCache != "" {
		return filepath.Join(userCache, "ObjectDataBrowserPortable")
	}
	return filepath.Join(os.TempDir(), "ObjectDataBrowserPortable")
}

func main() {
	exePath, err := os.Executable()
	if err != nil {
		showError("Object Data Browser Portable", fmt.Sprintf("Could not resolve executable path: %v", err))
		os.Exit(1)
	}
	if resolved, err := filepath.EvalSymlinks(exePath); err == nil {
		exePath = resolved
	}

	extractOnly := false
	noSplash := false
	var childArgs []string
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--odb-portable-extract-only":
			extractOnly = true
			noSplash = true
		case "--odb-portable-no-splash":
			noSplash = true
		default:
			childArgs = append(childArgs, arg)
		}
	}

	cacheRoot := resolveCacheRoot()

	// Peek at trailer to decide whether we need to show the first-launch splash.
	var updateSplash func(done, total int)
	closeSplash := func() {}
	if !noSplash {
		if f, err := os.Open(exePath); err == nil {
			if st, err := f.Stat(); err == nil {
				if t, err := ReadTrailer(f, st.Size()); err == nil {
					targetDir := filepath.Join(cacheRoot, CacheDirName(t))
					if !isCacheReady(targetDir, t.HexHash()) {
						updateSplash, closeSplash = startSplash(t.Version)
					}
				}
			}
			f.Close()
		}
	}

	appDir, _, err := EnsureExtracted(exePath, cacheRoot, updateSplash)
	closeSplash()
	if err != nil {
		showError("Object Data Browser Portable", fmt.Sprintf("Failed to prepare portable runtime:\n\n%v", err))
		os.Exit(1)
	}

	if extractOnly {
		fmt.Println(appDir)
		return
	}

	appExe := filepath.Join(appDir, appExeName)
	cmd := exec.Command(appExe, childArgs...)
	cmd.Dir = appDir
	pathDirs := []string{
		appDir,
		filepath.Join(appDir, "engines", "java", "runtime", "bin"),
		filepath.Join(appDir, "engines", "python"),
	}
	env := make([]string, 0, len(os.Environ())+4)
	pathUpdated := false
	for _, entry := range os.Environ() {
		if len(entry) >= 5 && strings.EqualFold(entry[:5], "PATH=") {
			env = append(env, "PATH="+strings.Join(pathDirs, string(os.PathListSeparator))+string(os.PathListSeparator)+entry[5:])
			pathUpdated = true
		} else {
			env = append(env, entry)
		}
	}
	if !pathUpdated {
		env = append(env, "PATH="+strings.Join(pathDirs, string(os.PathListSeparator)))
	}
	cmd.Env = append(
		env,
		"ODB_PORTABLE=1",
		"ODB_PORTABLE_EXE="+exePath,
		"ODB_PORTABLE_DIR="+appDir,
	)
	if err := cmd.Start(); err != nil {
		showError("Object Data Browser Portable", fmt.Sprintf("Failed to launch Object Data Browser:\n\n%v", err))
		os.Exit(1)
	}
}
