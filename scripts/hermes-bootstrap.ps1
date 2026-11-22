<#
.SYNOPSIS
  Hermes prebuilt updater - one-line entry (self-check + interactive menu).
.DESCRIPTION
  Run it straight from PowerShell:

    irm https://github.com/ArthurZhu1992/hermes-prebuild/releases/latest/download/hermes-bootstrap.ps1 | iex

  Why this file is pure ASCII: `irm ... | iex` decodes the response with the
  system ANSI code page, so any non-ASCII text (Chinese) gets mangled into
  parser errors. This launcher therefore stays ASCII-only and hands control to
  hermes-update.ps1, which is written to disk (UTF-8 with BOM) and renders
  Chinese correctly.

  It downloads hermes-update.ps1 plus its dependency sign-receipts.mjs into
  %TEMP%\hermes-prebuild\ and runs it with no arguments, which opens the menu:
    1 check only / 2 overlay / 3 overlay+update / 4 pick version / 5 rollback / 6 proxy / 0 quit

  No token needed: release assets are anonymous. Four download sources are
  tried in order (github direct, ghproxy, ghfast, raw.githubusercontent).
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repo = 'ArthurZhu1992/hermes-prebuild'
$dir  = Join-Path $env:TEMP 'hermes-prebuild'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$bases = @(
  "https://github.com/$repo/releases/latest/download",
  "https://ghproxy.net/https://github.com/$repo/releases/latest/download",
  "https://ghfast.top/https://github.com/$repo/releases/latest/download",
  "https://raw.githubusercontent.com/$repo/main/scripts"
)

Write-Host '--- Hermes prebuilt updater -----------------------' -ForegroundColor Cyan
$hit = $null
foreach ($base in $bases) {
  $tmp1 = Join-Path $dir 'hermes-update.ps1.new'
  $tmp2 = Join-Path $dir 'sign-receipts.mjs.new'
  try {
    Write-Host ("  fetching: {0}" -f $base) -ForegroundColor DarkGray
    Invoke-WebRequest "$base/hermes-update.ps1" -OutFile $tmp1 -UseBasicParsing -TimeoutSec 45
    Invoke-WebRequest "$base/sign-receipts.mjs" -OutFile $tmp2 -UseBasicParsing -TimeoutSec 45
    if ((Get-Item $tmp1).Length -lt 5000 -or (Get-Item $tmp2).Length -lt 800) {
      throw 'incomplete file (probably a 404 page)'
    }
    Move-Item $tmp1 (Join-Path $dir 'hermes-update.ps1') -Force
    Move-Item $tmp2 (Join-Path $dir 'sign-receipts.mjs') -Force
    $hit = $base
    break
  } catch {
    Write-Host ("    x {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    Remove-Item $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
  }
}

if (-not $hit) {
  Write-Host '!! every source failed. Download these two files by hand into one folder,' -ForegroundColor Red
  Write-Host '   then run hermes-update.ps1 there:' -ForegroundColor Red
  Write-Host "   https://github.com/$repo/releases/latest" -ForegroundColor Yellow
  return
}

Write-Host ("  scripts ready: {0}" -f $dir) -ForegroundColor Green
Write-Host ''
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'hermes-update.ps1')
