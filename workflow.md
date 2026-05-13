---
name: claude-code-phone-ping-workflow
description: "Push-notify a phone via ntfy.sh whenever Claude Code needs user input — three hooks (Stop, Notification, PreToolUse:AskUserQuestion) call one PowerShell script"
metadata:
  type: workflow
  surface: claude-code
  platform: windows
  external_dependencies: [ntfy.sh, powershell]
---

# Phone Ping Workflow (AI-readable copy)

This is the AI-readable twin of [`workflow.html`](./workflow.html). Drop this file into a memory system, paste it into a chat, or feed it to an agent that needs to reproduce or extend the setup. The HTML version is the same content rendered for human eyes.

## What this does

Sends a push notification to a phone every time Claude Code surfaces a state that requires user attention:

1. **Turn end** — Claude has finished responding and is waiting for the next prompt.
2. **Permission prompt** — Claude wants to run a tool (Bash, PowerShell, file write) that isn't pre-approved.
3. **AskUserQuestion prompt** — Claude is asking the user a multiple-choice question via the `AskUserQuestion` tool.

Delivery channel is [ntfy.sh](https://ntfy.sh), a free public push service. The user subscribes to a chosen topic on the ntfy mobile app; Claude Code's hooks POST to that topic.

## Architecture

Three hook entries in `~/.claude/settings.json` all invoke the same PowerShell script (`~/.claude/hooks/ping_notify.ps1`). The script checks for a flag file (`~/.claude/ping_enabled`) before sending — this is the kill switch.

| Hook | Matcher | Trigger | Notes |
|---|---|---|---|
| `Stop` | `""` | End of every Claude turn | Most frequent ping. |
| `Notification` | `""` | Permission prompts AND idle timeouts | Fires for Bash, PowerShell, file-write permission prompts. |
| `PreToolUse` | `"AskUserQuestion"` | Each `AskUserQuestion` tool call | One ping per call regardless of how many sub-questions are bundled in. |

**Key insight:** `AskUserQuestion` does NOT trigger the `Notification` hook (it's a tool call, not a permission-system event). That's why the `PreToolUse` matcher is needed as a separate entry. This was the missing piece in the original setup; added 2026-05-13 after debugging.

## File inventory

```
~/.claude/
├── settings.json          # hook wiring (3 entries point to ping_notify.ps1)
├── ping_enabled           # 0-byte flag file; presence = ON, absence = OFF
├── toggle_ping.ps1        # convenience script to flip the flag
└── hooks/
    └── ping_notify.ps1    # reads flag, POSTs to ntfy.sh
```

## Hook script (verbatim)

```powershell
$flag = "$env:USERPROFILE\.claude\ping_enabled"
if (Test-Path $flag) {
    Invoke-WebRequest -Method POST -Uri "https://ntfy.sh/<TOPIC>" `
        -Body "Claude has finished - your turn" `
        -Headers @{ Title = "Claude needs input"; Priority = "default"; Tags = "robot" } `
        -UseBasicParsing | Out-Null
}
```

Replace `<TOPIC>` with the user's ntfy topic. The ntfy topic is effectively public — anyone with the name can read/write. Use a long random suffix for low-sensitivity privacy.

## Hook configuration (verbatim)

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }],
    "Notification": [{
      "matcher": "",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }],
    "PreToolUse": [{
      "matcher": "AskUserQuestion",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }]
  }
}
```

If the user already has other `PreToolUse` entries (linting, guard scripts), the `AskUserQuestion` entry must be added as an additional object in the `PreToolUse` array, NOT a replacement.

## Verified scenarios (debug session 2026-05-13)

All paths confirmed working:

- Bash command requiring permission → `Notification` hook → ping ✓
- PowerShell command requiring permission → `Notification` hook → ping ✓
- `AskUserQuestion` single-select → `PreToolUse` hook → ping ✓
- `AskUserQuestion` multi-select → `PreToolUse` hook → ping ✓
- `AskUserQuestion` multi-question (1 call, 2 sub-questions) → `PreToolUse` hook → exactly 1 ping ✓
- End of Claude turn → `Stop` hook → ping ✓

## Failure modes to avoid

- **Don't use `curl` from Bash/Git Bash on Windows.** SSL handshake fails (error 35) due to stale system certs. The script uses PowerShell's `Invoke-WebRequest` for that reason. If a future AI is tempted to "simplify" by swapping to curl, it will break.
- **Don't remove the flag-file check.** The `ping_enabled` flag is the user's kill switch; without it, there's no way to silence notifications mid-session.
- **Don't use a real-name or guessable topic.** Topics on ntfy.sh are public namespace. Include a random suffix.
- **Don't add the `Notification` hook with a non-empty matcher** thinking it'll filter to specific tools — the matcher field for `Notification` doesn't accept tool names; leave it `""`.

## Toggle commands

```powershell
# Off
Remove-Item "$env:USERPROFILE\.claude\ping_enabled"

# On
New-Item -ItemType File "$env:USERPROFILE\.claude\ping_enabled" -Force
```

`toggle_ping.ps1` flips between the two states in one call. A custom `/ping` skill can wrap this for in-session toggling.

## Mobile setup

App: **ntfy** by Andreas Heigl (binwiederhier) — Android (F-Droid + Play Store) or iOS. Open the app → "Subscribe to topic" → enter the chosen topic name → done. No account needed. Notifications appear with title "Claude needs input" and body "Claude has finished - your turn".

## Extension points

- **Different message per hook:** Currently all three hooks send the same body. To distinguish them, pass `$env:CLAUDE_HOOK_TYPE` or write three separate scripts.
- **Critical-only pings:** Raise the `Priority` header to `urgent` for `Notification` hook only (permission prompts often time out faster than turn-end pings).
- **Tag-based routing:** ntfy supports tag-based filtering in the mobile app; differentiate hooks with `Tags = "tool"` vs `"robot"` vs `"question"`.
- **Linux / macOS:** Swap the PowerShell script for a bash equivalent using `curl`. The `curl` SSL issue is Windows-specific.

## Related

- Companion HTML view: [`workflow.html`](./workflow.html) — same content, designed for humans.
- Pattern for dual artifacts: the AI/HTML twin is a deliberate design choice (memory systems need plain text; users need visual structure). When documenting any non-trivial workflow, ship both.
