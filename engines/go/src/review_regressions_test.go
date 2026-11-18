package main

import (
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSelectionDeleteBatchesAndPreservesEarlierOutcomes(t *testing.T) {
	for _, versions := range []bool{false, true} {
		calls := 0
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls++
			var body struct {
				Objects []struct {
					Key       string
					VersionId string
				} `xml:"Object"`
			}
			data, _ := io.ReadAll(r.Body)
			if err := xml.Unmarshal(data, &body); err != nil {
				t.Error(err)
			}
			if len(body.Objects) > 1000 {
				t.Errorf("oversized delete: %d", len(body.Objects))
			}
			if calls == 2 {
				xmlError(w, 403, "AccessDenied")
				return
			}
			fmt.Fprint(w, "<DeleteResult>")
			for _, item := range body.Objects {
				fmt.Fprintf(w, "<Deleted><Key>%s</Key><VersionId>%s</VersionId></Deleted>", item.Key, item.VersionId)
			}
			fmt.Fprint(w, "</DeleteResult>")
		}))
		params := map[string]interface{}{"profile": testProfilePayload(server.URL), "bucketName": "bucket"}
		keys := make([]interface{}, 1001)
		for i := range keys {
			if versions {
				keys[i] = map[string]interface{}{"key": fmt.Sprintf("key-%d", i), "versionId": "null"}
			} else {
				keys[i] = fmt.Sprintf("key-%d", i)
			}
		}
		var result map[string]interface{}
		var err error
		if versions {
			params["versions"] = keys
			result, err = deleteObjectVersions(params)
		} else {
			params["keys"] = keys
			result, err = deleteObjects(params)
		}
		server.Close()
		if err != nil {
			t.Fatal(err)
		}
		if calls != 2 || result["successCount"] != 1000 || result["failureCount"] != 1 {
			t.Fatalf("lost partial outcomes: %v, calls=%d", result, calls)
		}
	}
}

func TestEncodedListingKeysDecodeOnceAndKeepOpaqueCursor(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("encoding-type") != "url" {
			t.Error("missing XML-safe encoding")
		}
		io.WriteString(w, `<ListBucketResult><EncodingType>url</EncodingType><CommonPrefixes><Prefix>dir+one/</Prefix></CommonPrefixes><Contents><Key>a%252Fb%2B+%E9%9B%AA%01</Key><Size>1</Size></Contents><IsTruncated>true</IsTruncated><NextContinuationToken>opaque+%2F</NextContinuationToken></ListBucketResult>`)
	}))
	defer server.Close()
	result, err := listObjects(map[string]interface{}{"profile": testProfilePayload(server.URL), "bucketName": "bucket", "flat": true})
	if err != nil {
		t.Fatal(err)
	}
	items := result["items"].([]map[string]interface{})
	if len(items) != 2 || items[0]["key"] != "dir one/" || items[1]["key"] != "a%2Fb+ 雪\x01" {
		t.Fatalf("wrong list keys: %v", items)
	}
	if result["nextCursor"].(map[string]interface{})["value"] != "opaque+%2F" {
		t.Fatal("decoded opaque token")
	}
}

func TestEncodedVersionListingDecodesKeyMarkerOnly(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		if query.Has("key-marker") {
			if query.Get("key-marker") != "a + b" || query.Get("version-id-marker") != "v+%2F" {
				t.Errorf("wrong version request markers: %s", r.URL.RawQuery)
			}
			io.WriteString(w, `<ListVersionsResult><IsTruncated>false</IsTruncated></ListVersionsResult>`)
			return
		}
		io.WriteString(w, `<ListVersionsResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated><NextKeyMarker>a+%2B+b</NextKeyMarker><NextVersionIdMarker>v+%2F</NextVersionIdMarker><Version><Key>a+%2B+b</Key><VersionId>v+%2F</VersionId><Size>1</Size></Version><DeleteMarker><Key>a+%2B+b</Key><VersionId>removed</VersionId></DeleteMarker></ListVersionsResult>`)
	}))
	defer server.Close()
	params := map[string]interface{}{
		"profile": testProfilePayload(server.URL), "bucketName": "bucket", "key": "a + b",
	}
	result, err := listObjectVersions(params)
	if err != nil {
		t.Fatal(err)
	}
	items := result["items"].([]map[string]interface{})
	if len(items) != 2 || items[0]["key"] != "a + b" || items[1]["key"] != "a + b" {
		t.Fatalf("wrong version keys: %v", items)
	}
	params["cursor"] = result["cursor"]
	if next, err := listObjectVersions(params); err != nil || next["cursor"].(map[string]interface{})["hasMore"] != false {
		t.Fatalf("wrong second page: %v, %v", next, err)
	}
}
