package main

import (
	"net/url"
	"strings"
	"testing"
)

func TestAzureContainerIsOnePathSegment(t *testing.T) {
	base, err := url.Parse("https://account.blob.core.windows.net")
	if err != nil {
		t.Fatal(err)
	}
	client := &azureClient{base: base}
	// Valid container names are unchanged, and keys keep their slashes.
	if got := client.urlFor("photos-2024", "a/b c.txt").EscapedPath(); got != "/photos-2024/a/b%20c.txt" {
		t.Fatalf("unexpected path %q", got)
	}
	// A name with a slash must not address a blob path in another container.
	got := client.urlFor("bucket/vault", "payroll.txt").EscapedPath()
	if strings.HasPrefix(got, "/bucket/vault/") || strings.Count(got, "/") != 2 {
		t.Fatalf("container was read as a path: %q", got)
	}
}
