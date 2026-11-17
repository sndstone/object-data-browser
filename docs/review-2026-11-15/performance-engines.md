## Summary

The primary 2.3.5 fixes are present: ordinary S3 transfers stream data, transfer dispatch is bounded, and listing methods return individual pages. The highest-value remaining problems are Python API logging consuming streaming responses, whole-range buffering in recoverable downloads, unbounded request admission, and retained Python benchmark caches. Go still lacks range-body retries and applies whole-request deadlines to healthy transfers. Several fixes are only partially applied across engines, especially progress coalescing, cancellation cleanup, and benchmark control responsiveness. This was a static, read-only review; memory calculations below are source-derived estimates, not measured RSS.

## Findings

1. **Python API logging consumes and buffers download bodies** — severity **high**, effort **S**, confidence **confirmed**

   **Where:** `engines/python/src/main.py:466`, `engines/python/src/main.py:552`, `engines/python/src/main.py:558`. Supporting installed dependency: `.tmp/toolchains/python/lib/python3.12/site-packages/botocore/awsrequest.py:571`.

   **What happens now:** With API logging enabled, the `after-call.s3` handler accesses `http_response.content` before checking the preview size. Botocore implements that property by joining the entire raw response stream. For `GetObject`, this consumes the stream that the transfer subsequently reads.

   **Why it matters:** Logging defeats bounded downloads and can cause incomplete-body failures. Eight concurrent 128 MiB ranges can retain approximately **1 GiB** of response content, with additional transient allocation during joining. A non-ranged GET can buffer the entire object.

   **Proposed change:** In `_log_http_receive`, detect streaming operations through `model.has_streaming_output`; log headers and a streaming-body marker without accessing `.content`. Keep body previews limited to already-buffered, bounded administrative responses.

   **Measure:** Download 10 GiB using 128 MiB ranges and concurrency 8, with API logging disabled/enabled; compare completion, peak RSS, and bytes read by the transfer.

2. **Recoverable Python downloads still buffer complete ranges** — severity **high**, effort **M**, confidence **confirmed**

   **Where:** `engines/python/src/advanced_workflows.py:884`, `engines/python/src/advanced_workflows.py:937`, `engines/python/src/advanced_workflows.py:957`, `engines/python/src/advanced_workflows.py:964`, `engines/python/src/advanced_workflows.py:969`; `engines/python/src/main.py:2893`.

   **What happens now:** `Workflows.execute_download` reads each range into one `bytes` value and returns it through a future. Resume validation also reads each completed range into memory. The scheduler retains completed futures while refilling the next window.

   **Why it matters:** At eight workers, default 8 MiB ranges require **64 MiB** for one completed window; 128 MiB ranges require **1 GiB**. Old completed results and a newly filled window can overlap, approaching twice those payload amounts before SDK overhead.

   **Proposed change:** Port `_read_range_with_retry` into this workflow: stream bounded blocks to positional file writes and hash incrementally. Return only range identity, length, and digest. Preserve data-before-checkpoint durability and validators.

   **Measure:** Compare peak RSS during resumable downloads with 8/128 MiB ranges at concurrency 8, including resume validation.

3. **Request admission remains unbounded above bounded transfer workers** — severity **high**, effort **M**, confidence **confirmed**

   **Where:** `engines/python/src/main.py:6108`, `engines/python/src/main.py:6117`; `engines/java/src/main/java/com/example/s3browser/Main.java:212`, `engines/java/src/main/java/com/example/s3browser/Main.java:231`; `engines/rust/src/main.rs:226`, `engines/rust/src/main.rs:229`.

   **What happens now:** Python and Java submit requests into executors with unbounded queues. Rust spawns each request task before acquiring its eight-request semaphore. Requests retain input strings or parsed payloads while waiting. Python, Java, and Rust also frame input lines without a byte limit.

   **Why it matters:** The transfer scheduler fixes do not bound process memory during request bursts. Go has a 64 MiB input-frame limit and synchronous admission; the other engines lack equivalent protection.

   **Proposed change:** Add a bounded admission queue and byte-limited framing. Reserve an independent control path so pause/resume/cancel cannot become blocked behind transfers. Document limits and overload responses in `contracts/transport_contract.md:5` and the request schema at `contracts/engine_contract.json:64`.

   **Measure:** Hold eight requests open against a delayed fixture, then submit thousands of additional requests; track queued work and RSS.

