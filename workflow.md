---
name: claude-code-phone-ping-workflow
description: "Push-notify a phone via ntfy.sh only when Claude Code is actually waiting on you - two hooks (Notification idle-60s, PreToolUse:AskUserQuestion) call one stdin-aware PowerShell script that tailors the message per event and debounces duplicates"
metadata:
  type: workflow
  surface: claude-code
  platform: windows
  external_dependencies: [ntfy.sh, powershell]
  revised: 2026-06-13
---

# Phone Ping Workflow (AI-readable copy)

This is the AI-readable twin of [`workflow.html`](./workflow.html). Drop it into a memory system, paste it into a chat, or feed it to an agent that needs to reproduce or extend the setup. The HTML version is the same content rendered for human eyes.

## What this does

Sends a push notification to a phone **only when Claude Code is genuinely waiting on you** — deliberately *attention-only*, not a buzz on every turn:

1. **A question** — Claude calls the `AskUserQuestion` tool (a real choice you have to make). Immediate ping.
2. **Idle 60s** — Claude finished and you haven't responded for 60 seconds. One ping.

Delivery is [ntfy.sh](https://ntfy.sh), a free public push service: subscribe to a chosen topic on the ntfy mobile app; Claude Code's hooks POST to that topic.

### Why not ping on every turn-end?

The original design also wired the `Stop` hook (fires at the end of *every* assistant turn). In an active back-and-forth that buzzes your phone constantly — and a single `AskUserQuestion` produced **two** pings (one from `PreToolUse` before the question, one from `Stop` at turn-end). Dropping `Stop` is the core of the attention-only redesign: if you respond within 60s you get no ping at all; if you're away, the idle-60s `Notification` covers the "your turn" case with a single buzz. (Revised 2026-06-13.)

To opt back into a buzz on every turn-end, add a `Stop` entry identical to the `Notification` one in `settings.snippet.json`.

## Architecture

Two hook entries in `~/.claude/settings.json` invoke the same PowerShell script (`~/.claude/hooks/ping_notify.ps1`). The script reads the hook event JSON from **stdin** to (a) pick a message tailored to the event and (b) debounce duplicate pings within a short window per session. It checks a flag file (`~/.claude/ping_enabled`) before sending — the kill switch.

| Hook | Matcher | Fires when | Message |
|---|---|---|---|
| `Notification` | `""` | Idle 60s waiting for input (and, outside bypass mode, on permission prompts) | "Claude is waiting" |
| `PreToolUse` | `"AskUserQuestion"` | Claude asks a multiple-choice question | "Claude has a question" |
| ~~`Stop`~~ | ~~`""`~~ | ~~every turn-end~~ | **removed — was the noise** |

**Two key facts that shape the design:**
- `AskUserQuestion` does NOT trigger the `Notification` hook (it's a tool call, not a permission-system event). The `PreToolUse` matcher is what catches it.
- In `bypassPermissions` mode there are no permission prompts, so `Notification` effectively only fires on the **idle-60s** case. That's exactly the "you walked away" signal we want.

## File inventory

```
~/.claude/
├── settings.json          # hook wiring (2 entries point to ping_notify.ps1)
├── ping_enabled           # 0-byte flag file; presence = ON, absence = OFF
├── ping_check.ps1         # diagnostic: checks wiring + sends test pings
├── toggle_ping.ps1        # convenience script to flip the flag
└── hooks/
    └── ping_notify.ps1    # reads stdin event, tailors message, debounces, POSTs to ntfy.sh
```

## Hook script (verbatim)

```powershell
$ErrorActionPreference = 'SilentlyContinue'

$flag = "$env:USERPROFILE\.claude\ping_enabled"
if (-not (Test-Path $flag)) { return }          # kill-switch off

$topic       = '<YOUR-TOPIC>'                    # your private ntfy topic
$debounceSec = 10                               # collapse same-instant duplicates

# read hook payload (JSON on stdin)
$evt = ''; $sid = 'nosession'
$raw = [Console]::In.ReadToEnd()
if ($raw) {
    try {
        $h = $raw | ConvertFrom-Json
        if ($h.hook_event_name) { $evt = $h.hook_event_name }
        if ($h.session_id)      { $sid = $h.session_id }
    } catch { }
}

# event -> tailored message
switch ($evt) {
    'PreToolUse'   { $title = 'Claude has a question'; $body = 'Claude is asking you to choose'; $tag = 'question' }
    'Notification' { $title = 'Claude is waiting';     $body = 'Idle 60s - Claude needs you';    $tag = 'hourglass' }
    default        { $title = 'Claude needs input';    $body = 'Your turn';                       $tag = 'robot' }
}

# per-session debounce
$key   = ($sid -replace '[^\w-]', '_')
$stamp = Join-Path $env:TEMP "claude_ping_$key.txt"
$now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (Test-Path $stamp) {
    [long]$last = 0
    if ([long]::TryParse((Get-Content $stamp -Raw).Trim(), [ref]$last)) {
        if (($now - $last) -lt $debounceSec) { return }
    }
}
Set-Content -Path $stamp -Value $now -NoNewline

try {
    Invoke-WebRequest -Method POST -Uri "https://ntfy.sh/$topic" `
        -Body $body `
        -Headers @{ Title = $title; Priority = 'default'; Tags = $tag } `
        -UseBasicParsing -TimeoutSec 5 | Out-Null
} catch { }
```

The `try/catch` + `-TimeoutSec 5` keep a slow/offline ntfy from ever stalling a hook (and therefore Claude). The stdin read is how one script serves both events with different messages.

## Hook configuration (verbatim)

```json
{
  "hooks": {
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

If you already have other `PreToolUse` entries (linting, guard scripts), add the `AskUserQuestion` entry as an additional object in the `PreToolUse` array, NOT a replacement.

## Verify

Run the diagnostic — it checks the flag, the script, the wiring (Notification + AskUserQuestion present, per-turn Stop absent), then drives each kept event through `ping_notify.ps1` so the phone gets the real tailored messages:

```powershell
powershell -NonInteractive -File "$env:USERPROFILE\.claude\ping_check.ps1"
```

Expected: 2 phone notifications — "Claude has a question", then "Claude is waiting".

Live behaviour to confirm in a real session:
- `AskUserQuestion` → exactly **one** "Claude has a question" ping (no longer two).
- Finish, stay idle 60s → **one** "Claude is waiting" ping.
- Rapid turn-ends while you're actively typing → **no** pings.

## Failure modes to avoid

- **Don't use `curl` from Bash/Git Bash on Windows.** SSL handshake fails (error 35) on stale system certs. The script uses PowerShell's `Invoke-WebRequest` for that reason. If a future AI "simplifies" to curl, it breaks.
- **Don't remove the flag-file check.** `ping_enabled` is the kill switch; without it there's no way to silence pings mid-session.
- **Don't use a real-name or guessable topic.** ntfy.sh topics are a public namespace — anyone with the name can read/write. Use a random suffix.
- **Don't re-add the `Stop` hook unless you actually want a buzz on every turn.** That was the original noise. The idle-60s `Notification` already covers the "your turn" case for when you're away.
- **Don't set a non-empty matcher on `Notification`** expecting it to filter to specific tools — that field doesn't accept tool names; leave it `""`.
- **Idle re-fire:** if you find `Notification` re-fires every 60s while you stay idle, raise `$debounceSec` so reminders don't stack. (Claude Code's idle re-fire cadence isn't documented; tune empirically.)

## Toggle on / off

```powershell
# Off
Remove-Item "$env:USERPROFILE\.claude\ping_enabled"

# On
New-Item -ItemType File "$env:USERPROFILE\.claude\ping_enabled" -Force
```

`toggle_ping.ps1` flips between the two states in one call.

## Mobile setup

App: **ntfy** by binwiederhier — Android (F-Droid + Play Store) or iOS. Open → "Subscribe to topic" → enter your topic name → done. No account needed. Pings arrive titled "Claude has a question" or "Claude is waiting".

## Extension points

- **More events:** the `switch` keys off `hook_event_name`; add a `SubagentStop` case if you want a ping when a long subagent batch finishes.
- **Critical-only escalation:** raise the `Priority` header to `urgent` for a specific event.
- **Tag routing:** ntfy supports tag-based filtering in the app — the script already tags `question` vs `hourglass`.
- **Linux / macOS:** swap the PowerShell script for a bash equivalent using `curl` (the curl SSL issue is Windows-specific) and read the JSON from stdin with `jq`.

## Related

- Companion HTML view: [`workflow.html`](./workflow.html) — same content, for humans.
- Pattern: ship both an AI-readable `.md` and a human `.html` for any non-trivial workflow.
