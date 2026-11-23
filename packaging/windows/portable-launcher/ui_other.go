//go:build !windows

package main

import (
	"fmt"
	"os"
)

func showError(title, message string) {
	fmt.Fprintf(os.Stderr, "%s: %s\n", title, message)
}

func startSplash(version string) (func(done, total int), func()) {
	return func(done, total int) {}, func() {}
}
