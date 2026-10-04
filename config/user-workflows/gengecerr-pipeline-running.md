# Gen-GEC-ERRANT pipeline user run

Follow `default.md` in this directory. Work from the fresh Gen-GEC-ERRANT checkout, using a new run directory and independent outputs. Build a run ledger with these columns: model family, model size, fine-tuned or native, L1/CEFR head present or absent, shard range, config file, checkpoint, corpus, output, status. Select one row before each run; never launch the entire matrix at once.

Use `python run.py --list` to see the shipped 88 cells. Pick the exact model/size and fine-tuned/native cell plus one shard, then run `python run.py CELL --dry-run`, followed by `python run.py CELL --out NEW_RUN_DIR/out` when prerequisites are ready. Inspect `out/<cell>/` before proceeding to another shard. `run.py` does not expose an L1/CEFR head switch; that axis comes from the separate L1-CEFR conditioning pipeline. Resolve the specific head artifact and its provenance before claiming a head-enabled result. If that integration is unavailable, mark the combination unimplemented rather than silently using a no-head cell.

Final acceptance: validate the run by listing and inspecting its published result at the remote rclone source of truth, `hetzner:`. A local output or a successful runner exit alone does not pass; if the result is not present on `hetzner:`, mark the run failed.
