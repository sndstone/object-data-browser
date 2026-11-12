//go:build !darwin && !linux && !windows

package main

import "os"

func renameDownloadNoReplace(from, to string) error { return os.Link(from, to) }
