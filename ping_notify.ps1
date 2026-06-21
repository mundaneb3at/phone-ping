# ping_notify.ps1 - Claude Code -> ntfy phone notifier (one ping per prompt-cycle).
# Wired to FOUR hooks, all -> this script, dispatched on hook_event_name:
#   UserPromptSubmit            -> reset the per-cycle gate (never pings)
#   PreToolUse(AskUserQuestion) -> "Claude has a question"
#   Notification(idle_prompt)   -> "Claude is waiting"
#   Stop                        -> "Claude is done"
#
# ONLY interactive Desktop chats ping. Headless / scheduled / SDK runs
# (background scheduled tasks, cron jobs, `claude -p`) ALSO fire Stop, so they are
# gated out two ways: (a) anything running from a Temp dir is skipped, and (b) only
# the Desktop app's entrypoint pings. (a) is the reliable one (background and
# scheduled jobs typically run from %TEMP%); (b) catches other non-Desktop launches.
#
# MODEL: one ping per prompt-cycle per session (session_id-namespaced marker,
# cleared by UserPromptSubmit, 30-min self-expiry). The notification BODY just
# names the chat (project folder) + send time; the TITLE says what happened.
#
# Kill-switch: pings only if ~/.claude/ping_enabled exists (global on/off).
# Transport: curl.exe (System32, Schannel TLS, real exit codes -> failures logged).
# Errors are silenced by design: a hook must never block Claude, and delivery
# failures are surfaced via curl's exit code + the error log below, not exceptions.
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
# (a) Temp-dir runs = background/scheduled jobs (claude -p, cron, SDK). Reliable.
if ("$cwd" -match '(?i)[\\/]Temp([\\/]|$)') { return }
# (b) Only the Desktop app pings. Headless/cli/sdk launches use other entrypoints.
#     FAIL-OPEN: gate ONLY when the var is actually set to a non-Desktop value. If it
#     is unset (e.g. a hook subprocess that didn't inherit it), do NOT gate here --
#     fall back to (a) -- so we can never silently drop ALL pings.
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
# The 8-char session-id prefix distinguishes concurrent chats so you can spot a
# single chat over-pinging. (Full convo title isn't in the hook payload.)
$ts   = (Get-Date).ToString('HH:mm:ss')
$proj = if ($cwd) { (Split-Path $cwd -Leaf) -replace '["\r\n]', '' } else { 'chat' }
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
