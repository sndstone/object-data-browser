package main

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const benchmarkHistoryLimit = 10000

var benchmarkCSVHeader = []string{"second", "operation", "operationCount", "latencyMs", "sizeBytes", "bytesTransferred", "success", "checksumState", "key", "elapsedMs", "timestamp", "timingSource"}

// Persist cumulative counters independently of the bounded diagnostic history.
// Older recovery files are upgraded once, while their complete history exists.
func benchmarkCumulativeMetrics(state map[string]interface{}) map[string]interface{} {
	if counters := asMap(state["cumulativeMetrics"]); counters != nil {
		return counters
	}
	counters := map[string]interface{}{
		"recordCount": 0, "operationCount": 0, "bytesTransferred": 0,
		"latencySumMs": 0.0, "operationsByType": map[string]interface{}{},
		"checksumStats": map[string]interface{}{"validated_success": 0, "validated_failure": 0, "not_used": 0},
	}
	for _, record := range asMapSlice(state["history"]) {
		addBenchmarkCumulativeRecord(counters, record)
	}
	state["cumulativeMetrics"] = counters
	return counters
}

func addBenchmarkCumulativeRecord(counters, record map[string]interface{}) {
	count := benchmarkOperationCount(record)
	counters["recordCount"] = asInt(counters["recordCount"]) + 1
	counters["operationCount"] = asInt(counters["operationCount"]) + count
	counters["bytesTransferred"] = asInt(counters["bytesTransferred"]) + asInt(record["bytesTransferred"])
	counters["latencySumMs"] = asFloat(counters["latencySumMs"]) + asFloat(record["latencyMs"])
	operations := asMap(counters["operationsByType"])
	operation := strings.ToUpper(asString(record["operation"]))
	operations[operation] = asInt(operations[operation]) + count
	checksums := asMap(counters["checksumStats"])
	checksum := asString(record["checksumState"])
	if checksum == "" {
		checksum = "not_used"
	}
	checksums[checksum] = asInt(checksums[checksum]) + count
}

func appendBenchmarkHistory(state, record map[string]interface{}) {
	counters := benchmarkCumulativeMetrics(state)
	// Open/backfill before adding this record, so recovery never duplicates it.
	stream, err := benchmarkCSV(state)
	if err == nil && stream != nil {
		err = stream.append(record)
	}
	if err != nil {
		state["_benchmarkCSVError"] = err
	}
	addBenchmarkCumulativeRecord(counters, record)
	history := asMapSlice(state["history"])
	history = append(history, record)
	if len(history) > benchmarkHistoryLimit {
		history[0] = nil // Release the evicted map even while the array is reused.
		history = history[len(history)-benchmarkHistoryLimit:]
	}
	state["history"] = history
}

type benchmarkCSVStream struct {
	file   *os.File
	buffer *bufio.Writer
	writer *csv.Writer
	fields int
	rows   int
}

func (stream *benchmarkCSVStream) append(record map[string]interface{}) error {
	elapsed, source := benchmarkRecordElapsed(record)
	row := []string{
		strconv.Itoa(asInt(record["second"])), asString(record["operation"]),
		strconv.Itoa(benchmarkOperationCount(record)), strconv.FormatFloat(asFloat(record["latencyMs"]), 'f', -1, 64),
		strconv.Itoa(asInt(record["sizeBytes"])), strconv.Itoa(asInt(record["bytesTransferred"])),
		strconv.FormatBool(asBool(record["success"]) || record["success"] == nil),
		asString(record["checksumState"]), asString(record["key"]),
		strconv.FormatFloat(elapsed, 'f', -1, 64), asString(record["timestamp"]), source,
	}
	if err := stream.writer.Write(row[:stream.fields]); err != nil {
		return err
	}
	stream.rows++
	return nil
}

