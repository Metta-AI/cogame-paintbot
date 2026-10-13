#!/usr/bin/env python3
"""Fixture tests for brain.py's model selection and failure degradation
(stdlib only; the only network is a loopback fixture server).

Run from anywhere: python3 policies/poc_llm_policy/test_brain.py

The scenario that motivates these: hosted starter pods asked the LLM sidecar
for a model its allowlist rejects (HTTP 403 model_not_allowed) and exited 1,
taking ~10 seats per episode with them. The contract under test:

1. the platform-injected ``COWORLD_LLM_MODEL`` wins over the baked-in default,
2. a missing injection falls back to the default instead of refusing to start,
3. ANY completions failure (the allowlist 403 first among them, but also an
   unreachable sidecar) leaves the policy alive and still emitting playable
   decisions, having logged the error exactly once and made exactly one
   upstream attempt.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import brain  # noqa: E402


@contextlib.contextmanager
def env(**pairs):
    """Temporarily set (value) or clear (None) environment variables."""
    saved = {key: os.environ.get(key) for key in pairs}
    try:
        for key, value in pairs.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


# Every test starts from a clean slate: no ambient sidecar/OpenRouter config.
CLEAN = {"COWORLD_LLM_ENDPOINT": None, "COWORLD_LLM_MODEL": None,
         "POC_LLM_PROTOCOL": None, "OPENROUTER_API_KEY": None}

INJECTED = "anthropic/claude-haiku-4.5"
# 127.0.0.1:9 (discard) refuses immediately; nothing listens there.
DEAD_ENDPOINT = "http://127.0.0.1:9"


def entries_of(decision):
    entries = decision["call"]["entries"]
    assert entries and all(e.get("play") for e in entries), decision
    return entries


# ── 1. The injected model wins over the baked-in default ──────────────────
with env(**{**CLEAN, "COWORLD_LLM_ENDPOINT": DEAD_ENDPOINT,
            "COWORLD_LLM_MODEL": INJECTED}):
    engine, why = brain.build_brain(False, brain.DEFAULT_MODEL)
    assert isinstance(engine, brain.ResilientBrain), why
    assert engine.primary.model == INJECTED, engine.primary.model
    assert f"COWORLD_LLM_MODEL={INJECTED}" in why, why

# ── 2. No injection: default model is a fallback, never a refusal ─────────
with env(**{**CLEAN, "COWORLD_LLM_ENDPOINT": DEAD_ENDPOINT}):
    engine, why = brain.build_brain(False, brain.DEFAULT_MODEL)  # must not raise
    assert isinstance(engine, brain.ResilientBrain), why
    assert engine.primary.model == brain.DEFAULT_MODEL, engine.primary.model
    assert "COWORLD_LLM_MODEL unset" in why, why

    # ...and an UNREACHABLE sidecar degrades instead of killing the policy.
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        decision = engine.decide("lobby, before the drop")
    entries_of(decision)
    assert engine.error is not None
    assert log.getvalue().count("playing on") == 1, log.getvalue()


# ── 3. The 403 model_not_allowed scenario, end to end over real HTTP ──────
class Deny403(BaseHTTPRequestHandler):
    """The sidecar's allowlist rejection, verbatim shape from the incident."""

    hits = 0

    def do_POST(self):
        type(self).hits += 1
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.dumps({"error": {
            "code": "model_not_allowed",
            "message": "model 'qwen/qwen3-30b-a3b-instruct-2507' "
                       "is not allowed"}}).encode("utf-8")
        self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep the test output clean
        pass


server = HTTPServer(("127.0.0.1", 0), Deny403)
threading.Thread(target=server.serve_forever, daemon=True).start()
live_endpoint = f"http://127.0.0.1:{server.server_port}"

with env(**{**CLEAN, "COWORLD_LLM_ENDPOINT": live_endpoint,
            "COWORLD_LLM_MODEL": "qwen/qwen3-30b-a3b-instruct-2507"}):
    engine, why = brain.build_brain(False, brain.DEFAULT_MODEL)
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        first = engine.decide("lobby, before the drop")
        second = engine.decide("mid-match, the zone is closing")

    # Alive, and every post-failure decision still carries playable entries.
    first_entries = entries_of(first)
    entries_of(second)
    # Exactly one upstream attempt (a hard rejection is never retried) and
    # exactly one degrade log line.
    assert Deny403.hits == 1, f"expected 1 upstream attempt, got {Deny403.hits}"
    assert log.getvalue().count("playing on") == 1, log.getvalue()
    assert "403" in str(engine.error), engine.error
    assert "model_not_allowed" in str(engine.error), engine.error
    assert "degraded" in engine.name, engine.name
    assert engine.calls == 0  # no completed model call

