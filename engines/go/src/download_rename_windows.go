package main

import "golang.org/x/sys/windows"

func renameDownloadNoReplace(from, to string) error {
	source, err := windows.UTF16PtrFromString(from)
	if err != nil {
		return err
	}
	target, err := windows.UTF16PtrFromString(to)
	if err != nil {
		return err
	}
	// No REPLACE_EXISTING or COPY_ALLOWED: publication cannot overwrite or
	// expose a partially copied final path.
	return windows.MoveFileEx(source, target, windows.MOVEFILE_WRITE_THROUGH)
}
