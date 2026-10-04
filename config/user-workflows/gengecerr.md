# Gen-GEC-ERRANT user

Follow `gengecerr-pipeline-running.md` in this directory. Choose a concrete matrix cell by model family and size, fine-tuned versus native, L1/CEFR head versus no head, and one shard. Run exactly one shard at a time from the fresh checkout with a new output directory. Record all four choices, the config and checkpoint, source SHA, and result before choosing another cell. Validate the completed run against the remote rclone source of truth, `hetzner:`; if its result is not present there, the run fails acceptance.
