package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// A source must still be the prepared file, not a replacement or an edited
// snapshot. Metadata cannot detect adversarial edits restoring all metadata.
func verifyUploadSource(file *os.File, path string, prepared os.FileInfo) error {
	opened, err := file.Stat()
	if err != nil {
		return err
	}
	current, err := os.Stat(path)
	if err != nil {
		return err
	}
	if prepared == nil || !prepared.Mode().IsRegular() || !os.SameFile(prepared, opened) || !os.SameFile(opened, current) || opened.Size() != prepared.Size() || current.Size() != prepared.Size() || !opened.ModTime().Equal(prepared.ModTime()) || !current.ModTime().Equal(prepared.ModTime()) {
		return &sidecarError{Code: "object_conflict", Message: fmt.Sprintf("Upload source changed: %s. Check the destination before retrying a single-request upload.", path)}
	}
	return nil
}

type transferProgressGate struct {
	mu       sync.Mutex
	previous time.Time
	interval time.Duration
}

func newTransferProgressGate(params map[string]interface{}) *transferProgressGate {
	ms := asInt(params["progressIntervalMs"])
	if ms == 0 {
		ms = 100
	}
	ms = max(50, min(2000, ms))
	return &transferProgressGate{interval: time.Duration(ms) * time.Millisecond}
}
func (gate *transferProgressGate) ready(force bool) bool {
	gate.mu.Lock()
	defer gate.mu.Unlock()
	now := time.Now()
	if !force && !gate.previous.IsZero() && now.Sub(gate.previous) < gate.interval {
		return false
	}
	gate.previous = now
	return true
}

func decodeVersionCursor(cursor map[string]interface{}) (string, string, error) {
	value := asString(cursor["value"])
	if value == "" {
		return "", "", nil
	}
	var markers map[string]string
	if err := json.Unmarshal([]byte(value), &markers); err != nil {
		// The original protocol allowed a bare key marker. Preserve it unless
		// the input purports to be a malformed paired-marker object.
		if len(value) > 0 && value[0] == '{' {
			return "", "", &sidecarError{Code: "invalid_config", Message: "Invalid version listing cursor."}
		}
		return value, "", nil
	}
	if markers["keyMarker"] == "" && markers["versionIdMarker"] == "" {
		return "", "", &sidecarError{Code: "invalid_config", Message: "Version listing cursor has no continuation markers."}
	}
	return markers["keyMarker"], markers["versionIdMarker"], nil
}

func encodeVersionCursor(truncated bool, key, version, previousKey, previousVersion string) (map[string]interface{}, error) {
	if !truncated {
		return map[string]interface{}{"value": nil, "hasMore": false}, nil
	}
	if (key == "" && version == "") || (key == previousKey && version == previousVersion) {
		return nil, &sidecarError{Code: "invalid_response", Message: "S3 returned missing or repeated version listing markers."}
	}
	encoded, err := json.Marshal(map[string]string{"keyMarker": key, "versionIdMarker": version})
	if err != nil {
		return nil, err
	}
	return map[string]interface{}{"value": string(encoded), "hasMore": true}, nil
}
