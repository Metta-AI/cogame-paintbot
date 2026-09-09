#!/usr/bin/env python3
"""Run one game-hosted paintbot-wasm episode locally, the way the platform
runner would: stage policy files, write player_seats.json, hand the game its
COGAME_* URIs, and collect results, replay, seat logs, and player status.

    tools/hosted_episode.py --policy policies/wasm/.build/echo.wasm \
        --seats 16 --max-ticks 900 --workspace build/hosted-run

Pass --policy once to seat the same file everywhere, or once per seat.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent


def variant_config(manifest: pathlib.Path, variant_id: str) -> dict:
    manifest_doc = json.loads(manifest.read_text())
    for variant in manifest_doc["variants"]:
        if variant["id"] == variant_id:
            return json.loads(json.dumps(variant["game_config"]))
    raise SystemExit(f"variant {variant_id} not in {manifest}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", default=str(REPO / "build" / "ctf"))
    parser.add_argument("--policy-host", default=str(REPO / "build" / "policy-host"))
    parser.add_argument("--policy", action="append", required=True)
    parser.add_argument("--seats", type=int, default=16)
    parser.add_argument("--manifest", default=str(REPO / "coworld_manifest_paintbot.json"))
    parser.add_argument("--variant", default="battle-royale-s2")
    parser.add_argument("--max-ticks", type=int, default=900)
    parser.add_argument("--lobby-chat-ticks", type=int, default=240)
    parser.add_argument("--start-wait-ticks", type=int, default=48)
    parser.add_argument("--override", action="append", default=[],
                        help="KEY=JSON game_config override")
    parser.add_argument("--workspace", default=str(REPO / "build" / "hosted-run"))
    parser.add_argument("--port", type=int, default=18420)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--env", action="append", default=[],
                        help="extra KEY=VALUE for the game process")
    args = parser.parse_args()

    workspace = pathlib.Path(args.workspace).resolve()
    if workspace.exists():
        shutil.rmtree(workspace)
    (workspace / "logs").mkdir(parents=True)

    config = variant_config(pathlib.Path(args.manifest), args.variant)
    seats = args.seats
    # Names with spaces, slashes, and colons, like the platform's de-duplicated
    # "entrant (2)" and "coworld-smoke/cow_...:v1" roster names.
    config["players"] = [{"name": f"wasm/starter:{slot} ({slot // 2})"} for slot in range(seats)]
    config["slots"] = (config.get("slots") or [{}] * seats)[:seats]
    while len(config["slots"]) < seats:
        config["slots"].append({"control": "play"})
    tokens = [secrets.token_urlsafe(12) for _ in range(seats)]
    config["tokens"] = tokens
    config["minPlayers"] = seats
    config["num_agents"] = seats
    config["maxTicks"] = args.max_ticks
    config["lobbyChatTicks"] = args.lobby_chat_ticks
    config["startWaitTicks"] = args.start_wait_ticks
    config["closedRoster"] = True
    for item in args.override:
        key, _, value = item.partition("=")
        config[key] = json.loads(value)
    (workspace / "config.json").write_text(json.dumps(config, indent=2))

    policies = args.policy
    if len(policies) == 1:
        policies = policies * seats
    if len(policies) != seats:
        raise SystemExit(f"--policy given {len(policies)} times for {seats} seats")
    seat_entries = []
    for slot, source in enumerate(policies):
        data = pathlib.Path(source).read_bytes()
        target = workspace / "players" / str(slot) / "file"
        target.parent.mkdir(parents=True)
        target.write_bytes(data)
        seat_entries.append({
            "slot": slot,
            "file_uri": f"file://{target}",
            "content_hash": "sha256:" + hashlib.sha256(data).hexdigest(),
            "size_bytes": len(data),
            "log_uri": f"file://{workspace}/logs/policy_agent_{slot}.log",
            "artifact_uri": f"file://{workspace}/policy_artifact_{slot}.zip",
        })
    (workspace / "player_seats.json").write_text(json.dumps({
        "schema": "coworld-player-seats/1",
        "seats": seat_entries,
        "player_status_uri": f"file://{workspace}/player_status.json",
    }, indent=2))

    env = dict(os.environ)
    env.update({
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(args.port),
        "COGAME_CONFIG_URI": f"file://{workspace}/config.json",
        "COGAME_RESULTS_URI": f"file://{workspace}/results.json",
        "COGAME_SAVE_REPLAY_URI": f"file://{workspace}/replay",
        "COGAME_EVENTS_URI": f"file://{workspace}/events.jsonl",
        "COGAME_PLAYER_SEATS_URI": f"file://{workspace}/player_seats.json",
        "COGAME_PLAYER_FAILURE_URI": f"file://{workspace}/player_failure.json",
        "PAINTBOT_POLICY_HOST": args.policy_host,
    })
    for item in args.env:
        key, _, value = item.partition("=")
        env[key] = value

    game_log = open(workspace / "logs" / "game.stdout.log", "w")
    started = time.monotonic()
    print(f"[hosted_episode] workspace {workspace}; game {args.game}", flush=True)
    process = subprocess.Popen([args.game], cwd=str(REPO), env=env,
                               stdout=game_log, stderr=subprocess.STDOUT)
    try:
        code = process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        code = -1
        print("[hosted_episode] TIMEOUT: game did not finish", flush=True)
    game_log.close()
    elapsed = time.monotonic() - started
    print(f"[hosted_episode] game exit {code} after {elapsed:.0f}s", flush=True)

    ok = code == 0
    results = workspace / "results.json"
    if results.exists():
        doc = json.loads(results.read_text())
        print("[hosted_episode] results scores:", doc.get("scores"))
    else:
        ok = False
        print("[hosted_episode] MISSING results.json")
    replay = workspace / "replay"
    if replay.exists():
        print(f"[hosted_episode] replay {replay.stat().st_size} bytes")
    else:
        ok = False
        print("[hosted_episode] MISSING replay")
    failure = workspace / "player_failure.json"
    if failure.exists():
        print("[hosted_episode] player_failure:", failure.read_text().strip())
    status = workspace / "player_status.json"
    if status.exists():
        players = json.loads(status.read_text())["players"]
        print("[hosted_episode] player_status:",
              {p["slot"]: (p["state"], p.get("exit_code")) for p in players})
    else:
        print("[hosted_episode] MISSING player_status.json")
    for slot in range(seats):
        log = workspace / "logs" / f"policy_agent_{slot}.log"
        if not log.exists():
            ok = False
            print(f"[hosted_episode] MISSING seat log {slot}")
            continue
        lines = log.read_text(errors="replace").splitlines()
        if slot < 2 or not ok:
            print(f"--- seat {slot} log ({len(lines)} lines) ---")
            shown = lines if len(lines) <= 24 else lines[:12] + ["..."] + lines[-12:]
            for line in shown:
                print("   ", line[:200])
    print("[hosted_episode]", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
