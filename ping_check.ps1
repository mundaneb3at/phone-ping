# ping_check.ps1
# Manual diagnostic for the Claude Code -> ntfy.sh phone notifier (attention-only design).
#
# What it tests:
#   1. Flag file (ping_enabled) exists  -> notifications ON
#   2. Script file (ping_notify.ps1) exists
#   3. Hook wiring in settings.json:
#        - Notification hook present (idle-60s ping)
#        - PreToolUse(AskUserQuestion) present (question ping)
#        - per-turn Stop ping is INTENTIONALLY absent (attention-only)
#   4. Drives ping_notify.ps1 once per kept event by piping a fake hook
#      payload, so the phone receives the real tailored messages.
#
# Usage:
#   powershell -NonInteractive -File "$env:USERPROFILE\.claude\ping_check.ps1"
#
# Expected phone output: 2 labeled notifications -> "Claude has a question", "Claude is waiting".
# If any step fails, exit code is 1 and the failing check is printed in red.

$flag   = "$env:USERPROFILE\.claude\ping_enabled"
$script = "$env:USERPROFILE\.claude\hooks\ping_notify.ps1"
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

# --- 2. Hook wiring in settings.json ---
try {
    $cfg = Get-Content $settings -Raw | ConvertFrom-Json
    $notifOk  = $null -ne $cfg.hooks.Notification
    $askOk    = $null -ne ($cfg.hooks.PreToolUse | Where-Object { $_.matcher -eq "AskUserQuestion" })
    $stopGone = ($null -eq $cfg.hooks.Stop) -or (-not ($cfg.hooks.Stop.hooks.command -match 'ping_notify'))

    Check "Notification hook wired"      $notifOk  $(if ($notifOk)  { "present -- idle-60s ping" } else { "MISSING from settings.json" })
    Check "PreToolUse(AskUserQ) wired"   $askOk    $(if ($askOk)    { "present -- question ping" } else { "MISSING from settings.json" })
    Check "Per-turn Stop ping removed"   $stopGone $(if ($stopGone) { "absent -- attention-only OK" } else { "STILL PRESENT -- will buzz every turn" })
} catch {
    Check "settings.json parse" $false "ERROR: $_"
}

# --- 3. Drive each kept event through ping_notify.ps1 (real tailored messages) ---
# Distinct fake session_ids so the per-session debounce does not collapse the two.
function Fire($evt) {
    $payload = @{ hook_event_name = $evt; session_id = "ping-check-$evt" } | ConvertTo-Json -Compress
    $payload | powershell -NonInteractive -ExecutionPolicy Bypass -File "$script"
}
if (Test-Path $script) {
    Fire "PreToolUse"      # -> "Claude has a question"
    Start-Sleep -Milliseconds 600
    Fire "Notification"    # -> "Claude is waiting"
    Check "Drove PreToolUse + Notification through ping_notify" $true "2 tailored pings sent (if flag ON)"
} else {
    Check "Drove events through ping_notify" $false "ping_notify.ps1 missing -- skipped"
}

# --- Report ---
Write-Host ""
foreach ($line in $log) {
    if ($line -match '^\s+\[OK\]') { Write-Host $line -ForegroundColor Green }
    else                          { Write-Host $line -ForegroundColor Red }
}
Write-Host ""
if ($fail -eq 0) {
    Write-Host "  $pass/$($pass + $fail) checks passed." -ForegroundColor Green
    Write-Host "  Confirm 2 notifications arrived on phone (Question, Idle)." -ForegroundColor Green
} else {
    Write-Host "  $fail check(s) FAILED -- see red lines above." -ForegroundColor Red
}
Write-Host ""

exit $(if ($fail -eq 0) { 0 } else { 1 })
