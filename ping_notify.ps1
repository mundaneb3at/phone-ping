# ping_notify.ps1
# Hook script — invoked by Claude Code's Stop, Notification, and PreToolUse hooks.
# Sends a push notification to a phone via ntfy.sh if the kill-switch flag exists.
#
# Setup:
#   1. Copy this file to ~/.claude/hooks/ping_notify.ps1
#   2. Replace <YOUR-TOPIC> below with your chosen ntfy topic name
#   3. Create the kill-switch flag:  New-Item -ItemType File "$env:USERPROFILE\.claude\ping_enabled" -Force
#   4. Wire the three hook entries in settings.json (see settings.snippet.json)

$flag = "$env:USERPROFILE\.claude\ping_enabled"
if (Test-Path $flag) {
    Invoke-WebRequest -Method POST -Uri "https://ntfy.sh/<YOUR-TOPIC>" `
        -Body "Claude has finished - your turn" `
        -Headers @{ Title = "Claude needs input"; Priority = "default"; Tags = "robot" } `
        -UseBasicParsing | Out-Null
}
