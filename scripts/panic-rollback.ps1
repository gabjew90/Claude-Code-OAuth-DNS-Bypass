# PANIC ROLLBACK: restore Claude Code settings and credentials to the state
# they were in before you applied this Worker setup.
#
# When to use: something is wrong (VSCode Claude broken, can't figure out
# why), and you want to bail out to the "daily paste credentials from
# personal laptop" workflow that worked before.
#
# What this does:
#   1. Snapshots current state (dated backup) so you can re-apply later.
#   2. Removes ANTHROPIC_BASE_URL from ~/.claude/settings.json.
#   3. Restores ~/.claude/.credentials.json from the most recent pre-Shape-B
#      backup, if one exists.
#
# After running: in VSCode, Ctrl+Shift+P -> Developer: Reload Window.

$ErrorActionPreference = "Continue"

$settings = "$env:USERPROFILE\.claude\settings.json"
$credentials = "$env:USERPROFILE\.claude\.credentials.json"
$backupDir = "$env:USERPROFILE\.claude\backups"

Write-Host ""
Write-Host "=== PANIC ROLLBACK ===" -ForegroundColor Red
Write-Host ""

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

if (Test-Path $settings) {
    Copy-Item $settings "$backupDir\settings.json.bak-panic-$stamp" -Force
}
if (Test-Path $credentials) {
    Copy-Item $credentials "$backupDir\credentials.json.bak-panic-$stamp" -Force
}
Write-Host "[1] Snapshotted current state to $backupDir (timestamp $stamp)" -ForegroundColor Yellow
Write-Host ""

# --- Remove ANTHROPIC_BASE_URL from settings.json ---
if (Test-Path $settings) {
    try {
        $s = Get-Content $settings -Raw | ConvertFrom-Json
        if ($s.env -and $s.env.PSObject.Properties['ANTHROPIC_BASE_URL']) {
            $s.env.PSObject.Properties.Remove('ANTHROPIC_BASE_URL')
            $s | ConvertTo-Json -Depth 10 | Set-Content -Path $settings -NoNewline
            Write-Host "[2] Removed ANTHROPIC_BASE_URL from settings.json" -ForegroundColor Green
        } else {
            Write-Host "[2] ANTHROPIC_BASE_URL not present in settings.json (nothing to remove)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "[2] WARN: couldn't parse settings.json. Manual edit may be required." -ForegroundColor Yellow
    }
} else {
    Write-Host "[2] settings.json not present. Skipping." -ForegroundColor DarkGray
}
Write-Host ""

# --- Restore credentials.json from most recent pre-Shape-B backup ---
$preShapeB = Get-ChildItem "$backupDir\credentials.json.bak-pre-shape-b-*" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($preShapeB) {
    Copy-Item $preShapeB.FullName $credentials -Force
    Write-Host "[3] Restored credentials.json from pre-Shape-B backup:" -ForegroundColor Green
    Write-Host "    $($preShapeB.FullName)"
    Write-Host "    (expiresAt and token values reverted to their pre-Worker state)"
} else {
    Write-Host "[3] No pre-Shape-B backup found." -ForegroundColor Yellow
    Write-Host "    credentials.json left unchanged."
    Write-Host "    If Claude Code still complains: paste a fresh .credentials.json from personal laptop."
}
Write-Host ""

Write-Host "=== Next steps ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. In VSCode: Ctrl+Shift+P -> Developer: Reload Window" -ForegroundColor Cyan
Write-Host "2. Try Claude. If still broken, the local access token is probably expired."
Write-Host "   Copy a fresh ~/.claude/.credentials.json from your personal laptop."
Write-Host "3. Reload VSCode again."
Write-Host ""

Read-Host "Press Enter to close"