4. **Completed Python benchmarks retain their payload caches indefinitely** — severity **high**, effort **S**, confidence **confirmed**

   **Where:** `engines/python/src/main.py:4875`, `engines/python/src/main.py:4897`, `engines/python/src/main.py:4996`, `engines/python/src/main.py:5035`.

   **What happens now:** `_BENCHMARKS` retains every `_BenchmarkRun`. Terminal cleanup clears `profile` but retains `payload_store`, its cached bytes, the client, state, and thread references.

   **Why it matters:** Each completed run can retain its populated cache, configured up to **1,024 MiB**, until the process exits. Repeated benchmarks accumulate memory despite per-run cache bounds.

   **Proposed change:** After all workers drain, release the payload cache/client and remove the live owner, serving historical status from persisted state. Preserve paused-run ownership separately. Go already releases its payload store at `engines/go/src/benchmark_owner.go:159`; Rust removes terminal owners at `engines/rust/src/main.rs:2364`.

   **Measure:** Run several cache-filling benchmarks consecutively in one process; inspect RSS after each terminal response.

5. **Whole-request deadlines still terminate healthy slow transfers** — severity **high**, effort **M**, confidence **confirmed**

   **Where:** `engines/go/src/main.go:379`, `engines/go/src/azure.go:103`; `engines/java/src/main/java/com/example/s3browser/Main.java:2063`.

   **What happens now:** Go sets `http.Client.Timeout` to connect timeout plus read timeout, including body transfer. Java sets `apiCallAttemptTimeout` to the read timeout, including upload-body execution.

   **Why it matters:** With defaults, Go allows approximately 65 seconds per request. A 128 MiB part below approximately **1.97 MiB/s** exceeds that deadline despite continuous progress. Java uploads face a 60-second attempt deadline. Retrying wastes transmitted data.

   **Proposed change:** Separate connect/header deadlines from body inactivity detection. Retain a stall deadline driven by actual byte movement and bounded cancellation.

   **Measure:** Throttle uploads/downloads to 1 MiB/s while continuously delivering bytes; distinguish healthy completion from a deliberately stalled connection.

6. **Go lacks the range-body recovery implemented by the other engines** — severity **high**, effort **M**, confidence **confirmed**

   **Where:** `engines/go/src/main.go:1878`, `engines/go/src/main.go:1900`; `engines/go/src/azure.go:1247`, `engines/go/src/azure.go:1258`.

   **What happens now:** S3 and Azure range downloads perform one body copy. A mid-body error cancels the transfer and discards the staged download.

   **Why it matters:** A reset near the end of a large download loses all completed ranges. SDK request retries do not replace an application retry around an already-returned response body.

   **Proposed change:** Port the behavior of Python `_read_range_with_retry` (`main.py:1671`), Rust `download_object_ranged` (`main.rs:1798`), or Java `RangedDownload.transfer` (`RangedDownload.java:27`). Reopen the same validated range, rewrite its offset, and commit progress once.

   **Measure:** Reset one range halfway through a 10 GiB download; verify only that range repeats in endpoint access logs.

