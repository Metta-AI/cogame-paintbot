# Paintbot training

`tools/train_bridge.nim` runs the maintained native Arena simulation for the
certified direct-input variants `1v1`, `2v2`, and `4ffa`. Seat 0 is the learner.
The bridge sends Sprite v1 input packets and reads only seat 0's fogged player
frames. `semantic_view.sprite_v1_base64` is the exact frame, and
`visible_objects` contains policy-facing labels and positions from it. The
11 numeric values describe time, self position and life, aim, trigger
readiness, visible actors and pickups, and map dimensions. Every 8-bit Sprite
input mask is a legal action.

The shipped baseline teaches seat 0 and runs two-team opponents. Its roles
assume red and blue. Four-team opponents use deterministic legal movement
and periodic shots without simulation-state access.

```sh
nimby --global sync nimby.lock
nim c -d:release --path:. --path:src --path:players/baseline \
  --out:train-bridge tools/train_bridge.nim
python3 tests/test_train_bridge.py ./train-bridge
```

The command `./train-bridge coworld_manifest_template.json VARIANT
[MAX_TICKS]` implements the persistent decision protocol. Pass it to
`recipes.external.coworld.train` for native PufferLib or to
`recipes.external.coworld_metta_rl.train` for Metta RL. Set `players` to the
variant's `num_agents`, seat 0, and a finite timestep limit. PufferLib can
use the baseline teacher loss. `MAX_TICKS` disables the classic barrage,
which otherwise disables the draw ceiling, and shortens the post-game
countdown. It is a bounded pipeline curriculum; full games use the certified
manifest rules and produce useful outcome scores.

For Metta post-training, export the baseline's text decisions over the
visible Sprite labels:

```sh
python3 tools/export_posttrain.py ./train-bridge /tmp/paintbot-data 10 1v1 32
```

This writes episode-split `train.jsonl`, `validation.jsonl`, and
`manifest.json`. The game-hosted player consumes WASM at 24 Hz, so deploying
a post-trained text model requires a WASM inference adapter.

`battle-royale-s2` uses play-seat WASM calls, not direct Sprite masks. This
bridge rejects it. A play-call trainer needs that separate protocol.
