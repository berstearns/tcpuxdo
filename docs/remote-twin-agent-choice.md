# Choose the agents, models, and effort for a remote twin

The ordinary `i3minator start remote-<profile>` command still works. With no
saved options, it starts local Codex `gpt-6-sol` at medium effort and remote
Claude Code `sonnet` at medium effort. Options are saved per project so i3 can
read them when it launches the terminal.

Use the selector to change choices and open the same i3 launcher:

```bash
cd /home/b/p/tcpuxdo
scripts/AUTO-choose-agents-models-effort-and-open-remote-twin.sh app303-get-my-audio-android \
  --local-agent codex --local-model gpt-6-sol --local-effort high \
  --remote-agent claude --remote-model opus --remote-effort medium
```

Any subset of the six flags is valid. When you switch an agent without giving
its model or effort, that side gets the new agent's defaults: Codex
`gpt-6-sol/medium`, Claude `sonnet/medium`. Use `--dry-run` to see the selected
agent command bases without saving or launching. Use `--reset` to restore defaults.
Without flags, the selector opens the twin with the saved choices.

The selected options apply when an agent process starts. If the local twin
tmux session is already running, the selector rejects a change instead of
silently leaving the old agent in place. End the existing twin session before
choosing another agent/model/effort. The remote launcher also refuses to type
a launch command into a pane already running a different agent. Existing
conversations are not discarded by changing the saved file.

All profiles use the same mechanism. The selected local manager still reads
`<profile>-local-manager.md`; the remote worker reads
`<profile>-remote-worker.md` when it starts fresh. If a project has no
specific instruction, the generic remote-twin instruction is used.

Codex uses `--model` and `-c model_reasoning_effort=...`; Claude Code uses
`--model` and `--effort`. The chosen model must be available to the account
on the machine where that agent runs. The launcher validates flag syntax and
reports a missing CLI or unsupported model when the process starts.

CLI references: [Codex configuration](https://developers.openai.com/codex/config-reference/)
and [Claude Code CLI](https://code.claude.com/docs/en/cli-reference).
