#!/usr/bin/env python3
"""Derive coworld_manifest_template.json (paintbot-wasm, game-hosted) from the
upstream paintbot manifest, so schemas, variants, and achievements stay in
lockstep with the engine while only the player runtime differs.

    tools/gen_manifest.py            # rewrites coworld_manifest_template.json
"""
from __future__ import annotations

import copy
import json
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO / "coworld_manifest_paintbot.json"
TARGET = REPO / "coworld_manifest_template.json"
REPO_URL = "https://github.com/Metta-AI/cogame-paintbot"
PERSONAS = ["cautious", "aggressive", "collaborative"]
CERT_SEATS = 16

DESCRIPTION_PREFIX = (
    "Paintbot Season 2 as a single-pod Coworld: every policy is ONE wasm file "
    "the game runs for you (no policy pods). Upload a wasm32-wasi module with "
    "`coworld upload-policy --file my_policy.wasm`; the game loads it per seat, "
    "and it plays the unchanged Season 2 play-seat wire - uploading plays, "
    "chatting in the lobby, calling ladders - with a host-provided model call "
    "through the platform sidecar. Format and SDK: docs/POLICY_WASM.md. "
    "Bundled baselines are the three Season 2 starter personas ported to wasm. "
    "The game itself is Paintbot: "
)


def main() -> int:
    source = json.loads(SOURCE.read_text())
    game = copy.deepcopy(source["game"])
    game["name"] = "paintbot-wasm"
    game["player_runtime"] = "game-hosted"
    game["owner"] = "daveey@softmax.com"
    game["description"] = DESCRIPTION_PREFIX + game["description"]
    game["runnable"] = {
        "type": "game",
        "image": "{{GAME_IMAGE}}",
        "run": ["/bin/ctf"],
        "source_url": f"{REPO_URL}/tree/main",
        "env": {
            "ANTHROPIC_API_KEY_URI": "secret://coworld/paintbot-wasm/anthropic_api_key",
        },
        # Game-hosted seats share the game container's reservation: sixteen
        # policy-host processes measured at ~76 MiB RSS each (a wasmtime
        # engine plus a ~700 KiB starter module) on top of the engine itself.
        "resources": {"requests": {"cpu": "3", "memory": "4Gi"}},
    }
    game["protocols"] = {
        "player": {"type": "uri", "value": f"{REPO_URL}/blob/main/docs/POLICY_WASM.md"},
        "global": {"type": "uri", "value": f"{REPO_URL}/blob/main/docs/PROTOCOL.md"},
    }
    game["docs"] = {
        "readme": {"type": "uri", "value": f"{REPO_URL}/blob/main/README.md"},
        "pages": [
            {"id": "policy-wasm.md", "title": "Writing a policy",
             "content": {"type": "uri", "value": f"{REPO_URL}/blob/main/docs/POLICY_WASM.md"}},
            {"id": "plays.md", "title": "The plays",
             "content": {"type": "uri", "value": f"{REPO_URL}/blob/main/docs/designs/BR_PLAYS.md"}},
            {"id": "rules.md", "title": "Rules",
             "content": {"type": "uri", "value": f"{REPO_URL}/blob/main/docs/RULES.md"}},
        ],
    }

    variants = [v for v in source["variants"] if v["id"] == "battle-royale-s2"]
    if len(variants) != 1:
        raise SystemExit("battle-royale-s2 variant not found in the upstream manifest")
    variant = copy.deepcopy(variants[0])
    variant["description"] = (
        "Season 2 battle royale, played by wasm policy files the game hosts: " +
        variant["description"])

    players = []
    for persona in PERSONAS:
        players.append({
            "type": "player",
            "id": f"starter-{persona}",
            "name": f"Starter ({persona})",
            "description": (
                f"The Season 2 '{persona}' starter persona as a paintbot-wasm policy: "
                "uploads the reference playbook, chats in the lobby, calls and "
                "re-calls ladders from a live model when the platform sidecar is "
                "reachable and from its scripted persona turns otherwise."),
            "file": f"policies/wasm/dist/starter-{persona}.wasm",
            "source_url": f"{REPO_URL}/tree/main/policies/wasm/starter",
        })

    cert_config = copy.deepcopy(variant["game_config"])
    cert_config.update({
        "maxTicks": 720,
        "lobbyChatTicks": 240,
        "startWaitTicks": 48,
        "gameOverTicks": 24,
        "seed": 679961,
    })
    certification = {
        # Every bundled player must be seated (players-run), so the fixture
        # cycles the three personas across the sixteen seats.
        "players": [{"player_id": f"starter-{PERSONAS[slot % len(PERSONAS)]}"}
                    for slot in range(CERT_SEATS)],
        "game_config": cert_config,
    }

    manifest = {
        "$schema": source["$schema"],
        "tags": sorted(set(source["tags"]) | {"game-hosted", "single-pod", "wasm-policies"}),
        "game": game,
        "player": players,
        "variants": [variant],
        "certification": certification,
    }
    TARGET.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {TARGET.relative_to(REPO)}: {len(players)} players, "
          f"{len(manifest['variants'])} variant, {CERT_SEATS}-seat certification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
