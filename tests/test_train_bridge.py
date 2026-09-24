"""Run the numeric protocol against the certified native Arena runtime."""

import base64
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "coworld_manifest_template.json"


def main() -> None:
    binary = sys.argv[1]
    variants = json.loads(MANIFEST.read_text())["variants"]
    for variant in variants:
        if variant["game_config"].get("season2Shell"):
            continue
        seats = variant["game_config"]["num_agents"]
        for policy in ("teacher", "random"):
            with subprocess.Popen(
                [binary, str(MANIFEST), variant["id"], "32"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, cwd=ROOT,
            ) as process:
                def call(request):
                    process.stdin.write(json.dumps(request) + "\n")
                    process.stdin.flush()
                    return json.loads(process.stdout.readline())

                observation = call({"kind": "reset", "players": seats,
                                    "seed": f"{variant['id']}-{policy}"})
                rng = random.Random(42)
                decisions = 0
                while observation["kind"] == "decision":
                    assert base64.b64decode(observation["semantic_view"]["sprite_v1_base64"])
                    encoded = call({"kind": "encode"})
                    assert encoded["decision_id"] == observation["decision_id"]
                    assert len(encoded["values"]) == 11
                    assert len(encoded["actions"]) == 256
                    action = (json.loads(call({"kind": "teacher"})["response"])
                              if policy == "teacher" else rng.choice(encoded["actions"]))
                    accepted = call({"kind": "step", "decision_id": observation["decision_id"],
                                     "response": json.dumps(action)})
                    assert accepted["kind"] == "accepted"
                    observation = accepted["observation"]
                    decisions += 1
                assert decisions >= 31
                assert set(observation["scores"]) == {str(seat) for seat in range(seats)}
                print(variant["id"], policy, decisions, observation["scores"], flush=True)
                process.stdin.close()
                assert process.wait() == 0


if __name__ == "__main__":
    main()