func benchmarkCSV(state map[string]interface{}) (*benchmarkCSVStream, error) {
	if err, ok := state["_benchmarkCSVError"].(error); ok {
		return nil, err
	}
	if stream, ok := state["_benchmarkCSVStream"].(*benchmarkCSVStream); ok {
		return stream, nil
	}
	path := asString(asMap(state["config"])["csvOutputPath"])
	if path == "" {
		return nil, nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	ready := false
	defer func() {
		if !ready {
			file.Close()
		}
	}()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	fields, rows := len(benchmarkCSVHeader), 0
	if committed, present := state["csvCommittedBytes"]; present {
		offset := int64(asFloat(committed))
		if offset < 0 || offset > info.Size() {
			return nil, fmt.Errorf("benchmark CSV is shorter than its recovery checkpoint")
		}
		// Discard only an uncheckpointed crash tail before resuming this snapshot.
		if err = file.Truncate(offset); err != nil {
			return nil, err
		}
		if _, err = file.Seek(offset, io.SeekStart); err != nil {
			return nil, err
		}
		fields, rows = asInt(state["csvFieldCount"]), asInt(state["csvRecordCount"])
		if fields != 9 && fields != len(benchmarkCSVHeader) {
			return nil, fmt.Errorf("invalid benchmark CSV recovery schema")
		}
	} else if info.Size() > 0 {
		// A legacy checkpoint rewrote its entire CSV. Read its header and count
		// without loading it in memory; preserve its existing column schema.
		reader := csv.NewReader(file)
		header, readErr := reader.Read()
		if readErr != nil || (len(header) != 9 && len(header) != len(benchmarkCSVHeader)) || strings.Join(header, ",") != strings.Join(benchmarkCSVHeader[:len(header)], ",") {
			return nil, fmt.Errorf("unsupported existing benchmark CSV header")
		}
		fields = len(header)
		for {
			_, readErr = reader.Read()
			if readErr == io.EOF {
				break
			}
			if readErr != nil {
				return nil, fmt.Errorf("invalid existing benchmark CSV: %w", readErr)
			}
			rows++
		}
		if rows != asInt(benchmarkCumulativeMetrics(state)["recordCount"]) {
			return nil, fmt.Errorf("existing benchmark CSV does not match its recovery checkpoint")
		}
		if _, err = file.Seek(0, io.SeekEnd); err != nil {
			return nil, err
		}
	}
	buffer := bufio.NewWriterSize(file, 64*1024)
	stream := &benchmarkCSVStream{file: file, buffer: buffer, writer: csv.NewWriter(buffer), fields: fields, rows: rows}
	if info.Size() == 0 {
		history := asMapSlice(state["history"])
		if asInt(benchmarkCumulativeMetrics(state)["recordCount"]) != len(history) {
			return nil, fmt.Errorf("full benchmark CSV is missing; bounded history cannot reconstruct earlier operations")
		}
		if err = stream.writer.Write(benchmarkCSVHeader); err != nil {
			return nil, err
		}
		for _, record := range history {
			if err = stream.append(record); err != nil {
				return nil, err
			}
		}
	}
	state["_benchmarkCSVStream"] = stream
	ready = true
	return stream, nil
}

func flushBenchmarkCSV(state map[string]interface{}) error {
	stream, err := benchmarkCSV(state)
	if err != nil || stream == nil {
		return err
	}
	stream.writer.Flush()
	if err = stream.writer.Error(); err != nil {
		return err
	}
	if err = stream.buffer.Flush(); err != nil {
		return err
	}
	if err = stream.file.Sync(); err != nil {
		return err
	}
	offset, err := stream.file.Seek(0, io.SeekCurrent)
	if err != nil {
		return err
	}
	state["csvCommittedBytes"] = offset
	state["csvFieldCount"] = stream.fields
	state["csvRecordCount"] = stream.rows
	return nil
}

func closeBenchmarkCSV(state map[string]interface{}) {
	if stream, ok := state["_benchmarkCSVStream"].(*benchmarkCSVStream); ok {
		_ = stream.file.Close()
		delete(state, "_benchmarkCSVStream")
	}
}
