---
name: claude-code-phone-ping-workflow
description: "Push-notify a phone via ntfy.sh once per Claude Code prompt-cycle - four hooks (UserPromptSubmit resets the gate, PreToolUse:AskUserQuestion, Notification:idle_prompt, Stop) call one PowerShell script that dispatches per event, gates out headless/background runs, sends at most one ping per cycle, and POSTs via curl.exe"
metadata:
  type: workflow
  surface: claude-code
  platform: windows
  external_dependencies: [ntfy.sh, powershell, curl.exe]
  revised: 2026-06-21
---

# Phone Ping Workflow (AI-readable copy)

This is the AI-readable twin of [`workflow.html`](./workflow.html). Drop it into a memory system, paste it into a chat, or feed it to an agent that needs to reproduce or extend the setup. The HTML version is the same content rendered for human eyes.

## What this does

Sends a phone push **once per prompt-cycle**, only for interactive Desktop sessions, with a message that names what happened:

1. **A question** — Claude calls the `AskUserQuestion` tool. → "Claude has a question"
2. **Idle** — Claude went idle waiting on you (`Notification` / `idle_prompt`). → "Claude is waiting"
3. **Done** — Claude finished a turn (`Stop`). → "Claude is done"

At most **one ping per prompt-cycle per session**: the first of those events that fires in a cycle sends; the rest are suppressed until your next prompt resets the gate. Delivery is [ntfy.sh](https://ntfy.sh), a free public push service: subscribe to a chosen topic in the ntfy mobile app; the hooks POST to that topic.

### Only interactive Desktop sessions ping

`Stop` and the other events also fire for headless / scheduled / SDK runs (`claude -p`, cron jobs, background scheduled tasks). Those are gated out two ways:

- **(a) Temp-dir cwd** — anything running from a `…\Temp\…` directory is skipped (the reliable gate; background jobs run there).
- **(b) Entrypoint** — only the Desktop app pings. This gate is **fail-open**: it only blocks when `CLAUDE_CODE_ENTRYPOINT` is set to a non-Desktop value, so a hook subprocess that didn't inherit the var can never silently drop *all* pings — gate (a) still catches the background case.

## Architecture

Four hook entries in `~/.claude/settings.json` invoke the same script (`~/.claude/hooks/ping_notify.ps1`). It reads the hook event JSON from **stdin**, dispatches on `hook_event_name`, applies the interactive + per-cycle gates, then POSTs via `curl.exe`. It checks a flag file (`~/.claude/ping_enabled`) first — the kill switch.

| Hook | Matcher | Fires when | Message |
|---|---|---|---|
| `UserPromptSubmit` | `""` | You send a prompt | *(none — resets the per-cycle gate)* |
| `PreToolUse` | `"AskUserQuestion"` | Claude asks a multiple-choice question | "Claude has a question" |
| `Notification` | `"idle_prompt"` | Claude went idle waiting for input | "Claude is waiting" |
| `Stop` | `""` | Claude finished a turn | "Claude is done" |

**Facts that shape the design:**
- The per-cycle marker is namespaced by `session_id`, so concurrent chats don't suppress each other. It self-expires after 30 min and is cleared by `UserPromptSubmit`.
- For `Notification`, the script also checks `notification_type` and only proceeds on `idle_prompt` / `permission_prompt` (a `permission_prompt` retitles to "Claude needs permission"). So even with an empty `Notification` matcher, auth/elicitation notifications don't ping.
- The `pinged` marker is written **only after** `curl.exe` exits 0 — a failed POST never suppresses the next real ping, and failures are logged to `%TEMP%\claude_ping_error.log`.

## File inventory

```
~/.claude/
├── settings.json          # hook wiring (4 entries point to ping_notify.ps1)
├── ping_enabled           # 0-byte flag file; presence = ON, absence = OFF
├── ping_check.ps1         # diagnostic: checks 4-hook wiring + sends 3 test pings
├── toggle_ping.ps1        # convenience script to flip the flag
└── hooks/
    └── ping_notify.ps1    # reads stdin event, gates, debounces per cycle, POSTs via curl.exe
```

> `ping_messages.json` was an earlier config-driven message file. The current `ping_notify.ps1` defines messages inline in its `$msg` map and does **not** read it; it remains in the repo for reference only.

## Hook script

```powershell
# ping_notify.ps1 - Claude Code -> ntfy phone notifier (one ping per prompt-cycle).
# Wired to FOUR hooks, all -> this script, dispatched on hook_event_name:
#   UserPromptSubmit            -> reset the per-cycle gate (never pings)
#   PreToolUse(AskUserQuestion) -> "Claude has a question"
#   Notification(idle_prompt)   -> "Claude is waiting"
#   Stop                        -> "Claude is done"
#
# ONLY interactive Desktop chats ping. Headless / scheduled / SDK runs ALSO fire
# Stop, so they are gated out two ways: (a) anything running from a Temp dir is
# skipped, and (b) only the Desktop app's entrypoint pings. (a) is the reliable one.
#
# MODEL: one ping per prompt-cycle per session (session_id-namespaced marker,
# cleared by UserPromptSubmit, 30-min self-expiry). The notification BODY names
# the chat (project folder) + send time; the TITLE says what happened.
#
# Kill-switch: pings only if ~/.claude/ping_enabled exists (global on/off).
# Transport: curl.exe (System32, Schannel TLS, real exit codes -> failures logged).
$ErrorActionPreference = 'SilentlyContinue'

$flag  = "$env:USERPROFILE\.claude\ping_enabled"
$topic = '<YOUR-TOPIC>'

# --- read hook payload (JSON on stdin) ---
$evt = ''; $sid = 'nosession'; $ntype = ''; $cwd = ''
$raw = [Console]::In.ReadToEnd()
if ($raw) {
    try {
        $h = $raw | ConvertFrom-Json
        if ($h.hook_event_name)   { $evt   = $h.hook_event_name }
        if ($h.session_id)        { $sid   = $h.session_id }
        if ($h.notification_type) { $ntype = $h.notification_type }
        if ($h.cwd)               { $cwd   = $h.cwd }
    } catch { }
}

# --- interactive-only gate (skip background/headless/scheduled runs) ---
if ("$cwd" -match '(?i)[\\/]Temp([\\/]|$)') { return }
if ($env:CLAUDE_CODE_ENTRYPOINT -and ($env:CLAUDE_CODE_ENTRYPOINT -ne 'claude-desktop')) { return }

# --- per-session state (session_id namespaces each concurrent chat) ---
$key      = ($sid -replace '[^\w\-]', '_')
$stateDir = Join-Path $env:TEMP "phone-ping\$key"
$pinged   = Join-Path $stateDir 'pinged'

# --- UserPromptSubmit: a new cycle begins -> clear the gate, never pings ---
if ($evt -eq 'UserPromptSubmit') {
    if (Test-Path $pinged) { Remove-Item $pinged -Force }
    return
}

# --- kill-switch (global on/off across all chats) ---
if (-not (Test-Path $flag)) { return }

# --- Notification: only idle / permission warrant a ping ---
if ($evt -eq 'Notification' -and $ntype -and ($ntype -notin @('idle_prompt','permission_prompt'))) { return }

# --- one ping per prompt-cycle (30-min self-expiry safety net) ---
if (Test-Path $pinged) {
    $age = ((Get-Date) - (Get-Item $pinged).LastWriteTime).TotalSeconds
    if ($age -lt 1800) { return }
}

# --- event -> title + tag. Body = chat name. ---
$msg = @{
    PreToolUse   = @{ title = 'Claude has a question'; tag = 'question' }
    Notification = @{ title = 'Claude is waiting';     tag = 'hourglass' }
    Stop         = @{ title = 'Claude is done';        tag = 'checkered_flag' }
    default      = @{ title = 'Claude needs input';    tag = 'robot' }
}
$m     = if ($msg.ContainsKey($evt)) { $msg[$evt] } else { $msg['default'] }
$title = $m.title; $tag = $m.tag
if ($evt -eq 'Notification' -and $ntype -eq 'permission_prompt') {
    $title = 'Claude needs permission'; $tag = 'lock'
}

# --- body = which chat (project folder + short session id) + send time ---
$ts   = (Get-Date).ToString('HH:mm:ss')
$proj = if ($cwd) { Split-Path $cwd -Leaf } else { 'chat' }
$sidShort = if ("$sid".Length -ge 8) { "$sid".Substring(0, 8) } else { "$sid" }
$body = "$proj #$sidShort (sent $ts)"

# --- fire the push (curl.exe: Schannel TLS, real exit codes) ---
curl.exe -s -f --max-time 5 -H "Title: $title" -H "Tags: $tag" -H "Priority: high" --data-raw "$body" "https://ntfy.sh/$topic" | Out-Null
if ($LASTEXITCODE -eq 0) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    Set-Content -Path $pinged -Value $ts -NoNewline
} else {
    "$([DateTime]::Now.ToString('s')) ping curl failed: exit $LASTEXITCODE (evt=$evt)" |
        Out-File "$env:TEMP\claude_ping_error.log" -Append -Encoding utf8
}
```

Using `curl.exe` (the Windows System32 binary, Schannel TLS) gives real exit codes, so a failed POST is logged instead of silently swallowed — the failure mode that an earlier `Invoke-WebRequest` version hid.

## Hook configuration (verbatim)

```json
{
  "hooks": {
    "UserPromptSubmit": [{
      "matcher": "",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }],
    "PreToolUse": [{
      "matcher": "AskUserQuestion",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }],
    "Notification": [{
      "matcher": "idle_prompt",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{ "type": "command", "command": "powershell -NonInteractive -File \"C:\\Users\\<USER>\\.claude\\hooks\\ping_notify.ps1\"" }]
    }]
  }
}
```

If you already have other `PreToolUse` / `UserPromptSubmit` / `Stop` entries (linting, guard scripts), add these as additional objects in those arrays, NOT replacements.

## Customizing the messages

Each event's title and ntfy tag live inline in `ping_notify.ps1`'s `$msg` map. Edit that hashtable to reword a ping or change its emoji `tag`. (The `ping_messages.json` file in this repo is legacy and is not read by the current script.)

## Verify

Run the diagnostic — it checks the flag, the script, the four-hook wiring (Notification, AskUserQuestion, Stop, UserPromptSubmit), then POSTs the three tailored messages straight to ntfy so the phone gets the real pings:

```powershell
powershell -NonInteractive -File "$env:USERPROFILE\.claude\ping_check.ps1"
```

Expected: 3 phone notifications — "Claude has a question", "Claude is waiting", "Claude is done".

> A green diagnostic proves the wiring and that ntfy accepted the POST (HTTP 2xx). It does **not** prove the notification surfaced on your phone — confirm receipt on the device for a real, natural trigger before declaring it working (iOS routes ntfy through APNs; check the app subscription, notification permissions, and any Focus/Scheduled-Summary batching).

## Designed behaviour

| Scenario | Result | Pings |
|---|---|---|
| `AskUserQuestion` (first event in the cycle) | `PreToolUse` → "Claude has a question" | 1 |
| Claude goes idle waiting on you | `Notification`/`idle_prompt` → "Claude is waiting" | 1 |
| Claude finishes a turn | `Stop` → "Claude is done" | 1 |
| Two events fire in the same cycle | collapsed by the per-cycle marker | 1 |
| Headless / scheduled / SDK run (`claude -p`, cron, Temp-dir) | gated out | 0 |

## Failure modes to avoid

- **Don't swap `curl.exe` back to `Invoke-WebRequest`.** The script uses the System32 `curl.exe` (Schannel TLS, real exit codes) precisely because the old `Invoke-WebRequest` path failed TLS silently. (This is the Windows System32 binary, *not* the MSYS/Git-Bash `curl`, which has its own stale-cert SSL-handshake issues.)
- **Don't remove the flag-file check.** `ping_enabled` is the kill switch; without it there's no way to silence pings.
- **Don't weaken the interactive gates** (Temp-dir + entrypoint) — they are what stop headless/cron/SDK runs from buzzing your phone. Keep gate (b) fail-open so a missing env var can't drop all pings.
- **Don't use a guessable topic.** ntfy.sh topics are a public namespace — anyone with the name can read/write. Use a random suffix and never commit the literal topic (this repo ships the `<YOUR-TOPIC>` placeholder).

## Toggle on / off

```powershell
# Off
Remove-Item "$env:USERPROFILE\.claude\ping_enabled"

# On
New-Item -ItemType File "$env:USERPROFILE\.claude\ping_enabled" -Force
```

`toggle_ping.ps1` flips between the two states in one call.

## Mobile setup

App: **ntfy** by binwiederhier — Android (F-Droid + Play Store) or iOS. Open → "Subscribe to topic" → enter your topic name → done. No account needed. Pings arrive titled "Claude has a question", "Claude is waiting", or "Claude is done".

## Extension points

- **More events:** the dispatch keys off `hook_event_name`; add a `SubagentStop` case to the `$msg` map (and a hook entry) for a ping when a long subagent batch finishes.
- **Critical-only escalation:** the script already sends `Priority: high`; raise it to `urgent` for a specific event.
- **Tag routing:** ntfy supports tag-based filtering in the app — the script tags `question` / `hourglass` / `checkered_flag` / `lock` per event.
- **Linux / macOS:** swap the PowerShell script for a bash equivalent using `curl` and read the hook JSON from stdin with `jq`.

## Related

- Companion HTML view: [`workflow.html`](./workflow.html) — same content, for humans.
