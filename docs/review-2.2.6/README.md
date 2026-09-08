# 2.2.6 backend and settings review evidence

The [HTML improvement plan](../backend-settings-improvement-plan.html) reviews
local commit `1b68873fead15276388224aba4691db2e957d3b3` (app 2.2.6+1;
bundled engines 2.2.5). App and engine source were not changed.

`evidence.json` records four bounded observations from current code:

- Python basename collisions overwrite the earlier downloaded file.
- A failed Python GET truncates an existing destination file.
- A short Python range body can produce a completed, zero-padded file.
- Go Azure move deletes the source after 20 still-pending copy polls.

The Python checks use a fake client, bypassing boto3 and networking. The Go
check compiles current source and uses a loopback-only HTTP fixture with
fictional credentials. These demonstrate code behavior, not real-provider
incidence. No remote storage is accessed.

From the repository root:

```sh
(cd engines/go && ../../.tmp/toolchains/go/bin/go build -o ../../.tmp/review-226-go-engine ./src)
python3 docs/review-2.2.6/reproduce.py
```

The script prints observations and uses disposable temporary files. It is a
review harness, not a regression suite: after fixes, the recorded outcomes
should change and the cases should be added to the normal contract tests.

Baseline verification during this review:

- `flutter analyze --no-pub`: no issues found.
- `flutter test --no-pub`: 141 passed, 2 skipped.
- HTML nesting, unique IDs, fragment targets and local links checked.
- Browser: desktop layout, phone-layout mocks, dark appearance, simulated
  test/save-failure/recovery/activation, transfer sizing, findings filters and
  disclosures checked. No console warnings/errors observed.

No full engine contract matrix, native builds, physical devices, real-provider
integration, actual mobile-browser viewport or print-dialog verification was
performed. The report contains the proposed acceptance checks for implementation.
