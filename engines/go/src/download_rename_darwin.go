package main

import "golang.org/x/sys/unix"

// Same-directory no-replace rename publishes complete files on filesystems
// such as exFAT that do not implement hard links.
func renameDownloadNoReplace(from, to string) error {
	return unix.RenamexNp(from, to, unix.RENAME_EXCL)
}