7. **Java bounded-task cleanup cancels futures without draining workers** — severity **high**, effort **M**, confidence **confirmed**

   **Where:** `engines/java/src/main/java/com/example/s3browser/BoundedTasks.java:39`; `engines/java/src/main/java/com/example/s3browser/Main.java:1311`, `engines/java/src/main/java/com/example/s3browser/Main.java:1494`.

   **What happens now:** `BoundedTasks.close` calls `Future.cancel(true)` and clears references. Transfer cleanup calls `shutdownNow()` without awaiting worker termination. Enclosing resources can close and the terminal response can be produced before callables have exited.

   **Why it matters:** Cancellation does not establish that network requests, response bodies, or file operations have stopped. This falls short of the terminal-cleanup contract at `contracts/transport_contract.md:37`.

   **Proposed change:** Track callable completion separately from future cancellation and drain workers before closing shared sources/destinations or returning terminal state. Rust `run_bounded` explicitly aborts and drains at `engines/rust/src/transfer_workers.rs:31`.

   **Measure:** Cancel while a fixture blocks a body read and delays interruption handling; verify no worker/body/file handle survives the terminal response.

8. **Some bulk paths still allocate every future upfront** — severity **medium**, effort **S**, confidence **confirmed**

   **Where:** `engines/python/src/main.py:3697`, `engines/python/src/main.py:2016`, `engines/python/src/main.py:5322`; `engines/java/src/main/java/com/example/s3browser/Main.java:1613`.

   **What happens now:** Python S3/Azure `runPutTestData`, Python recoverable S3 uploads, and Java `runPutTestData` retain a future for every object or part.

   **Why it matters:** Million-object test-data jobs allocate million-entry task/future populations despite limited active workers. Recoverable uploads retain up to 10,000 part futures. This is an incomplete application of the previous bounded-dispatch work.

   **Proposed change:** Use Python `_bounded_parallel` and Java `BoundedTasks`, including the draining correction above. Rust `run_put_test_data` already uses `run_bounded` at `engines/rust/src/main.rs:2168`; Go acquires its semaphore before spawning at `engines/go/src/main.go:2137`.

   **Measure:** Use a slow fixture with one million logical objects; compare pending-task count and RSS before substantial network completion.

9. **Python log deltas reduce traffic but do not bound retained transfer output** — severity **medium**, effort **M**, confidence **confirmed**

   **Where:** `engines/python/src/main.py:3271`, `engines/python/src/main.py:3502`, `engines/python/src/main.py:3093`, `engines/python/src/main.py:3582`, `engines/python/src/main.py:6078`.

   **What happens now:** Python retains one string per completed upload part/download range. Incremental events slice the list, but the final response still includes the entire list and encodes it as one JSON string.

   **Why it matters:** A 1 TiB download at 8 MiB ranges creates **131,072 range lines**. Memory grows with job length, and final serialization temporarily adds another large representation. Go, Rust, and Java cap per-part lines at 64.

   **Proposed change:** Spool complete output to a bounded-access log store, retain only a small live window, and expose sequenced retrieval/export so existing log access remains available. Extend the transport contract for that access.

   **Measure:** Download a synthetic large logical object; record retained log bytes, final response size, serialization time, and RSS.

10. **Rust and Java benchmark controls wait behind network execution** — severity **medium**, effort **M**, confidence **confirmed**

    **Where:** `engines/rust/src/main.rs:2343`, `engines/rust/src/main.rs:2375`, `engines/rust/src/main.rs:2381`; `engines/java/src/main/java/com/example/s3browser/Main.java:1818`, `engines/java/src/main/java/com/example/s3browser/Main.java:1868`, `engines/java/src/main/java/com/example/s3browser/Main.java:1875`.

    **What happens now:** Both workers hold the benchmark-state lock while executing and persisting network batches. Status, pause, and stop require the same lock.

    **Why it matters:** A blocked request makes benchmark controls appear frozen until the request settles. The nominal batch time budget cannot interrupt an individual network call.

    **Proposed change:** Port Go’s independently accessible published snapshot and pending-control mechanism from `engines/go/src/benchmark_owner.go:39`. Acknowledge control immediately, then account for already-dispatched operations before settlement.

    **Measure:** Block one benchmark request for 30 seconds and measure status/pause/stop acknowledgment latency.

