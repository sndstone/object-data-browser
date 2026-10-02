# Local S3 performance testing

`scripts/local-s3-performance.py` starts a real MinIO server bound to IPv4
loopback and points the Flutter application's `DesktopSidecarEngineService`
at it. The test uses the same process host, request serialization, transfer
methods, benchmark methods and engine binaries as the desktop app. It runs
headlessly; it does not measure widget rendering or native-window responsiveness.

Every invocation creates a private bucket and temporary data directory.
Random credentials are passed in memory and child environments. No application
state repository or Keychain is opened. The runner stops the server and removes
its storage on completion or failure. Results, logs and process-resource samples
remain in the requested output directory.

## Reproduce

Use a Python environment with the dependencies in
`engines/python/requirements.txt`, the repository Flutter SDK, a working MinIO
binary and a staged desktop `engines` directory containing `manifest.json`.
Rebuild/stage engines after changing their source; the harness executes the
specified binaries rather than compiling them.

The Homebrew MinIO binary on the test Mac crashed during `go-m1cpu`
initialization. A source build with cgo disabled worked:

```sh
mkdir -p .tmp/local-s3/bin
CGO_ENABLED=0 GOBIN="$PWD/.tmp/local-s3/bin" \
  .tmp/toolchains/go/bin/go install -p 4 \
  github.com/minio/minio@RELEASE.2025-10-15T17-29-55Z
```

