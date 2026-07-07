# Contract Test Suite

The contract suite is the enforcement point for engine parity.

Minimum scenarios:

1. `health` returns engine metadata.
2. `testProfile` maps invalid credentials to `auth_failed`.
3. `listBuckets` returns normalized bucket summaries.
4. `listObjects` honors `prefix`, `delimiter`, and cursor behavior.
5. `listObjectVersions` returns version and delete marker flags.
6. `startUpload` and `startDownload` return `TransferJob`.
7. `deleteObjects` returns partial failures without crashing.
8. `startBenchmark` produces a stable status schema and export path.

The fixtures in `tests/fixtures` are canonical shape examples for engine implementers.

## Running the automated suite

`test_contract.py` (with fixtures in `conftest.py`) is a pytest harness that
spawns a real engine process and speaks the transport contract described in
`contracts/transport_contract.md`: line-delimited JSON on stdin/stdout, one
request per line, correlated by `requestId`, with an `{"ok": true/false, ...}`
response envelope.

Run it with:

```
pytest tests/contract
```

By default the suite targets the Python engine
(`engines/python/src/main.py`), launched with the same interpreter running
pytest. To run the same tests against another engine binary (Go, Rust,
Java), set `ENGINE_CMD` to the full command line, e.g.:

```
ENGINE_CMD="engines/go/build/x64/s3-browser-go-engine.exe" pytest tests/contract
# or, on Windows PowerShell:
$env:ENGINE_CMD = "engines\java\...\run-java-engine.bat"; pytest tests/contract
```

If the resolved binary is not present, the engine-dependent tests skip
cleanly instead of failing; the fixture-shape tests (which only read
`tests/fixtures/*.json`) still run regardless of engine availability.

The suite covers: `health` (advertised methods must be a subset of the
`contracts/engine_contract.json` method enum), `getCapabilities`, an unknown
method producing a well-formed error envelope, a malformed JSON line, an
oversized request line (~100KB, guarding the known 64KB scanner bug class),
and structural validation of the `health_response.json` and
`list_objects_response.json` fixtures (including the `nextCursor` field).
All scenarios are offline-only and require no cloud credentials.