11. **Python Azure still reduces concurrency according to whole-part memory assumptions** — severity **medium**, effort **S**, confidence **confirmed**

    **Where:** `engines/python/src/main.py:1531`, `engines/python/src/main.py:1535`, `engines/python/src/main.py:1913`, `engines/python/src/main.py:1915`.

    **What happens now:** Azure upload/download workers are capped by `256 MiB / partSize`, although uploads now use `_FilePart` and downloads stream 1 MiB blocks.

    **Why it matters:** A 128 MiB part permits only **two workers**, even when eight are configured. Larger permitted parts can reduce execution to one worker without a corresponding resident part allocation.

    **Proposed change:** Size concurrency against actual streaming buffers and the connection limit, using the ordinary S3 worker policy. Retain a separate byte budget for genuinely buffered workflows.

    **Measure:** Transfer with 128 MiB parts and concurrency 8; compare active requests and throughput before/after removing the stale calculation.

12. **Go Azure downloads bypass progress coalescing** — severity **medium**, effort **S**, confidence **confirmed**

    **Where:** `engines/go/src/azure.go:1273`, `engines/go/src/azure.go:1297`; efficient counterpart: `engines/go/src/main.go:1954`.

    **What happens now:** Azure emits a complete job snapshot after each single-stream read and each completed range. The supplied progress interval is not consulted.

    **Why it matters:** Small socket reads produce excessive JSON allocation, stdout traffic, and Flutter parsing. This remains open from the earlier progress-traffic review.

    **Proposed change:** Apply `newTransferProgressGate(params)` before constructing snapshots in both Azure paths, preserving immediate queued/terminal responses.

    **Measure:** Serve small response chunks and compare event count, IPC bytes, CPU, and transfer throughput at a 100 ms interval.

13. **Benchmark “in-memory” mode can write every large PUT payload to disk** — severity **medium**, effort **M**, confidence **confirmed**

    **Where:** `engines/python/src/main.py:4543`, `engines/python/src/main.py:4561`; `engines/rust/src/benchmark_runtime.rs:149`, `engines/rust/src/benchmark_runtime.rs:174`; `engines/java/src/main/java/com/example/s3browser/BenchmarkRuntime.java:88`, `engines/java/src/main/java/com/example/s3browser/BenchmarkRuntime.java:108`.

    **What happens now:** Payloads exceeding cache-entry thresholds are generated into temporary files even when `inMemoryData` is true.

    **Why it matters:** Every large PUT can add a full local write and subsequent read. Network benchmark throughput becomes dependent on local storage, free space, and cache behavior.

    **Proposed change:** Port Go’s repeatable generated reader from `engines/go/src/benchmark_data.go:81` and its no-cache fallback at line 172. Keep explicit file-backed mode available.

    **Measure:** Run repeated 256 MiB PUTs with cache disabled and in-memory mode enabled; record temporary-file writes and storage throughput.

14. **Benchmark latency boundaries differ across engines** — severity **medium**, effort **M**, confidence **confirmed**

    **Where:** Python `engines/python/src/main.py:4705`, `engines/python/src/main.py:4739`; Go `engines/go/src/main.go:3080`, `engines/go/src/main.go:3115`; Rust `engines/rust/src/main.rs:3727`, `engines/rust/src/main.rs:3730`; Java `engines/java/src/main/java/com/example/s3browser/Main.java:2858`, `engines/java/src/main/java/com/example/s3browser/Main.java:2873`.

    **What happens now:** Python and Go start PUT latency after payload preparation; Rust and Java include preparation. Python ends GET latency before generating/hashing expected content, while Go, Rust, and Java include that work. Java additionally includes active-object bookkeeping in PUT latency.

    **Why it matters:** Engine comparisons measure different operations. Cache misses, temporary-file generation, checksum choice, and active-object count can change rankings independently of storage performance.

    **Proposed change:** Define identical monotonic timing boundaries in the benchmark contract. Report preparation, transfer, and validation separately, while retaining end-to-end throughput.

    **Measure:** Compare cache-hit/miss PUTs and checksum-enabled/disabled GETs against the same loopback fixture.

