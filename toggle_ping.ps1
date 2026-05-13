# toggle_ping.ps1
# Flip the phone-ping kill switch on/off in one command.
# Copy to ~/.claude/toggle_ping.ps1, then run from any PowerShell prompt.

$flag = "$env:USERPROFILE\.claude\ping_enabled"
if (Test-Path $flag) {
    Remove-Item $flag
    Write-Output "Phone ping: OFF"
} else {
    New-Item -ItemType File $flag -Force | Out-Null
    Write-Output "Phone ping: ON"
}
