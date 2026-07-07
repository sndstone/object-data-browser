"""Shared fixtures for the engine contract test suite.

These fixtures spawn a real engine process and speak the transport
contract described in ``contracts/transport_contract.md``: line-delimited
JSON on stdin/stdout, one request per line, correlated by ``requestId``,
with an ``{"ok": true/false, ...}`` response envelope.

By default the Python engine (``engines/python/src/main.py``) is exercised,
launched with the same interpreter that is running pytest. Set the
``ENGINE_CMD`` environment variable to point at a different engine binary
(go/rust/java) to run the same suite against it, e.g.::

    ENGINE_CMD="engines/go/build/x64/s3-browser-go-engine.exe" pytest tests/contract

If the resolved binary cannot be found, engine-dependent tests are skipped
cleanly rather than failing.
"""

from __future__ import annotations

import json
import os
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
ENGINE_SCRIPT = REPO_ROOT / "engines" / "python" / "src" / "main.py"
CONTRACT_PATH = REPO_ROOT / "contracts" / "engine_contract.json"
FIXTURES_DIR = REPO_ROOT / "tests" / "fixtures"

DEFAULT_TIMEOUT = 15.0


def _default_engine_cmd() -> list[str]:
    # Mirrors scripts/stage-engines.ps1's Python launch: the staged manifest
    # runs `python.exe engine\main.py`. Locally we invoke the same source
    # file with whichever interpreter is running the tests, so ENGINE_CMD
    # can still be overridden with an explicit "python" command if desired.
    return [sys.executable, str(ENGINE_SCRIPT)]


def _resolve_engine_cmd() -> list[str]:
    override = os.environ.get("ENGINE_CMD")
    if override:
        return shlex.split(override, posix=(os.name != "nt"))
    return _default_engine_cmd()


def _binary_available(cmd: list[str]) -> bool:
    exe = cmd[0]
    if os.sep in exe or (os.altsep and os.altsep in exe):
        return Path(exe).exists()
    return shutil.which(exe) is not None


class EngineProcess:
    """Wraps a spawned engine subprocess and speaks the line-delimited
    JSON transport contract (see contracts/transport_contract.md)."""

    def __init__(self, cmd: list[str]):
        self.cmd = cmd
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
            cwd=str(REPO_ROOT),
        )
        self._stdout_queue: "queue.Queue[str]" = queue.Queue()
        self._stderr_lines: list[str] = []
        self._stdout_thread = threading.Thread(target=self._pump_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._pump_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _pump_stdout(self) -> None:
        try:
            assert self.proc.stdout is not None
            for line in self.proc.stdout:
                self._stdout_queue.put(line)
        except Exception:
            pass

    def _pump_stderr(self) -> None:
        try:
            assert self.proc.stderr is not None
            for line in self.proc.stderr:
                self._stderr_lines.append(line)
        except Exception:
            pass

    def send_raw(self, line: str) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(line if line.endswith("\n") else line + "\n")
        self.proc.stdin.flush()

    def send(self, payload: dict[str, Any]) -> None:
        self.send_raw(json.dumps(payload))

    def recv_line(self, timeout: float = DEFAULT_TIMEOUT) -> str:
        try:
            return self._stdout_queue.get(timeout=timeout)
        except queue.Empty as exc:
            stderr_tail = "".join(self._stderr_lines[-40:])
            raise TimeoutError(
                f"Engine did not respond within {timeout}s. cmd={self.cmd!r} "
                f"alive={self.proc.poll() is None} stderr_tail={stderr_tail!r}"
            ) from exc

    def recv_json(self, timeout: float = DEFAULT_TIMEOUT) -> dict[str, Any]:
        line = self.recv_line(timeout=timeout)
        return json.loads(line)

    def request(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        request_id: str | None = None,
        engine_version: str = "test",
        timeout: float = DEFAULT_TIMEOUT,
    ) -> dict[str, Any]:
        req_id = request_id or f"test-{method}-{time.time_ns()}"
        self.send(
            {
                "requestId": req_id,
                "method": method,
                "engineVersion": engine_version,
                "params": params or {},
            }
        )
        return self.recv_json(timeout=timeout)

    def is_alive(self) -> bool:
        return self.proc.poll() is None

    def terminate(self) -> None:
        if self.proc.poll() is None:
            try:
                if self.proc.stdin:
                    self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=3)
            except Exception:
                try:
                    self.proc.terminate()
                    self.proc.wait(timeout=5)
                except Exception:
                    try:
                        self.proc.kill()
                    except Exception:
                        pass
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            try:
                if stream:
                    stream.close()
            except Exception:
                pass


@pytest.fixture(scope="session")
def engine_cmd() -> list[str]:
    return _resolve_engine_cmd()


@pytest.fixture()
def engine(engine_cmd: list[str]):
    if not _binary_available(engine_cmd):
        pytest.skip(f"Engine binary not available: {engine_cmd[0]!r} (cmd={engine_cmd!r})")

    proc = EngineProcess(engine_cmd)
    try:
        yield proc
    finally:
        proc.terminate()


@pytest.fixture(scope="session")
def engine_contract() -> dict[str, Any]:
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def contract_methods(engine_contract: dict[str, Any]) -> set[str]:
    return set(engine_contract["properties"]["method"]["enum"])


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    return FIXTURES_DIR
