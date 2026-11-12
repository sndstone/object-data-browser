package main

import (
	"errors"
	"golang.org/x/sys/unix"
	"os"
)

func renameDownloadNoReplace(from, to string) error {
	err := unix.Renameat2(unix.AT_FDCWD, from, unix.AT_FDCWD, to, unix.RENAME_NOREPLACE)
	if errors.Is(err, unix.ENOSYS) || errors.Is(err, unix.EINVAL) || errors.Is(err, unix.EOPNOTSUPP) {
		// Older kernels/filesystems may support hard links but not rename flags.
		return os.Link(from, to)
	}
	return err
}
