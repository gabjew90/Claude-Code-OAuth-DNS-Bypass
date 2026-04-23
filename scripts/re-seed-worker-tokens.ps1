# Re-seed the Worker's CLAUDE_REFRESH_TOKEN and flush its KV cache.
# Use when the Worker starts returning:
#   {"error":{"type":"oauth_refresh_error","message":"..."}}
# (stored refresh token is dead; Worker can't mint access tokens any more).
#
# Get a fresh refresh token first:
#   1. On a network where claude.ai is reachable: sign out of Claude Code,
#      sign back in.
#   2. Open ~/.claude/.credentials.json on that machine.
#   3. Copy the value of the "refreshToken" field (a 108-character string).
#   4. Run this script on the blocked-network machine, paste when prompted.

$ErrorActionPreference = "Stop"

# ---------- CONFIGURE ME ----------
# Path to your cloned worker repo. Adjust if you cloned somewhere other than ~/claude-oauth-worker.
$WORKER_REPO = "$env:USERPROFILE\claude-oauth-worker"
# ---------- END CONFIGURE ----------

Write-Host ""
Write-Host "=== Re-seed Claude OAuth Worker refresh token ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Paste the refreshToken value from a fresh personal-network login." -ForegroundColor Yellow
Write-Host "Value is hidden as you type." -ForegroundColor DarkGray
Write-Host ""

$secureToken = Read-Host "refreshToken" -AsSecureString
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
$token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

if (-not $token -or $token.Length -lt 50 -or $token.Length -gt 300) {
    Write-Host ""
    Write-Host "ERROR: token looks wrong (length $($token.Length), expected ~108). Aborting." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

if (-not (Test-Path $WORKER_REPO)) {
    Write-Host "ERROR: WORKER_REPO not found: $WORKER_REPO" -ForegroundColor Red
    Write-Host "Edit the WORKER_REPO path at the top of this script." -ForegroundColor Yellow
    Read-Host "Press Enter to close"
    exit 1
}

Push-Location $WORKER_REPO

try {
    $tmp = Join-Path $WORKER_REPO ".tmpsecret"
    [System.IO.File]::WriteAllText($tmp, $token)

    Write-Host ""
    Write-Host "[1/4] Seeding CLAUDE_REFRESH_TOKEN on MAIN env..." -ForegroundColor Yellow
    Get-Content $tmp | wrangler secret put CLAUDE_REFRESH_TOKEN 2>&1 | Select-String -NotMatch $token | Select-Object -Last 5

    Write-Host ""
    Write-Host "[2/4] Seeding CLAUDE_REFRESH_TOKEN on TEST env..." -ForegroundColor Yellow
    Get-Content $tmp | wrangler secret put CLAUDE_REFRESH_TOKEN --env test 2>&1 | Select-String -NotMatch $token | Select-Object -Last 5

    Remove-Item $tmp -Force

    Write-Host ""
    Write-Host "[3/4] Flushing KV cache (access_token)..." -ForegroundColor Yellow
    wrangler kv key delete --binding CLAUDE_TOKEN_CACHE --remote access_token 2>&1 | Select-Object -Last 3

    Write-Host ""
    Write-Host "[4/4] Flushing KV cache (refresh_token)..." -ForegroundColor Yellow
    wrangler kv key delete --binding CLAUDE_TOKEN_CACHE --remote refresh_token 2>&1 | Select-Object -Last 3

    Write-Host ""
    Write-Host "=== Done ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next Worker request will:" -ForegroundColor Cyan
    Write-Host "  - See empty KV"
    Write-Host "  - Use your newly-seeded CLAUDE_REFRESH_TOKEN"
    Write-Host "  - Mint a fresh access token + rotated refresh token"
    Write-Host "  - Cache both in KV"
    Write-Host ""
    Write-Host "Test by making a request through the Worker. Reload VSCode if needed." -ForegroundColor Cyan

} catch {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    if (Test-Path "$WORKER_REPO\.tmpsecret") { Remove-Item "$WORKER_REPO\.tmpsecret" -Force }
} finally {
    Pop-Location
}

Read-Host "Press Enter to close"
