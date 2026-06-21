# ping_check.ps1
# Manual diagnostic for the Claude Code -> ntfy.sh phone notifier.
#
# What it tests:
#   1. Flag file (ping_enabled) exists -> notifications ON
#   2. Script file (ping_notify.ps1) exists
#   3. Hook wiring in settings.json -- all four events -> ping_notify.ps1:
#        Notification (idle) · PreToolUse(AskUserQuestion) (question)
#        Stop (completion) · UserPromptSubmit (per-cycle reset)
#   4. POSTs the tailored messages straight to ntfy so the phone receives them
#   5. Purges stale per-session state (>7 days)
#
# Usage:  powershell -NoProfile -File "$env:USERPROFILE\.claude\ping_check.ps1"
# Expected: 3 notifications -> "Claude has a question", "Claude is waiting", "Claude is done".
# Exit code 1 if any check fails.

$flag     = "$env:USERPROFILE\.claude\ping_enabled"
$script   = "$env:USERPROFILE\.claude\hooks\ping_notify.ps1"
$settings = "$env:USERPROFILE\.claude\settings.json"

$pass = 0; $fail = 0
$log  = [System.Collections.Generic.List[string]]::new()
function Check($label, $ok, $detail) {
    if ($ok) { $script:pass++; $script:log.Add("  [OK]   $label -- $detail") }
    else     { $script:fail++; $script:log.Add("  [FAIL] $label -- $detail") }
}

Write-Host ""
Write-Host "=== ping_check $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Prereqs ---
Check "Flag file (ping_enabled)" (Test-Path $flag) `
    $(if (Test-Path $flag) { "present -- notifications ON" } else { "MISSING -- all hooks are silenced" })
Check "Script file (ping_notify.ps1)" (Test-Path $script) `
    $(if (Test-Path $script) { "present" } else { "MISSING -- hooks have nothing to call" })

# --- 2. Hook wiring in settings.json (4 events all -> ping_notify.ps1) ---
try {
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
    $notifOk = $null -ne $cfg.hooks.Notification
    $askOk   = $null -ne ($cfg.hooks.PreToolUse | Where-Object { $_.matcher -eq "AskUserQuestion" })
    $stopOk  = ($null -ne $cfg.hooks.Stop) -and ($cfg.hooks.Stop.hooks.command -match 'ping_notify')
    $upsOk   = ($null -ne $cfg.hooks.UserPromptSubmit) -and ($cfg.hooks.UserPromptSubmit.hooks.command -match 'ping_notify')
    Check "Notification hook wired"     $notifOk $(if ($notifOk) { "present -- idle ping" } else { "MISSING from settings.json" })
    Check "PreToolUse(AskUserQ) wired"  $askOk   $(if ($askOk)   { "present -- question ping" } else { "MISSING from settings.json" })
    Check "Stop hook wired"             $stopOk  $(if ($stopOk)  { "present -- completion ping" } else { "MISSING -- merge settings.snippet.json into settings.json, then start a new session" })
    Check "UserPromptSubmit hook wired" $upsOk   $(if ($upsOk)   { "present -- per-cycle reset" } else { "MISSING -- merge settings.snippet.json into settings.json, then start a new session" })
} catch {
    Check "settings.json parse" $false "ERROR: $_"
}

# --- 3. POST the tailored messages straight to ntfy (reliable delivery test) ---
# Direct POST (not via ping_notify.ps1) so the test never trips the per-cycle de-dupe.
$topic = $null
if (Test-Path $script) {
    $hk = Get-Content $script -Raw
    if     ($hk -match "topic\s*=\s*'([\w\-]+)'") { $topic = $matches[1] }
    elseif ($hk -match 'ntfy\.sh/([\w\-]+)')      { $topic = $matches[1] }
}

$M = @{
    PreToolUse   = @{ title = 'Claude has a question'; body = 'delivery test'; tag = 'question' }
    Notification = @{ title = 'Claude is waiting';     body = 'delivery test'; tag = 'hourglass' }
    Stop         = @{ title = 'Claude is done';        body = 'delivery test'; tag = 'checkered_flag' }
}

function Send-Ping($title, $body, $tag) {
    if (-not $topic) { return $false }
    $sentAt = (Get-Date).ToString('HH:mm:ss')
    curl.exe -s -f --max-time 5 -H "Title: $title" -H "Tags: $tag" -H "Priority: high" --data-raw "$body (sent $sentAt)" "https://ntfy.sh/$topic" | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    "$([DateTime]::Now.ToString('s')) ping_check curl failed: exit $LASTEXITCODE" |
        Out-File "$env:TEMP\claude_ping_error.log" -Append -Encoding utf8
    return $false
}

if (-not (Test-Path $flag)) {
    Check "Send tailored pings" $false "ping is OFF (no flag) -- run 'ping on' first, then re-run"
} elseif (-not $topic) {
    Check "Send tailored pings" $false "could not read ntfy topic from ping_notify.ps1"
} else {
    $ok1 = Send-Ping $M.PreToolUse.title   $M.PreToolUse.body   $M.PreToolUse.tag
    Start-Sleep -Milliseconds 500
    $ok2 = Send-Ping $M.Notification.title $M.Notification.body $M.Notification.tag
    Start-Sleep -Milliseconds 500
    $ok3 = Send-Ping $M.Stop.title         $M.Stop.body         $M.Stop.tag
    Check "Sent question + idle + completion pings (topic '$topic')" ($ok1 -and $ok2 -and $ok3) `
        $(if ($ok1 -and $ok2 -and $ok3) { "3 pings POSTed -- confirm all on phone" } else { "one or more POSTs FAILED -- see TEMP\claude_ping_error.log" })
}

# --- 4. Maintenance: purge stale per-session state (>7 days) ---
$purged = 0
$ppRoot = Join-Path $env:TEMP 'phone-ping'
if (Test-Path $ppRoot) {
    Get-ChildItem -Path $ppRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; $script:purged++ }
}
Check "Stale state purge" $true "removed $purged session dir(s) older than 7 days"

# --- Report ---
Write-Host ""
foreach ($line in $log) {
    if ($line -match '^\s+\[OK\]') { Write-Host $line -ForegroundColor Green }
    else                          { Write-Host $line -ForegroundColor Red }
}
Write-Host ""
if ($fail -eq 0) {
    Write-Host "  $pass/$($pass + $fail) checks passed." -ForegroundColor Green
    Write-Host "  Confirm 3 notifications arrived on phone (Question, Idle, Done)." -ForegroundColor Green
} else {
    Write-Host "  $fail check(s) FAILED -- see red lines above." -ForegroundColor Red
}
Write-Host ""
exit $(if ($fail -eq 0) { 0 } else { 1 })