# ── 4. A persona fallback rides the same wrapper (starter path) ───────────
with env(**{**CLEAN, "COWORLD_LLM_ENDPOINT": live_endpoint,
            "COWORLD_LLM_MODEL": "qwen/qwen3-30b-a3b-instruct-2507"}):
    class ScriptedFallback:
        name = "scripted-test"

        def decide(self, summary):
            return {"chat": "scripted line", "call": {"entries": [
                {"play": "edge_ride", "entry_id": "ride"}]}}

    Deny403.hits = 0
    engine, why = brain.build_brain(False, brain.DEFAULT_MODEL,
                                    fallback=ScriptedFallback())
    with contextlib.redirect_stdout(io.StringIO()):
        decision = engine.decide("summary")
    assert decision["chat"] == "scripted line", decision
    assert Deny403.hits == 1

server.shutdown()

# ── 5. The degraded decision repairs into a wire call (starter harness) ───
# Optional: starter_harness needs the third-party `websockets` package, which
# the fixture tests above deliberately avoid. Run this leg when available.
try:
    sys.path.insert(
        0, str(Path(__file__).resolve().parents[1] / "starters" / "common"))
    import starter_harness  # noqa: E402
except ImportError as error:
    print(f"skipped starter_harness leg (missing dependency: {error})")
else:
    payload, entries = starter_harness.build_call(
        first, ["edge_ride", "pact"])
    assert entries, entries
    parsed = json.loads(payload.decode("utf-8"))
    assert parsed["plays"], parsed
    print("starter-harness repair over the degraded decision: OK")

print("test_brain: all assertions passed")

# ── 6. A model that fences its JSON (```json … ```) still yields a decision ─
# Observed live (Paintbot league round 3625, 2026-09-02): the sidecar returned
# Claude's answer wrapped in a markdown code fence despite response_format
# json_object, and the policy died with "model did not return JSON". The
# contract: fenced or prose-wrapped JSON parses; the model call COUNTS as a
# completed call (no degrade); only genuinely non-JSON output degrades.
class FencedJson(BaseHTTPRequestHandler):
    hits = 0
    reply = ('Here is my call:\n```json\n{"chat": "fenced line",\n "call": '
             '{"entries": [{"play": "edge_ride", "entry_id": "zone_ride",'
             ' "params": {"margin": 280}}]}}\n```\nGood luck.')

    def do_POST(self):
        type(self).hits += 1
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.dumps({"choices": [{"message": {
            "content": self.reply}}]}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


fenced_server = HTTPServer(("127.0.0.1", 0), FencedJson)
threading.Thread(target=fenced_server.serve_forever, daemon=True).start()
fenced_endpoint = f"http://127.0.0.1:{fenced_server.server_port}"

with env(**{**CLEAN, "COWORLD_LLM_ENDPOINT": fenced_endpoint,
            "COWORLD_LLM_MODEL": INJECTED}):
    engine, why = brain.build_brain(False, brain.DEFAULT_MODEL)
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        decision = engine.decide("lobby, before the drop")
    assert decision["chat"] == "fenced line", decision
    assert entries_of(decision)[0]["entry_id"] == "zone_ride", decision
    assert engine.error is None, f"fenced JSON must not degrade: {engine.error}"
    assert engine.calls == 1, engine.calls
    assert "playing on" not in log.getvalue(), log.getvalue()

# The pure parser, on the shapes the sidecar has been seen to return.
assert brain.parse_model_json('{"a": 1}') == {"a": 1}
assert brain.parse_model_json('```json\n{"a": 1}\n```') == {"a": 1}
assert brain.parse_model_json('```\n{"a": [1, 2]}\n```') == {"a": [1, 2]}
assert brain.parse_model_json('Sure! {"a": {"b": "}"}} trailing') == {"a": {"b": "}"}}
for bad in ("", "no json here", "```json\n{not json}\n```", "[1, 2]"):
    try:
        brain.parse_model_json(bad)
    except ValueError:
        pass
    else:
        raise AssertionError(f"parse_model_json accepted {bad!r}")

fenced_server.shutdown()
print("fenced-JSON model output: OK")
