# phone-ping

Claude Code → phone push notifications via [ntfy.sh](https://ntfy.sh) (free, no account).

**One ping per prompt-cycle.** You receive at most one push per prompt-cycle, with a message that says what happened:

- **Claude has a question** — it called the `AskUserQuestion` tool.
- **Claude is waiting** — it went idle waiting on you (`Notification` / `idle_prompt`).
- **Claude is done** — it finished a turn (`Stop`).

Only **interactive Desktop sessions** ping. Headless / scheduled / SDK runs (`claude -p`, cron jobs, background scheduled tasks) are gated out, so automation never notifies your phone. A global on/off flag (`~/.claude/ping_enabled`) is the kill switch.

- [Setup guide → workflow.md](./workflow.md)
- [Visual dashboard → workflow.html](./workflow.html)

> **Topic security:** ntfy.sh topics are a public namespace — anyone who knows your topic name can read *and* post to it. Use a random, unguessable string (e.g. `my-claude-f3a8`) and never commit the literal topic to a public repo. The notification body also includes your working-directory's folder name; if that could be sensitive, replace `$proj` in `ping_notify.ps1` with a fixed string.

## Files

| File | Purpose |
|---|---|
| `ping_notify.ps1` | The hook script. One entry point for all four events; dispatches on `hook_event_name`, gates out background/headless runs, sends at most one ping per prompt-cycle, then POSTs to ntfy.sh via `curl.exe`. Messages are defined inline in its `$msg` map. |
| `ping_check.ps1` | Diagnostic — verifies the flag, the script, the four-hook wiring, and POSTs the three tailored test pings directly to ntfy. Also purges stale per-session state (>7 days). |
| `settings.snippet.json` | The four hook entries to merge into `~/.claude/settings.json`. |
| `toggle_ping.ps1` | Flip the on/off kill-switch flag in one command. |
| `ping_messages.json` | Legacy — an earlier config-driven message file. The current `ping_notify.ps1` defines messages inline and does **not** read this; kept for reference. |

Public domain ([Unlicense](./LICENSE)).
