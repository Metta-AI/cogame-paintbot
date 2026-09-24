#!/usr/bin/env python3
"""Export Sprite-visible action imitation episodes for Metta post-training."""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FEATURES = (
    "tick", "self_x_px", "self_y_px", "self_alive", "own_aim_brads",
    "fire_ready", "visible_players", "visible_med_kits", "visible_shields",
    "map_width_px", "map_height_px",
)
SYSTEM = (
    "You control seat 0 in Paintbot. Choose one Sprite v1 input mask as "
    "JSON with integer key mask. Bits: up=1, down=2, left=4, right=8, "
    "select=16, attack=32, B=64, C=128. Coordinates and visible objects "
    "come only from the fogged player frame."
)


def main() -> None:
    assert len(sys.argv) in (5, 6), (
        "usage: export_posttrain.py BRIDGE OUTPUT EPISODES VARIANT [MAX_TICKS]")
    bridge_binary = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    episodes = int(sys.argv[3])
    variant = sys.argv[4]
    max_ticks = int(sys.argv[5]) if len(sys.argv) == 6 else None
    assert episodes >= 10
    manifest = ROOT / "coworld_manifest_template.json"
    config = next(row["game_config"] for row in json.loads(manifest.read_text())["variants"]
                  if row["id"] == variant)
    seats = config["num_agents"]
    output.mkdir(parents=True, exist_ok=False)
    command = [str(bridge_binary), str(manifest), variant]
    if max_ticks is not None:
        command.append(str(max_ticks))
    train_rows = []
    validation_rows = []
    runs = []
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          text=True, cwd=ROOT) as process:
        def call(request):
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        for episode in range(1, episodes + 1):
            seed = f"paintbot-{variant}-{episode}"
            observation = call({"kind": "reset", "players": seats, "seed": seed})
            rows = []
            while observation["kind"] == "decision":
                encoding = call({"kind": "encode"})
                action = json.loads(call({"kind": "teacher"})["response"])
                prompt = [
                    {"role": "system", "content": SYSTEM},
                    {"role": "user", "content": json.dumps({
                        "features": dict(zip(FEATURES, encoding["values"], strict=True)),
                        "visible_objects": observation["semantic_view"]["visible_objects"],
                    })},
                ]
                accepted = call({"kind": "step", "decision_id": observation["decision_id"],
                                 "response": json.dumps(action)})
                rows.append(json.dumps({
                    "episode_id": seed, "seed": seed,
                    "decision_id": observation["decision_id"],
                    "prompt": prompt,
                    "completion": [{"role": "assistant", "content": json.dumps(action)}],
                    "game": "paintbot", "action_schema_revision": "sprite-mask-v1",
                }))
                observation = accepted["observation"]
            (validation_rows if episode % 5 == 0 else train_rows).extend(rows)
            runs.append({"episode": episode, "decisions": len(rows),
                         "scores": observation["scores"]})
            print(f"episode {episode}/{episodes}: {len(rows)} decisions", flush=True)
        process.stdin.close()
        assert process.wait() == 0
    (output / "train.jsonl").write_text("\n".join(train_rows) + "\n")
    (output / "validation.jsonl").write_text("\n".join(validation_rows) + "\n")
    (output / "manifest.json").write_text(json.dumps({
        "schema_version": 1, "game": "paintbot", "variant": variant,
        "source_revision": subprocess.check_output(["git", "rev-parse", "HEAD"],
                                                   text=True, cwd=ROOT).strip(),
        "teacher": "shipped-baseline-seat-0", "max_ticks": max_ticks,
        "train_examples": len(train_rows),
        "validation_examples": len(validation_rows), "runs": runs,
    }, indent=2) + "\n")


if __name__ == "__main__":
    main()
