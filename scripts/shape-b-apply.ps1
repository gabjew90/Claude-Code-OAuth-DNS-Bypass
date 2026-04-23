# Apply Shape B: set `claudeAiOauth.expiresAt` in ~/.claude/.credentials.json
# to a far-future value (year 2286) so Claude Code never attempts a local
# OAuth refresh. The Worker handles all real refreshes server-side.
#
# Idempotent — safe to run multiple times.
# Makes a dated backup of the original credentials.json before editing.

$ErrorActionPreference = "Stop"

$credentials = "$env:USERPROFILE\.claude\.credentials.json"
$backupDir = "$env:USERPROFILE\.claude\backups"

if (-not (Test-Path $credentials)) {
    Write-Host "ERROR: $credentials not found." -ForegroundColor Red
    Write-Host "Has Claude Code ever been logged in on this machine? It creates that file at first login." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backupPath = "$backupDir\credentials.json.bak-pre-shape-b-$stamp"
Copy-Item $credentials $backupPath -Force

Write-Host "Backed up existing credentials.json to:" -ForegroundColor Yellow
Write-Host "  $backupPath"
Write-Host ""

$content = Get-Content $credentials -Raw
$parsed = $content | ConvertFrom-Json

$originalExpiresAt = $parsed.claudeAiOauth.expiresAt
$FAKE_EXPIRES_AT = 9999999999000  # year 2286

$parsed.claudeAiOauth.expiresAt = $FAKE_EXPIRES_AT
$parsed | ConvertTo-Json -Depth 10 | Set-Content -Path $credentials -NoNewline -Encoding ASCII

Write-Host "Shape B applied." -ForegroundColor Green
Write-Host "  Original expiresAt: $originalExpiresAt"
Write-Host "  New expiresAt     : $FAKE_EXPIRES_AT  (year 2286)"
Write-Host ""
Write-Host "Now reload VSCode: Ctrl+Shift+P -> Developer: Reload Window" -ForegroundColor Cyan
Write-Host ""

Read-Host "Press Enter to close"