15. **Benchmark planning and result handling repeatedly copy active-object collections** — severity **medium**, effort **M**, confidence **confirmed**

    **Where:** `engines/python/src/main.py:4676`, `engines/python/src/main.py:4211`; `engines/rust/src/main.rs:3557`, `engines/rust/src/main.rs:3590`, `engines/rust/src/main.rs:3996`; `engines/java/src/main/java/com/example/s3browser/Main.java:2732`, `engines/java/src/main/java/com/example/s3browser/Main.java:2749`, `engines/java/src/main/java/com/example/s3browser/Main.java:2837`.

    **What happens now:** Python copies active records per operation and linearly searches on upsert. Rust clones the active array during planning and result application, with shifting `Vec.remove` operations. Java copies and redistributes active records into shards every batch, then copies shard records again.

    **Why it matters:** Small-object benchmarks increasingly measure allocation and collection management as active-object count grows.

    **Proposed change:** Maintain indexed active records and reserve stable entry IDs for each batch. Preserve operation order, key selection, and race avoidance without copying all records.

    **Measure:** Hold object size and endpoint latency constant while increasing active objects from 1,000 to 100,000; profile planner CPU, allocations, and achieved operations/second.

16. **Java stops caching new client configurations after the first sixteen** — severity **medium**, effort **M**, confidence **confirmed**

    **Where:** `engines/java/src/main/java/com/example/s3browser/Main.java:1991`, `engines/java/src/main/java/com/example/s3browser/Main.java:1995`.

    **What happens now:** Once `CLIENTS` contains sixteen configurations, every new configuration receives an uncached client. The first sixteen remain permanently cached. Client construction also occurs under the global synchronized method.

    **Why it matters:** Repeated requests using a seventeenth configuration repeatedly construct SDK clients and connection pools. A slow cold initialization blocks unrelated warm cache hits.

    **Proposed change:** Use a bounded cache with active leases and idle eviction; construct candidates outside the global lock. Python `_build_client` already keeps initialization outside its cache lock at `engines/python/src/main.py:377`.

    **Measure:** Warm sixteen configurations, repeatedly access a seventeenth, and count client constructions/TLS connections. Concurrently measure a warm lookup during delayed cold initialization.

17. **Exact-key version listings continue through unrelated suffix keys** — severity **medium**, effort **S**, confidence **confirmed**

    **Where:** `engines/python/src/main.py:2674`, `engines/python/src/main.py:2712`, `engines/python/src/main.py:2744`; `engines/go/src/main.go:1247`, `engines/go/src/main.go:1260`, `engines/go/src/main.go:1307`; `engines/rust/src/main.rs:954`, `engines/rust/src/main.rs:976`, `engines/rust/src/main.rs:1015`; `engines/java/src/main/java/com/example/s3browser/Main.java:918`, `engines/java/src/main/java/com/example/s3browser/Main.java:940`.

    **What happens now:** Exact-key inspection uses S3 `Prefix=key`, filters other keys locally, and forwards the provider’s continuation even after listing has advanced beyond the selected key.

    **Why it matters:** Inspecting `a` can continue through versions of `a/...` and `abc...`, returning empty pages. One million matching-prefix entries can require approximately **1,000 requests** despite few versions of `a`.

    **Proposed change:** For exact-key mode, terminate continuation once the returned keys or next key marker prove traversal has passed the selected key. Preserve continuation when additional versions of that exact key remain.

    **Measure:** Create a selected key with a few versions plus a large suffix-key population; count version-list requests until completion.

## Checked and fine

