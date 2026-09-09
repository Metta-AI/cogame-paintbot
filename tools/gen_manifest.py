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
# The campaign settles each board cell with a classic match on one of these
# variants (Sprite mask seats); battle-royale-s2 stays for the Season 2 ladder.
CAMPAIGN_VARIANTS = ["1v1", "2v2", "4ffa"]
VARIANTS = CAMPAIGN_VARIANTS + ["battle-royale-s2"]
# The bundled players are the classic baseline builds: the certification
# fixture is a classic 2v2, so every bundled player must be a mask bot. The
# Season 2 starters (policies/wasm/starter) are uploaded as policies instead.
BASELINES = [
    ("baseline", "The classic Paintbot baseline bot (players/baseline) as a wasm policy: "
                 "cover-aware pathfinding, a six-strong attack wave, overwatch and a home "
                 "defender, driving Sprite v1 input masks for the campaign's 1v1/2v2/4ffa cells."),
    ("baseline-rusher", "The classic baseline tuned to rush: wider engagement ranges and an "
                        "earlier late-game push."),
    ("baseline-guard", "The classic baseline tuned to defend: a longer thief hunt, shallower flanks and a "
                       "steadier back line."),
]

DESCRIPTION_PREFIX = (
    "Paintbot Season 2 as a single-pod Coworld: every policy is ONE wasm file "
    "the game runs for you (no policy pods). Upload a wasm32-wasi module with "
    "`coworld upload-policy --file my_policy.wasm`; the game loads it per seat, "
    "and it plays the unchanged Season 2 play-seat wire - uploading plays, "
    "chatting in the lobby, calling ladders - with a host-provided model call "
    "through the platform sidecar. Format and SDK: docs/POLICY_WASM.md. "
    "Bundled baselines are the classic Paintbot bot ported to wasm (campaign cells "
    "are 1v1/2v2/4ffa Sprite-mask matches); the three Season 2 starter personas "
    "are available as uploaded policies. "
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

    by_id = {v["id"]: v for v in source["variants"]}
    variants = []
    for variant_id in VARIANTS:
        if variant_id not in by_id:
            raise SystemExit(f"{variant_id} variant not found in the upstream manifest")
        variant = copy.deepcopy(by_id[variant_id])
        variant["description"] = (
            "Played by wasm policy files the game hosts (docs/POLICY_WASM.md): " +
            variant["description"])
        variants.append(variant)

    players = []
    for player_id, description in BASELINES:
        players.append({
            "type": "player",
            "id": player_id,
            "name": player_id.replace("-", " ").title(),
            "description": description,
            "file": f"policies/wasm/dist/{player_id}.wasm",
            "source_url": f"{REPO_URL}/tree/main/policies/wasm/baseline",
        })

    cert_config = copy.deepcopy(by_id["2v2"]["game_config"])
    cert_config.update({
        "maxTicks": 600,
        "startWaitTicks": 48,
        "gameOverTicks": 24,
        "seed": 679961,
    })
    certification = {
        # Every bundled player must be seated (players-run), so the fixture
        # cycles the three baseline builds across the sixteen seats.
        "players": [{"player_id": BASELINES[slot % len(BASELINES)][0]}
                    for slot in range(CERT_SEATS)],
        "game_config": cert_config,
    }

    manifest = {
        "$schema": source["$schema"],
        "tags": sorted(set(source["tags"]) | {"game-hosted", "single-pod", "wasm-policies"}),
        "game": game,
        "player": players,
        "variants": variants,
        "certification": certification,
    }
    TARGET.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {TARGET.relative_to(REPO)}: {len(players)} players, "
          f"{len(manifest['variants'])} variants, {CERT_SEATS}-seat certification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
