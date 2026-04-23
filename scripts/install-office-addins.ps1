# install-office-addins.ps1
# Generates manifest XML files for Excel/PowerPoint/Word from templates in
# ../manifests/, substituting YOUR pivot Worker URL. Then registers them in
# HKCU so Office shows them under Insert -> Get Add-ins -> Developer Add-ins.
#
# No admin required — all registry writes are HKCU, all files are user-scope.
#
# Usage:
#   .\install-office-addins.ps1 -PivotWorkerUrl "https://your-pivot.workers.dev"
# Then restart Excel/PowerPoint/Word. Find the add-ins under Insert > Get Add-ins > Developer Add-ins.

param(
    [Parameter(Mandatory=$true)]
    [string]$PivotWorkerUrl,

    [string]$ManifestDir = "$env:USERPROFILE\ClaudeAddin",

    [string]$TemplateDir = "$PSScriptRoot\..\manifests"
)

$ErrorActionPreference = "Stop"

# Normalize URL (strip trailing slash)
$PivotWorkerUrl = $PivotWorkerUrl.TrimEnd('/')
if ($PivotWorkerUrl -notmatch "^https://") {
    Write-Host "ERROR: PivotWorkerUrl must start with https://" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Generating Office add-in manifests ===" -ForegroundColor Cyan
Write-Host "Pivot Worker URL: $PivotWorkerUrl"
Write-Host "Manifest output directory: $ManifestDir"
Write-Host ""

New-Item -ItemType Directory -Force -Path $ManifestDir | Out-Null

$apps = @(
    @{ App = "Excel";      Template = "manifest-excel.template.xml";      Out = "manifest-excel.xml";      Registry = "ClaudeProxiedExcel" }
    @{ App = "PowerPoint"; Template = "manifest-powerpoint.template.xml"; Out = "manifest-powerpoint.xml"; Registry = "ClaudeProxiedPowerPoint" }
    @{ App = "Word";       Template = "manifest-word.template.xml";       Out = "manifest-word.xml";       Registry = "ClaudeProxiedWord" }
)

# Cache-busting version suffix so Office treats it as a new deploy
$versionBuild = [Math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1776900000))
$vQuery       = "?v=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

$devKey = "HKCU:\Software\Microsoft\Office\16.0\Wef\Developer"
New-Item -Path $devKey -Force | Out-Null

foreach ($app in $apps) {
    $templatePath = Join-Path $TemplateDir $app.Template
    $outputPath   = Join-Path $ManifestDir $app.Out

    if (-not (Test-Path $templatePath)) {
        Write-Host "  WARN: template not found: $templatePath" -ForegroundColor Yellow
        continue
    }

    $xml = Get-Content $templatePath -Raw

    # Substitute pivot URL everywhere (SourceLocation gets a ?v= cache-buster)
    $xml = $xml -replace 'DefaultValue="__PIVOT_URL__"', ('DefaultValue="' + $PivotWorkerUrl + '/' + $vQuery + '"')
    $xml = $xml -replace 'Url="__PIVOT_URL__/shortcuts\.json"', ('Url="' + $PivotWorkerUrl + '/shortcuts.json"')
    $xml = $xml -replace '__PIVOT_URL__', $PivotWorkerUrl

    # Bump version so Office doesn't serve from its internal add-in cache
    $xml = $xml -replace '<Version>1\.0\.0\.0</Version>', "<Version>1.0.0.$versionBuild</Version>"

    [System.IO.File]::WriteAllText($outputPath, $xml, [System.Text.UTF8Encoding]::new($false))
    Write-Host ("  [OK] {0,-10} -> {1}" -f $app.App, $outputPath) -ForegroundColor Green

    # Register in HKCU so Office picks it up
    New-ItemProperty -Path $devKey -Name $app.Registry -Value $outputPath -PropertyType String -Force | Out-Null
}

Write-Host ""
Write-Host "=== Registered developer add-ins ===" -ForegroundColor Cyan
Get-ItemProperty -Path $devKey | Select-Object * -ExcludeProperty PS* | Format-List

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Fully quit Excel, PowerPoint, Word (check Task Manager for stragglers)."
Write-Host "  2. Optional but recommended: clear WebView2 cache so stale bundles don't survive."
Write-Host "       Remove-Item -Recurse -Force `"`$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef\webview2`" -ErrorAction SilentlyContinue"
Write-Host "  3. Reopen the Office app."
Write-Host "  4. Insert -> Get Add-ins -> My Add-ins -> Developer Add-ins tab."
Write-Host "  5. The 'Claude (proxied, ...)' add-in for that app appears. Click Add."
Write-Host ""
