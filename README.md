# phone-ping

Claude Code → phone push notifications via [ntfy.sh](https://ntfy.sh) (free, no account).

**Attention-only:** your phone buzzes only when Claude is actually waiting on you — when it asks a question, or when it has sat idle 60s after finishing. It does **not** buzz on every turn-end. Each ping carries a message that says which.

- [Setup guide → workflow.md](./workflow.md)
- [Visual dashboard → workflow.html](./workflow.html)

## Files

| File | Purpose |
|---|---|
| `ping_notify.ps1` | The hook script. Reads the hook event from stdin to tailor the message per event and debounce duplicates, then POSTs to ntfy.sh. |
| `ping_check.ps1` | Diagnostic — verifies the flag, the script, the hook wiring, and sends test pings. |
| `toggle_ping.ps1` | Flip the on/off kill-switch flag in one command. |
| `settings.snippet.json` | The two hook entries to merge into `~/.claude/settings.json`. |

Public domain ([Unlicense](./LICENSE)).