This pins MinIO to commit `9e49d5e7a648`. The server is a local test dependency;
it is not bundled into the application. MinIO's source and license are available
in its [upstream repository](https://github.com/minio/minio/tree/RELEASE.2025-10-15T17-29-55Z).

Run a full comparison:

```sh
.tmp/toolchains/python/bin/python3 scripts/local-s3-performance.py \
  --server-binary .tmp/local-s3/bin/minio \
  --engine-root 'apps/flutter_app/build/macos/Build/Products/Release/Object Data Browser.app/Contents/Resources/engines' \
  --repetitions 3 --transfer-mib 256 --operations 1024
```

For a short smoke test, use `--repetitions 1 --transfer-mib 16 --operations 32`,
with `LOCAL_S3_BENCH_CONCURRENCY=1 LOCAL_S3_TRANSFER_CONCURRENCY=1` in the
environment. Output defaults to `.tmp/performance/<UTC timestamp>`;
`--output` selects a new directory. Normal `flutter test` skips this opt-in test.

## Workloads and interpretation

- Pure PUT benchmark: 64 KiB objects, concurrency 1/4/8, distinct keys and a
  fixed operation count. Each case independently lists its prefix and verifies
  object count and sizes after timing ends.
- Multipart upload and ranged download: 256 MiB file, 8 MiB parts/ranges,
  concurrency 1/4. SHA-256 verification occurs outside timed transfer windows.
- Three repetitions, engine order rotated between repetitions. Calls for
  different engines and workloads run sequentially to avoid mutual contention.
- The primary operation rate is completed operations divided by externally
  measured elapsed time, including service dispatch and status polling. The
  benchmark's own live headline may be a recent interval, so it is not used as
  the external comparison rate. The 2.3.0 Python/Go correction uses actual
  active elapsed time for cumulative averages and terminal headline rates.
- Process RSS and cumulative CPU time are sampled every 500 ms. This can miss
  brief peaks; RSS includes runtime allocations and retained histories.

The server and clients share this Mac's CPU, memory and SSD. HTTP loopback
excludes WAN latency, TLS overhead, remote rate limits and real cloud durability
behavior. Filesystem caches remain warm. These measurements characterize the
local application path; they are not S3 service limits or cloud throughput
predictions. No system-wide cache flush or privileged machine tuning is used.

The integrated benchmark includes scheduling, SDK work, state persistence and
result aggregation. Its small-object operation rate may therefore differ
substantially from the engine's bulk transfer rate. Benchmark error/retry summary
fields are not sufficient proof of success: the harness checks terminal status,
operation counts, server-visible objects and transferred content.

## Measured results — 2 October 2026

Apple M5 Pro, 24 GiB RAM, 15 logical CPUs, macOS 27.0. MinIO commit
`9e49d5e7a648`, built with Go 1.26.5 and `CGO_ENABLED=0`; local SSD, HTTP
loopback. These are medians of three repetitions. All engines use the same
256 MiB file, 8 MiB transfer parts/ranges and 64 KiB PUT workload.

Both the baseline and final matrix passed **108 timed cases and 60 independent
verification checks** each: 36,864 unique PUT objects, 24 file round trips
(6 GiB uploaded plus 6 GiB downloaded), and 1,200-object paginated listings.
The runner independently observed 38,064 remaining objects per server; transferred
files were deleted after their hash checks. Both private servers and data directories
were removed. All four engines connected through the real Flutter service; no mock
fallback, persisted profile, Keychain access, or remote storage account was used.

### Improvements measured against the baseline

| Change / workload | Before | After | Ratio |
| --- | ---: | ---: | ---: |
| Go PUT, 1 worker | 197.9 ops/s | 1,110.4 ops/s | 5.61× |
| Go PUT, 4 workers | 790.1 ops/s | 2,927.0 ops/s | 3.70× |
| Go PUT, 8 workers | 1,216.0 ops/s | 2,883.6 ops/s | 2.37× |
| Rust upload, 1 worker | 196.6 MiB/s | 427.3 MiB/s | 2.17× |
| Rust upload, 4 workers | 547.7 MiB/s | 1,393.0 MiB/s | 2.54× |

Go previously rebuilt full summaries and wrote report/state files after every
worker batch. It now checkpoints at most every 250 ms while keeping scheduling
and counters continuous. Completion, pause, stop and export force an up-to-date
checkpoint. Private clocks never reach state files or RPC output.

Rust previously used the SDK default 4 KiB file reader. Uploads now use a bounded
256 KiB reader, including retryable multipart file sections. Eight active workers
allow 2 MiB of reader-buffer capacity, excluding SDK/transport buffers. Exact
part offsets/lengths and abort-on-failure behavior remain covered by existing tests.

The baseline already includes the correctness fixes discovered while setting up
this test: Python/Go honor pure-write, pure-read and custom workloads; Go exposes
its benchmark capability for compatible endpoints and retains submillisecond latency.

### Earlier optimized rates

| Engine | PUT ops/s, 1 worker | 4 workers | 8 workers |
| --- | ---: | ---: | ---: |
| Python | 692.5 | 1,257.6 | 1,112.6 |
| Go | 1,110.4 | 2,927.0 | 2,883.6 |
| Rust | 898.8 | 2,549.8 | 2,719.5 |
| Java | 593.5 | 1,970.1 | 2,581.3 |

| Engine | Upload MiB/s, 1 worker | 4 workers | Download MiB/s, 1 worker | 4 workers |
| --- | ---: | ---: | ---: | ---: |
| Python | 405.4 | 1,302.6 | 2,346.2 | 2,785.5 |
| Go | 412.7 | 1,468.7 | 1,891.4 | 1,399.7 |
| Rust | 427.3 | 1,393.0 | 2,400.2 | 4,852.0 |
| Java | 473.8 | 1,620.1 | 2,516.4 | 4,934.1 |

Go explicitly syncs downloaded files to disk before publishing/completing them.
Rust and Java did not issue an equivalent forced disk sync in that earlier run;
2.3.0 adds durable completion in both engines, as measured below.
Download rates therefore include different durability costs and warm filesystem
caches; they must not be read as a pure network/SDK ranking. The Go slowdown at
four download workers remains a follow-up investigation, not a reason to remove
its durability check.

### Resources and remaining investigations

| Engine | Baseline sampled peak RSS MiB | Final sampled peak RSS MiB | Baseline / final CPU seconds |
| --- | ---: | ---: | ---: |
| Python | 148.9 | 169.7 | 12.57 / 12.57 |
| Go | 71.7 | 71.1 | 39.64 / 6.57 |
| Rust | 68.0 | 77.8 | 14.88 / 7.95 |
| Java | 598.0 | 660.6 | 18.26 / 18.64 |

These resource figures cover each engine process over the entire matrix, including
warmup, verification and retained histories. They are sampled observations, not
memory limits. MinIO peaked at about 593 MiB RSS in the final run. Subsecond
operations can fall entirely between samples.

The earlier run identified these follow-up priorities. The implementation work
below closes the buffer, executor/history, and benchmark-control gaps:

- Profile Go range read/write versus final sync separately; evaluate larger bounded
  write buffers while preserving durable completion.
- Reuse Java benchmark worker executors and reduce repeated history scans.
- Investigate Python small-object scaling: eight workers offered no gain over four
  here, while p95 request latency increased.
- Make ignored benchmark cache/pool/logging controls explicit and replace synthetic
  zero error/retry counters with measured values.
- Add latency/throttling/disconnect scenarios and separate AWS, compatible-provider
  and Azure qualification. This local run does not measure those environments.

### 2.3.0 complete application matrix

After the administration, recovery, mobile and benchmark-control additions, a
new matrix again passed **108 timed measurements and 60 verification checks**:
36,864 PUTs, 24 round trips of 256 MiB files, and 1,200-object listings. It used
the rebuilt 2.3.0 app's staged engines. Counts, content hashes and terminal
status were checked independently of the engine's reported rates.

| Engine | PUT ops/s, 1 worker | 4 workers | 8 workers | Upload MiB/s, 4 workers | Download MiB/s, 4 workers |
| --- | ---: | ---: | ---: | ---: | ---: |
| Python | 688.6 | 1,239.1 | 982.3 | 1,241.1 | 2,683.7 |
| Go | 1,112.0 | 2,175.4 | 2,895.6 | 1,369.0 | 1,553.6 |
| Rust | 898.0 | 2,454.0 | 2,695.9 | 1,380.2 | 1,687.7 |
| Java | 686.0 | 1,964.5 | 2,518.8 | 1,551.0 | 1,384.1 |

These are external wall-clock medians. Rust and Java now flush downloaded
content before completion; their lower download rates than the earlier table
include that durability change. Go uses a bounded larger read buffer. Java
reuses its worker executor, and Rust/Java cap retained operation history while
preserving full CSV output. All engines implement the selected payload/cache
controls and checksum algorithm rather than reporting placeholder results.

Sampled peak RSS was 177.1 MiB for Python, 90.9 MiB for Go, 149.6 MiB for Rust,
624.0 MiB for Java, and 595.4 MiB for MinIO. These are observations across this
run, including verification, rather than enforceable memory bounds.

This matrix exposed inaccurate Python/Go averages for partial-second runs and
Python's synthetic positions inside one-second history buckets. The final
reporting correction records actual completion timestamps, excludes paused
time from active duration, and bounds recent history at 10,000 operations while
retaining cumulative totals and the full CSV. Legacy bucket-only timestamps
remain explicitly approximate. The external rates above remain valid; a
separate run qualifies the final Python/Go correction.

The final Python/Go rerun passed **54 measurements and 30 verification checks**,
including 18,432 PUTs and twelve 256 MiB round trips. All eighteen benchmark
timelines retain the same measured completion times as their full CSVs, remain
inside actual runtime, and report cumulative average rates as operation count
divided by active elapsed time. Concurrent results may enter the log in a
different order from completion; the chart sorts by measured time and uses
record sequence only to break ties.

| Final engine | PUT ops/s, 1 worker | 4 workers | 8 workers | Upload MiB/s, 4 workers | Download MiB/s, 4 workers |
| --- | ---: | ---: | ---: | ---: | ---: |
| Python | 588.2 | 985.8 | 964.3 | 1,254.4 | 2,675.1 |
| Go | 976.9 | 2,124.5 | 2,838.9 | 1,356.2 | 1,602.1 |

These final external rates include the new complete CSV/cumulative-history
handling; the earlier optimized table is not substituted for these results.
Source fingerprints and ranges are in `release230ReportingFinal` in the
machine-readable evidence. Raw artifacts are in
`.tmp/performance/s3-reporting-230-20261002/`. Temporary servers and storage
were removed successfully after both release matrices.

The [machine-readable evidence](performance/local-s3-2026-10-02.json) includes
the `release230` run with exact engine/server fingerprints. Raw artifacts are
in `.tmp/performance/s3-release-230-20261002/`. Final application and emulator
checks are recorded in [2.3.0 verification](2.3.0-verification.md).

### Earlier evidence and validation

- [Machine-readable comparison](performance/local-s3-2026-10-02.json) retains all
  case medians/ranges, hardware and exact server/engine fingerprints.
- Raw JSONL, engine reports, process samples and logs are in
  `.tmp/performance/s3-full-20261002/` and
  `.tmp/performance/s3-optimized-20261002/`.
- Flutter analysis passed; 224 standard tests passed, with two pre-existing skips
  plus the opt-in local performance test skipped by the ordinary suite.
- Python contract suite: 90 passed, 25 engine-specific skips. Go shared suite:
  39 passed, 1 skipped; native race/checkpoint tests passed. Rust: 7 unit tests
  and 50 contract tests passed, 15 skips.
- Updated Python, Go and Rust adapters were copied into the existing macOS
  development app. All four packaged health checks and ad-hoc deep/strict
  signature verification passed; signed entitlements remain empty as required
  for the legacy-Keychain development build. The local MinIO server is not bundled.
