# ping_notify.ps1 - Claude Code -> ntfy phone notifier (attention-only).
# Invoked by the Notification and PreToolUse(AskUserQuestion) hooks.
# Reads the hook JSON from stdin to tailor the message per event and to
# debounce duplicate pings within a short window (per session).
# Kill-switch: pings only if ~/.claude/ping_enabled exists.
#
# Setup:
#   1. Copy to ~/.claude/hooks/ping_notify.ps1
#   2. Set $topic below to your ntfy topic (replace <YOUR-TOPIC>)
#   3. Create the flag:  New-Item -ItemType File "$env:USERPROFILE\.claude\ping_enabled" -Force
#   4. Wire the 2 hooks from settings.snippet.json into settings.json
$ErrorActionPreference = 'SilentlyContinue'

$flag = "$env:USERPROFILE\.claude\ping_enabled"
if (-not (Test-Path $flag)) { return }          # kill-switch off -> do nothing

$topic       = '<YOUR-TOPIC>'                    # e.g. my-claude-7f3a (your private ntfy topic)
$debounceSec = 10                               # collapse same-instant duplicate pings

# --- read hook payload (JSON on stdin) ---
$evt = ''; $sid = 'nosession'
$raw = [Console]::In.ReadToEnd()
if ($raw) {
    try {
        $h = $raw | ConvertFrom-Json
        if ($h.hook_event_name) { $evt = $h.hook_event_name }
        if ($h.session_id)      { $sid = $h.session_id }
    } catch { }
}

# --- event -> tailored message ---
switch ($evt) {
    'PreToolUse'   { $title = 'Claude has a question'; $body = 'Claude is asking you to choose'; $tag = 'question' }
    'Notification' { $title = 'Claude is waiting';     $body = 'Idle 60s - Claude needs you';    $tag = 'hourglass' }
    default        { $title = 'Claude needs input';    $body = 'Your turn';                       $tag = 'robot' }
}

# --- per-session debounce (kills same-instant duplicates) ---
$key   = ($sid -replace '[^\w-]', '_')
$stamp = Join-Path $env:TEMP "claude_ping_$key.txt"
$now   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
if (Test-Path $stamp) {
    [long]$last = 0
    if ([long]::TryParse((Get-Content $stamp -Raw).Trim(), [ref]$last)) {
        if (($now - $last) -lt $debounceSec) { return }   # too soon -> skip
    }
}
Set-Content -Path $stamp -Value $now -NoNewline

# --- fire the push ---
try {
    Invoke-WebRequest -Method POST -Uri "https://ntfy.sh/$topic" `
        -Body $body `
        -Headers @{ Title = $title; Priority = 'default'; Tags = $tag } `
        -UseBasicParsing -TimeoutSec 5 | Out-Null
} catch { }
