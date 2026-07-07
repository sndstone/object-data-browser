"""Runnable contract tests for the engine transport/method contract.

These exercise a spawned engine process over the line-delimited JSON
transport described in contracts/transport_contract.md. By default the
Python engine is targeted (see conftest.py); set ENGINE_CMD to point these
same tests at another engine binary.

Only offline-safe methods are exercised (health, getCapabilities, and
deliberately invalid/malformed input) -- nothing here requires cloud
credentials or network access.
"""

from __future__ import annotations

import json
from pathlib import Path


def test_health_ok_and_methods_subset_of_contract(engine, contract_methods):
    response = engine.request("health")
    assert response.get("ok") is True, response

    result = response["result"]
    for field in ("engine", "version", "available", "methods"):
        assert field in result, f"health result missing {field!r}: {result}"

    methods = result["methods"]
    assert isinstance(methods, list) and methods, methods

    advertised = set(methods)
    missing_from_contract = advertised - contract_methods
    assert not missing_from_contract, (
        "Engine advertises methods that are not present in the "
        "contracts/engine_contract.json method enum: "
        f"{sorted(missing_from_contract)}"
    )


def test_get_capabilities_returns_items(engine):
    response = engine.request("getCapabilities")
    assert response.get("ok") is True, response

    result = response["result"]
    assert "items" in result
    assert isinstance(result["items"], list)


def test_unknown_method_returns_error_envelope_and_process_survives(engine):
    response = engine.request("thisMethodDoesNotExist")

    assert response.get("ok") is False, response
    assert "error" in response, response
    error = response["error"]
    assert isinstance(error.get("code"), str) and error["code"], error
    assert isinstance(error.get("message"), str) and error["message"], error

    # The process must not have crashed -- a subsequent request should still
    # be answered normally.
    followup = engine.request("health")
    assert followup.get("ok") is True, followup
    assert engine.is_alive()


def test_malformed_json_line_is_survived(engine):
    engine.send_raw("{not valid json at all")

    # Observed contract for the Python engine: main()'s loop catches the
    # JSONDecodeError, cannot recover a requestId (json.loads failed before
    # the id was read), and emits a well-formed error envelope with
    # requestId=null rather than crashing.
    response = engine.recv_json()
    assert response.get("ok") is False, response
    assert response.get("requestId") is None, response
    assert "error" in response, response

    followup = engine.request("health")
    assert followup.get("ok") is True, followup
    assert engine.is_alive()


def test_oversized_request_line_still_responds(engine):
    # Guards the known 64KB line-scanner bug class: a large params payload
    # must not truncate or hang the request.
    padding = "x" * 100_000
    response = engine.request("getCapabilities", params={"padding": padding})
    assert response.get("ok") is True, response

    followup = engine.request("health")
    assert followup.get("ok") is True, followup
    assert engine.is_alive()


def test_health_fixture_matches_contract_shape(fixtures_dir: Path):
    payload = json.loads((fixtures_dir / "health_response.json").read_text(encoding="utf-8"))

    assert payload.get("ok") is True
    assert isinstance(payload.get("requestId"), str)

    result = payload["result"]
    assert isinstance(result["engine"], str)
    assert isinstance(result["version"], str)
    assert isinstance(result["available"], bool)


def test_list_objects_fixture_has_next_cursor_shape(fixtures_dir: Path):
    payload = json.loads((fixtures_dir / "list_objects_response.json").read_text(encoding="utf-8"))

    assert payload.get("ok") is True
    result = payload["result"]

    assert isinstance(result["items"], list) and result["items"]
    for item in result["items"]:
        assert "key" in item
        assert "size" in item
        assert "isFolder" in item

    assert "nextCursor" in result, (
        "list_objects_response fixture must use 'nextCursor' to match the "
        "real engines (see engines/python/src/main.py and "
        "engines/java/.../Main.java)"
    )
    cursor = result["nextCursor"]
    assert "value" in cursor
    assert isinstance(cursor["hasMore"], bool)