- **Ordinary S3 uploads stream rather than allocating eight whole parts.** Python uses `_FilePart` (`main.py:3237`), Go uses `io.NewSectionReader` (`main.go:1651`), Rust uses bounded `ByteStream` readers (`main.rs:1463`), and Java uses `FilePartStream` (`Main.java:1325`).
- **Per-transfer dispatch bounds are implemented.** Python `_bounded_parallel`, Go semaphore/fixed-worker dispatch, Rust `run_bounded`, and Java `BoundedTasks` limit pending transfer work. Findings above identify remaining callers and cleanup gaps.
- **Memory calculation:** Default profile concurrency is 10; ordinary part workers cap at 8 in every engine. Increasing configured concurrency beyond 8 therefore leaves the following per-job calculations unchanged:

  | Engine | Explicit ordinary ranged-download buffers at 8 workers | Explicit upload buffering |
  | --- | ---: | --- |
  | Python | Approximately 8 MiB of current blocks, plus transient replacement blocks | File views; SDK-controlled reads |
  | Go | 8 MiB copy buffers | Section readers; SDK-controlled buffers |
  | Rust | SDK response chunks; no whole-range allocation | 2 MiB of configured file-reader buffers |
  | Java | 8 MiB read buffers | File streams; SDK-controlled buffers |

  These exclude SDK/TLS buffers, runtime heaps, logs, caches, and concurrent jobs. They are **not total RSS bounds**. Eight fully buffered 128 MiB parts would equal **1 GiB**; ordinary upload code avoids that multiplication. Python diagnostic logging and recoverable downloads reintroduce it as described above.

- **Object listing is page-bounded:** all four S3 engines request at most 1,000 entries, apply `/` only for hierarchical listing, and sort only the returned page. A flat one-million-object traversal normally requires approximately 1,000 list requests, without engine-side accumulation of all million entries. Anchors: Python `main.py:2364`, Go `main.go:763`, Rust `main.rs:687`, Java `Main.java:664`.
- **Version cursors retain paired markers.** The previous Go first-page-only defect is fixed at `main.go:1242` and `main.go:1307`.
- **Successful-path S3 request counts**, excluding retries, credentials discovery, and optional diagnostics:

  | Operation | Request count |
  | --- | --- |
  | Single upload | 1 PUT |
  | Multipart upload with K parts | K + 2 |
  | Download with K GET ranges | 1 HEAD + K GETs |
  | Ordinary small copy, Go/Rust/Java | 1 HEAD + 1 COPY |
  | Ordinary small copy, Python defaults | HEAD + tagging GET + COPY + destination HEAD |
  | Successful move | Copy requests + 1 conditional DELETE |
  | Ordinary batch delete of N entries | ceil(N / 1,000) |
  | Object/version list page | 1 LIST |

  Python’s additional copy calls preserve tags and verify destination size; removing verification would require a separate correctness decision.

- **Client reuse exists in every engine.** No general per-operation client-construction defect was found beyond the Java cache behavior reported above.
- **Presigning does not download object bodies.** Python, Go, and Rust reuse their storage client; Java constructs a presigner. Credential refresh may still require authentication traffic.
- **Runtime trimming is implemented:** staging delegates Python/Java payload preparation to `runtime-payload.py`; the old full-toolchain packaging findings should not be repeated.
- No files were changed, staged, or deleted. No builds, tests, installs, network operations, or remote repository writes were performed. No disposable artifacts were created; cleanup freed **0 bytes**. Existing build outputs and toolchains were left untouched.

## Not covered

- Measured startup latency, peak RSS, idle CPU, TLS/DNS behavior, throughput, and filesystem-specific cancellation behavior.
- Exhaustive inspection of every administrative action and advanced history/configuration workflow. History source revalidation and durable fsync boundaries remain deliberate constraints documented by the previous review.
- SDK-internal allocation bounds across every packaged platform/version; total resident memory cannot be established from engine source alone.
- Flutter preview fetching/rendering and host scheduling, which are outside this task’s source scope.
- JVM CDS/GC tuning and final Windows/Linux runtime qualification. No recommendation to change JVM defaults is supported by this static review.