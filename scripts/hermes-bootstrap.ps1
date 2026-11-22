<#
.SYNOPSIS
  Hermes 预编译升级器 —— 一行命令入口（自检 + 交互菜单）。
.DESCRIPTION
  用法（PowerShell 里直接粘一行）：

    irm https://github.com/ArthurZhu1992/hermes-prebuild/releases/latest/download/hermes-bootstrap.ps1 | iex

  它做三件事，然后把控制权交给 hermes-update.ps1 的交互菜单：
    1) 把 hermes-update.ps1 与它依赖的 sign-receipts.mjs 下到 %TEMP%\hermes-prebuild\
       （必须落盘：irm|iex 执行时 $PSScriptRoot 是空串，重签那步会因找不到 .mjs 被静默跳过，
         结果就是“能跑但下次 update 又白编一遍”）
    2) 以无参数方式调用它 → 先打印本机状态，再给菜单：
       1 只检查 / 2 覆盖不 update / 3 覆盖+update / 4 指定版本 / 5 回滚 / 6 代理 / 0 退出
    3) 不需要 token：release 直链匿名可下；GitHub 不通时按顺序回退到镜像
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new() } catch {}

$repo = 'ArthurZhu1992/hermes-prebuild'
$dir  = Join-Path $env:TEMP 'hermes-prebuild'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# 直连优先，再试镜像（ghproxy 时快时 403，所以逐个试而不是写死一个）
$bases = @(
  "https://github.com/$repo/releases/latest/download",
  "https://ghproxy.net/https://github.com/$repo/releases/latest/download",
  "https://ghfast.top/https://github.com/$repo/releases/latest/download",
  "https://raw.githubusercontent.com/$repo/main/scripts"
)

Write-Host '── Hermes 预编译升级器 ──────────────────────────' -ForegroundColor Cyan
$hit = $null
foreach ($base in $bases) {
  $tmp1 = Join-Path $dir 'hermes-update.ps1.new'
  $tmp2 = Join-Path $dir 'sign-receipts.mjs.new'
  try {
    Write-Host ("  取脚本：{0}" -f $base) -ForegroundColor DarkGray
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest "$base/hermes-update.ps1" -OutFile $tmp1 -UseBasicParsing -TimeoutSec 45
    Invoke-WebRequest "$base/sign-receipts.mjs" -OutFile $tmp2 -UseBasicParsing -TimeoutSec 45
    if ((Get-Item $tmp1).Length -lt 5000 -or (Get-Item $tmp2).Length -lt 800) { throw '文件不完整（可能拿到的是 404 页面）' }
    Move-Item $tmp1 (Join-Path $dir 'hermes-update.ps1') -Force
    Move-Item $tmp2 (Join-Path $dir 'sign-receipts.mjs') -Force
    $hit = $base
    break
  } catch {
    Write-Host ("    × {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
    Remove-Item $tmp1, $tmp2 -Force -ErrorAction SilentlyContinue
  }
}
if (-not $hit) {
  Write-Host '!! 所有来源都失败。手动下载这两个文件到同一目录后直接运行 hermes-update.ps1：' -ForegroundColor Red
  Write-Host "   https://github.com/$repo/releases/latest" -ForegroundColor Yellow
  return
}
Write-Host ("  脚本就位：{0}" -f $dir) -ForegroundColor Green
Write-Host ''

& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'hermes-update.ps1')
