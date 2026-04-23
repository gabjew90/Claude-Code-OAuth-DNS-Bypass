# uninstall-office-addins.ps1
# Unregisters the Claude proxied Office add-ins from HKCU. Doesn't delete the
# manifest XML files (they stay in ~/ClaudeAddin/) or the Worker (still on
# Cloudflare). Use this to cleanly stop the add-ins from appearing in Office
# without nuking everything.

$devKey = "HKCU:\Software\Microsoft\Office\16.0\Wef\Developer"
foreach ($name in @("ClaudeProxiedExcel", "ClaudeProxiedPowerPoint", "ClaudeProxiedWord")) {
    if (Get-ItemProperty -Path $devKey -Name $name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $devKey -Name $name -Force
        Write-Host "Unregistered: $name" -ForegroundColor Green
    } else {
        Write-Host "Not registered: $name" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Restart Office apps for changes to take effect."
