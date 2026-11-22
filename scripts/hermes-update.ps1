<#
.SYNOPSIS
  Hermes Windows 预编译产物同步器 —— 探测本机安装、挑要升级的版本、把 CI 编好的产物覆盖进去。

.DESCRIPTION
  配合 hermes-prebuild 仓库的 prebuild.yml 使用。它做四件事：
    1) 探测：HERMES_HOME、安装目录、版本、渠道、有没有桌面壳、Node 版本、磁盘余量
    2) 选版本：按渠道取目标 SHA（stable=最新 tag，main=上游 HEAD），或 -Ref 直接指定
    3) 下载校验：拉对应 artifact，校验 manifest / 烘焙 stamp / receipt 的 commit+platform+arch+node
    4) 覆盖并升级：备份旧产物 → 覆盖 → 运行 hermes update（--SkipUpdate 可跳过）

  校验不过就什么都不改；覆盖失败可从备份回滚。它永远不碰 HERMES_HOME 里的数据
  （sessions/skills/config），只动 hermes-agent 下被 gitignore 的编译产物。

.EXAMPLE
  .\hermes-update.ps1                    # 交互菜单
  .\hermes-update.ps1 -Diagnose          # 只看状态，不改任何东西
  .\hermes-update.ps1 -Ref v0.23.1 -Yes  # 非交互：直接干到 v0.23.1
  .\hermes-update.ps1 -CheckOnly         # 只报有没有产物/差多少，不下载（菜单里的 1）
  .\hermes-update.ps1 -Flavor cli        # 强制按纯 CLI 版处理（默认 auto：看有没有 win-unpacked）
  .\hermes-update.ps1 -DryRun            # 下载并走完全部校验，不落地
  .\hermes-update.ps1 -Rollback          # 回到上一次覆盖前的备份
#>
[CmdletBinding()]
param(
  [string]$Ref,
  [switch]$Diagnose,
  [switch]$DryRun,
  [switch]$CheckOnly,                    # 只报告「有没有产物 / 差多少」，不下载、不落地
  [switch]$Yes,
  [switch]$SkipUpdate,
  [switch]$Rollback,
  [switch]$KillDesktop,                  # 桌面在跑时直接结束它（非交互/自动化用）
  [string]$Proxy,                        # 例：http://127.0.0.1:7890 / socks5://10.0.0.2:1080
  [ValidateSet('auto','artifact','release')][string]$Source = 'auto',   # 产物来源通道
  [ValidateSet('auto','desktop','cli')][string]$Flavor = 'auto',        # 装的是桌面版还是纯 CLI 版
  [switch]$NoProxy,                      # 忽略系统代理，强制直连
  [string]$BuilderRepo = 'ArthurZhu1992/hermes-prebuild',
  [string]$Upstream    = 'NousResearch/hermes-agent'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new() } catch {}   # 中文输出别乱码
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$script:StampTs = Get-Date -Format 'yyyyMMdd-HHmmss'
$Arch = if ([Environment]::Is64BitOperatingSystem) {
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
} else { 'x86' }

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Ok($m)  { Write-Host "  OK   $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  !!   $m" -ForegroundColor Yellow }
function Fail($m){ Write-Host "  XX   $m" -ForegroundColor Red; exit 1 }

# ─── 0. 代理 ────────────────────────────────────────────────────────────────
function Get-SystemProxy {
  # 1) 环境变量优先（HTTPS_PROXY / ALL_PROXY / HTTP_PROXY，大小写都看）
  foreach ($n in @('HTTPS_PROXY','https_proxy','ALL_PROXY','all_proxy','HTTP_PROXY','http_proxy')) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { return @{ Url = $v; Source = "环境变量 $n" } }
  }
  # 2) Windows 系统代理（设置 → 网络 → 代理）
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  try {
    $p = Get-ItemProperty -Path $key -ErrorAction Stop
    if ([int]$p.ProxyEnable -eq 1 -and $p.ProxyServer) {
      $raw = [string]$p.ProxyServer
      $url = $null
      if ($raw -match '(?i)(?:^|;)\s*(?:https?|socks)=([^;]+)') { $url = $Matches[1] }
      elseif ($raw -notmatch '=') { $url = $raw }
      if ($url) {
        if ($url -notmatch '^[a-z0-9]+://') { $url = "http://$url" }
        return @{ Url = $url; Source = '系统代理(注册表)' }
      }
    }
  } catch {}
  @{ Url = $null; Source = '无（直连）' }
}

function Resolve-Proxy {
  if ($NoProxy) { return @{ Url = $null; Source = '已禁用(--NoProxy)' } }
  if ($Proxy) {
    $u = $Proxy
    if ($u -notmatch '^[a-z0-9]+://') { $u = "http://$u" }     # 只输 ip:端口 时默认 http
    return @{ Url = $u; Source = '命令行 --Proxy' }
  }
  Get-SystemProxy
}

function Set-ProxyEnv($url) {
  if (-not $url) {
    foreach ($n in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','https_proxy','http_proxy','all_proxy')) {
      [Environment]::SetEnvironmentVariable($n, $null)
    }
    return
  }
  foreach ($n in @('HTTPS_PROXY','HTTP_PROXY','ALL_PROXY')) { [Environment]::SetEnvironmentVariable($n, $url) }
  $env:NO_PROXY = 'localhost,127.0.0.1,::1'
}

function Test-Proxy($url) {
  if (-not $url) { return $true }
  Say "  探测代理 $url ..." 'Gray'
  $errFile = [IO.Path]::GetTempFileName()
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'      # 原生程序写 stderr 时别被 Stop 当成终止错误
  try {
    $code = & curl.exe -sS -o NUL -w '%{http_code}' -x $url --connect-timeout 10 --max-time 20 https://api.github.com/ 2>$errFile
  } finally {
    $ErrorActionPreference = $prevEap
    if (Test-Path $errFile) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
  }
  if ("$code" -eq '200') { Ok '代理可用（api.github.com → 200）'; return $true }
  Warn "代理没通（返回 '$code'）：可以用 -Proxy 换一个，或 -NoProxy 强制直连"
  return $false
}

# ─── 1. 探测 ────────────────────────────────────────────────────────────────
function Get-HermesInstall {
  $home_ = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { Join-Path $env:LOCALAPPDATA 'hermes' }
  $dir   = Join-Path $home_ 'hermes-agent'
  $info = [ordered]@{
    Home        = $home_
    Dir         = $dir
    Exists      = (Test-Path $dir)
    Version     = 'unknown'
    Commit      = 'unknown'
    Channel     = 'unknown'
    Payload     = 'unknown'
    UpdateMech  = 'unknown'
    Desktop     = $false
    DesktopExe  = $null
    NodePin     = 'unknown'
    Cli         = (Get-Command hermes -ErrorAction SilentlyContinue).Source
  }
  if (-not $info.Exists) { return [pscustomobject]$info }

  $stamp = Join-Path $dir 'install-stamp.json'
  if (Test-Path $stamp) {
    $s = Get-Content $stamp -Raw | ConvertFrom-Json
    $info.Version    = $s.displayVersion
    $info.Commit     = $s.commit
    $info.Payload    = $s.payload
    $info.UpdateMech = $s.updateMechanism
    if ($s.branch) { $info.Channel = $s.branch }
    # 没记录渠道时按 stamp 推：distance=0 说明正好停在某个 release tag 上（stable），
    # 否则是在 tag 之后的 commit 上（main）。config.yaml 里的记录优先。
    if ($info.Channel -eq 'unknown' -and $null -ne $s.distance) {
      $info.Channel = if ([int]$s.distance -eq 0) { 'stable' } else { 'main' }
    }
  } else {
    $info.Payload = 'legacy'
  }
  $cfg = Join-Path $home_ 'config.yaml'
  if (Test-Path $cfg) {
    $m = Select-String -Path $cfg -Pattern '^\s+channel:\s*(\S+)' | Select-Object -First 1
    if ($m) { $info.Channel = $m.Matches[0].Groups[1].Value.Trim('"',"'") }
  }
  $lock = Join-Path $dir 'pm/lock.json'
  if (Test-Path $lock) {
    try { $info.NodePin = (Get-Content $lock -Raw | ConvertFrom-Json).packages.node.version } catch {}
  }
  $exe = Join-Path $dir 'apps/desktop/release/win-unpacked/Hermes.exe'
  if (Test-Path $exe) { $info.Desktop = $true; $info.DesktopExe = $exe }
  [pscustomobject]$info
}

function Show-Install($i) {
  Say ''
  Say '── 本机 Hermes 安装 ─────────────────────────────────────────────' 'Cyan'
  Say ("  HERMES_HOME : {0}" -f $i.Home)
  Say ("  安装目录    : {0}" -f $(if ($i.Exists) { $i.Dir } else { "$($i.Dir)  (不存在)" }))
  Say ("  版本        : {0}" -f $i.Version)
  Say ("  commit      : {0}" -f $i.Commit)
  Say ("  渠道        : {0}" -f $i.Channel)
  Say ("  形态        : payload={0}  updateMechanism={1}" -f $i.Payload, $i.UpdateMech)
  Say ("  桌面壳      : {0}" -f $(if ($i.Desktop) { "有 ($($i.DesktopExe))" } else { '无（纯 CLI）' }))
  Say ("  Node 版本   : {0}" -f $i.NodePin)
  $rootDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($i.Home))
  $free = ([IO.DriveInfo]::new($rootDrive)).AvailableFreeSpace / 1GB
  Say ("  磁盘余量    : {0:N1} GB" -f $free)
  Say '─────────────────────────────────────────────────────────────────' 'Cyan'
}

# ─── 2. 目标版本 ────────────────────────────────────────────────────────────
function Get-Token {
  foreach ($n in @('GITHUB_TOKEN','GH_TOKEN')) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) { return $v.Trim() }
  }
  if (Get-Command gh -ErrorAction SilentlyContinue) {
    $t = & gh auth token 2>$null
    if ($t) { return ("$t").Trim() }
  }
  return ''      # 没有也能用：release 通道匿名可下，公开 API 匿名 60 次/小时
}

function Api-Get([string]$path) {
  $h = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'hermes-prebuild' }
  if ($script:Token) { $h['Authorization'] = "token $($script:Token)" }
  Invoke-RestMethod -Uri "https://api.github.com/$path" -Headers $h -TimeoutSec 90 -ErrorAction Stop
}

function Resolve-TargetSha($i, [string]$want) {
  $script:Token = Get-Token
  if ($want) {
    try { $sha = (Api-Get "repos/$Upstream/commits/$want").sha } catch { Fail "解析不了 ref '$want'（上游不存在这个分支/tag/SHA）" }
    return @{ Ref = $want; Sha = $sha.Trim() }
  }
  if ($i.Channel -eq 'stable') {
    $tag = (Api-Get "repos/$Upstream/releases/latest").tag_name
    $sha = (Api-Get "repos/$Upstream/commits/$tag").sha
    return @{ Ref = $tag; Sha = $sha.Trim() }
  }
  $sha = (Api-Get "repos/$Upstream/commits/main").sha
  @{ Ref = 'main'; Sha = $sha.Trim() }
}

# ─── 3. 找产物 ──────────────────────────────────────────────────────────────
function Find-Artifact($i, $short) {
  $kind = if ($i.Desktop) { "hermes-win-$Arch-$short" } else { "hermes-cli-win-$Arch-$short" }
  $resp = Api-Get "repos/$BuilderRepo/actions/artifacts?per_page=100"
  $hit = @($resp.artifacts | Where-Object { $_.name -eq $kind -and -not $_.expired } | Sort-Object id -Descending)[0]
  if (-not $hit) { return $null }
  [pscustomobject]@{ Id = $hit.id; Name = $hit.name; Expired = $hit.expired; Size = [int64]$hit.size_in_bytes; Kind = 'artifact'; Url = $null }
}

# release 通道：资产名 = <artifact 名>.zip
# 发布结构：只有稳定版一条线 —— tag = 版本号本身（v0.23.1），永久保留，回退锚点。
#           main / 分支的滚动产物已停出，main 渠道没有预编译可命中。
function Find-ReleaseAsset($i, $short, $ref) {
  $kind = if ($i.Desktop) { "hermes-win-$Arch-$short" } else { "hermes-cli-win-$Arch-$short" }
  $zipName = "$kind.zip"
  $slugs = @()
  if ($ref -match '^v') { $slugs += $ref }
  if ($slugs.Count -eq 0) {
    Say ("  目标 ref「{0}」不是正式版 tag —— 预编译只出稳定版，这条渠道没有产物（用 --set-channel stable 或让 update 本地编译）" -f $ref)
    return $null
  }
  foreach ($slug in $slugs) {
    try { $rel = Api-Get "repos/$BuilderRepo/releases/tags/$slug" } catch { continue }
    $a = @($rel.assets | Where-Object { $_.name -eq $zipName })[0]
    if (-not $a) { continue }
    Say ("  命中 release「{0}」" -f $slug)
    # Id 非空 → 下载走 api.github.com/releases/assets/<id>（github.com 在国内常整段不通）
    return [pscustomobject]@{
      Id = [int64]$a.id; Name = $a.name; Expired = $false; Size = [int64]$a.size
      Kind = 'release'; Url = $a.browser_download_url
    }
  }
  return $null
}

function Locate-Payload($i, $short, $ref) {
  switch ($Source.ToLower()) {
    'artifact' { Find-Artifact $i $short }
    'release'  { Find-ReleaseAsset $i $short $ref }
    default {
      $a = Find-ReleaseAsset $i $short $ref
      if (-not $a) { $a = Find-Artifact $i $short }
      $a
    }
  }
}

# ─── 4. 下载 + 校验 ─────────────────────────────────────────────────────────
function Get-Artifact($art) {
  $tmp = Join-Path $env:TEMP "hermes-prebuild-$($art.Id)"
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'payload.zip'
  $token = $script:Token
  Say ("  下载 {0}（{1:N0} MB，通道={2}）..." -f $art.Name, ($art.Size / 1MB), $art.Kind)
  $curlProxy = @()
  if ($script:ProxyUrl) { $curlProxy = @('-x', $script:ProxyUrl) }
  if ($art.Kind -eq 'release') {
    $ok = $false
    if ($art.Id) {
      $hdr = @('-H', 'Accept: application/octet-stream')
      if ($token) { $hdr += @('-H', "Authorization: token $token") }
      & curl.exe -fsSL @curlProxy @hdr --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 `
        -o $zip "https://api.github.com/repos/$BuilderRepo/releases/assets/$($art.Id)"
      $ok = ($LASTEXITCODE -eq 0)
    }
    if (-not $ok) {
      & curl.exe -fsSL @curlProxy --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 `
        -o $zip $art.Url
    }
  } else {
    & curl.exe -fsSL @curlProxy -H "Authorization: token $token" -H "Accept: application/zip" `
      --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 `
      -o $zip "https://api.github.com/repos/$BuilderRepo/actions/artifacts/$($art.Id)/zip"
  }
  if ($LASTEXITCODE -ne 0) { Fail "下载失败（curl 退出码 $LASTEXITCODE）" }
  $x = Join-Path $tmp 'x'
  Expand-Archive -Path $zip -DestinationPath $x -Force
  # 产物 zip 顶层带一层目录（artifact 名 / release 资产名）→ manifest.json 不在根上，降一层
  if (-not (Test-Path (Join-Path $x 'manifest.json'))) {
    $mj = Get-ChildItem -Path $x -Filter 'manifest.json' -Recurse -Depth 2 -File |
          Select-Object -First 1
    if ($mj) { $x = $mj.Directory.FullName }
  }
  Ok ("已解包到 {0}" -f $x)
  $x
}

function Verify-Payload($root, $target, $i) {
  $bad = @()
  $man = Join-Path $root 'manifest.json'
  if (-not (Test-Path $man)) { $bad += 'manifest.json 缺失' }
  else {
    $m = Get-Content $man -Raw | ConvertFrom-Json
    if ($m.sha -ne $target.Sha) { $bad += "manifest.sha=$($m.sha) != 目标 $($target.Sha)" }
    if ($m.platform -ne 'win32')  { $bad += "manifest.platform=$($m.platform) 不是 win32" }
    if ($m.arch -ne $Arch)        { $bad += "manifest.arch=$($m.arch) 不是 $Arch" }
    if ($i.NodePin -ne 'unknown' -and $m.node -ne $i.NodePin) { $bad += "manifest.node=$($m.node) != 本机 $($i.NodePin)" }
  }
  if ($i.Desktop) {
    $st = Join-Path $root 'apps/desktop/release/win-unpacked/resources/install-stamp.json'
    if (-not (Test-Path $st)) { $bad += 'win-unpacked/resources/install-stamp.json 缺失' }
    else {
      $s = Get-Content $st -Raw | ConvertFrom-Json
      if ($s.commit -ne $target.Sha) { $bad += "烘焙 stamp.commit=$($s.commit) != 目标 $($target.Sha)（覆盖也不会命中）" }
    }
    $exe = Join-Path $root 'apps/desktop/release/win-unpacked/Hermes.exe'
    if (-not (Test-Path $exe)) { $bad += 'win-unpacked/Hermes.exe 缺失' }
  }
  foreach ($r in @('hermes_cli/web_dist/hermes-build.json', 'ui-tui/dist/hermes-build.json',
                   'apps/desktop/dist/hermes-build.json')) {
    $p = Join-Path $root $r
    if (-not (Test-Path $p)) { if ($r -like 'apps/desktop/*' -and -not $i.Desktop) { continue }; $bad += "$r 缺失" }
  }
  if ($bad.Count) { Say '  校验未通过：' 'Red'; $bad | ForEach-Object { Say "    - $_" 'Red' }; return $false }
  Ok '校验通过：manifest / 烘焙 stamp / receipts 全部匹配'
  $true
}

# ─── 5. 备份 / 覆盖 / 回滚 ─────────────────────────────────────────────────
function Backup-Current($i) {
  $bk = Join-Path $i.Dir ".hermes-prebuild-backup-$($script:StampTs)"
  New-Item -ItemType Directory -Force -Path $bk | Out-Null
  $moved = 0
  foreach ($rel in @('apps/desktop/release/win-unpacked', 'apps/desktop/dist', 'apps/desktop/build/install-stamp.json',
                     'apps/desktop/build/native-deps', 'apps/desktop/build/native-deps.prepared.json',
                     'hermes_cli/web_dist', 'ui-tui/dist')) {
    $src = Join-Path $i.Dir $rel
    if (Test-Path $src) {
      $dst = Join-Path $bk $rel
      New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
      Move-Item $src $dst; $moved++
    }
  }
  Ok ("旧产物已备份到 {0}（{1} 项）" -f $bk, $moved)
  $bk
}

function Apply-Payload($root, $i) {
  $pairs = @(
    @{ Src = 'apps/desktop/release/win-unpacked'; Dst = 'apps/desktop/release/win-unpacked' },
    @{ Src = 'apps/desktop/dist';                 Dst = 'apps/desktop/dist' },
    @{ Src = 'apps/desktop/build/install-stamp.json'; Dst = 'apps/desktop/build/install-stamp.json' },
    @{ Src = 'apps/desktop/build/native-deps';    Dst = 'apps/desktop/build/native-deps' },
    @{ Src = 'apps/desktop/build/native-deps.prepared.json'; Dst = 'apps/desktop/build/native-deps.prepared.json' },
    @{ Src = 'hermes_cli/web_dist';               Dst = 'hermes_cli/web_dist' },
    @{ Src = 'ui-tui/dist';                       Dst = 'ui-tui/dist' }
  )
  foreach ($p in $pairs) {
    $s = Join-Path $root $p.Src
    if (-not (Test-Path $s)) { continue }
    $d = Join-Path $i.Dir $p.Dst
    New-Item -ItemType Directory -Force -Path (Split-Path $d) | Out-Null
    Copy-Item $s -Destination $d -Recurse -Force
    Ok ("覆盖 {0}" -f $p.Dst)
  }
}

# CI 的 receipt 里 hash 是构建机算的：sourceHash 覆盖 .npmrc/源码树（构建过程自己会改 .npmrc），
# prepared.nativeDeps 甚至与 CI 自己上传的目录都对不上 —— 跨机器永远为 false，桌面壳会白编一遍（实测 237 s）。
# 所以覆盖后按本机源码树重签三份 receipt（hash 全部本地实算）。安全性由前面的校验兜着：
# manifest.sha == 目标 SHA、win-unpacked 烘焙 stamp.commit == 目标 SHA、且 HEAD == 目标 SHA。
function SafeShort([string]$s, [int]$n = 12) {
  if (-not $s) { return 'unknown' }
  if ($s.Length -le $n) { return $s }
  return $s.Substring(0, $n)
}

# 只认 win-unpacked 目录下的 Hermes.exe —— 用进程名匹配会把同为 hermes.exe 的 gateway 也算进去
function Get-DesktopProcesses($i) {
  if (-not $i.DesktopExe) { return @() }
  $dir = Split-Path $i.DesktopExe -Parent
  @(Get-CimInstance Win32_Process -Filter "Name='Hermes.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
}

# 菜单里的「只检查」：显示 当前版本 → 目标版本，不下载
function Show-Plan($i) {
  $cur = if ($i.Version -and $i.Version -ne 'unknown') { "v$($i.Version)" } else { 'unknown' }
  if (-not $script:PlanTarget) {
    try { $script:PlanTarget = Resolve-TargetSha $i $null }
    catch { Warn ("  解析目标版本失败：{0}" -f $_.Exception.Message); return }
  }
  $t = $script:PlanTarget
  Say ''
  Say ("  当前版本：{0}    HEAD {1}" -f $cur, (SafeShort $i.Commit)) 'Cyan'
  Say ("  目标版本：{0}    SHA  {1}" -f $t.Ref, (SafeShort $t.Sha)) 'Cyan'
  $art = Locate-Payload $i $t.Sha.Substring(0, 12) $t.Ref
  if (-not $art) {
    Warn '  没有可用产物（CI 还没编这个版本，或资产已过期）'
    Say ("  可手动触发：gh workflow run prebuild.yml -R {0} -f ref={1}" -f $BuilderRepo, $t.Ref) 'Yellow'
    return
  }
  Ok ("  产物：{0}（{1:N0} MB，{2} 通道）" -f $art.Name, ($art.Size / 1MB), $art.Kind)
  if ($i.Commit -eq $t.Sha) {
    Ok '  已是目标版本：覆盖产物 + 重签约 2 分钟，build 段 0 秒'
  } else {
    Warn '  落后于目标：脚本会先取源码快照灌 git 对象再 checkout（多 3–6 分钟）'
  }
  Say ''
}

function Show-Menu {
  Say ''
  Say '── 可选操作 ─────────────────────────────────────────────────────' 'Cyan'
  Say '  1) 只检查：当前版本 vs 目标版本，看有没有对应产物（不下载、不落地）'
  Say '  2) 下载并覆盖产物（不跑 hermes update）'
  Say '  3) 下载覆盖 + 运行 hermes update（推荐）'
  Say '  4) 选一个具体 tag/SHA 再执行'
  Say '  5) 回滚到上一次备份'
  Say ("  6) 手动指定代理（当前：{0}）" -f $(if ($script:ProxyUrl) { $script:ProxyUrl } else { '直连' }))
  Say '  0) 退出'
  Say '─────────────────────────────────────────────────────────────────' 'Cyan'
}

function Get-NodeExe($i) {
  $tools = Join-Path $env:HERMES_HOME 'tools'
  $cands = @()
  if ($i.NodePin -and $i.NodePin -ne 'unknown') {
    $cands += (Join-Path $tools "node-$($i.NodePin)-win32-x64/node.exe")
  }
  $cands += @(Get-ChildItem $tools -Directory -Filter 'node-*-win32-*' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'node.exe' })
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Invoke-SignReceipts($i) {
  $signer = Join-Path $PSScriptRoot 'sign-receipts.mjs'
  if (-not (Test-Path $signer)) {
    Warn '  找不到 sign-receipts.mjs（脚本目录里应有一份）→ 跳过重签，build 段会照常本地编译'
    return
  }
  $node = Get-NodeExe $i
  if (-not $node) {
    Warn '  找不到目标机 node → 跳过 receipt 重签，build 段会照常本地编译'
    return
  }
  Say ("  用 {0} 重签 receipt..." -f (Split-Path $node -Leaf)) 'DarkGray'
  & $node $signer $i.Dir
  if ($LASTEXITCODE -ne 0) {
    Warn '  receipt 重签有失败项：build 段可能仍会本地编译（产物本身没问题）'
  }
}

# 目标机多半是 partial clone（--filter=blob:none）：本地只有 commit/tree，换版本时 checkout 要现拉
# 缺失 blob，GitHub 一断就卡死。release 里带 hermes-src-<tag>.tar.gz（上游源码快照），把内容灌进本地
# 对象库即可离线 checkout —— blob hash 由内容决定，与 GitHub 那份必然一致。
# 注意换行：仓库里 `*.ps1 text eol=crlf`，归档给的是 CRLF、库里存 LF，所以必须让 .gitattributes
# 生效（见下面两遍灌法），只加 --no-filters 会漏掉这批文件。
function Ensure-SourceTree($i, $target) {
  $head = (& git -C $i.Dir rev-parse HEAD 2>$null | Out-String).Trim()
  if ($head -eq $target.Sha) { Ok '  源码树已在目标 commit（不用补 git 对象）'; return $true }
  Say ("  源码树 HEAD {0} != 目标 {1} → 需要补 git 对象" -f $head.Substring(0, [Math]::Min(12, $head.Length)), $target.Sha.Substring(0, 12)) 'Yellow'

  if ($target.Ref -notmatch '^v') {
    Warn '  目标不是正式版 tag，定位不到源码快照；这条路径请自己 git fetch/checkout'
    return $false
  }
  $asset = "hermes-src-$($target.Ref).tar.gz"
  $tmp = Join-Path $env:TEMP "hermes-src-$($target.Sha.Substring(0,12))"
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $tar = Join-Path $tmp 'src.tar.gz'

  Say ("  取源码快照 {0} ..." -f $asset) 'Cyan'
  try {
    $rel = Api-Get "repos/$BuilderRepo/releases/tags/$($target.Ref)"
    $a = @($rel.assets | Where-Object { $_.name -eq $asset })[0]
    if (-not $a) { throw "release $($target.Ref) 里没有 $asset" }
    $curlProxy = @(); if ($script:ProxyUrl) { $curlProxy = @('-x', $script:ProxyUrl) }
    & curl.exe -fsSL @curlProxy --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 `
      -o $tar $a.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw ("curl 退出码 {0}" -f $LASTEXITCODE) }
  } catch {
    Warn ("  取不到源码快照：{0}" -f $_.Exception.Message)
    Warn '  → 需要网络；或者手工把 tar.gz 放到本目录后加 -SourceDir 重跑（本次跳过源码补齐）'
    return $false
  }
  Ok ("  已下载 {0:N0} MB" -f ((Get-Item $tar).Length / 1MB))

  Say '  解包 ...' 'DarkGray'
  & tar -xzf $tar -C $tmp
  if ($LASTEXITCODE -ne 0) { Warn '  tar 解包失败'; return $false }
  $srcDir = @(Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like 'hermes-agent-*' })[0]
  if (-not $srcDir) { Warn '  解包后找不到源码目录'; return $false }

  Say '  灌对象（git hash-object -w --no-filters）...' 'DarkGray'
  Push-Location $srcDir.FullName
  try {
    $list = Get-ChildItem -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
      $_.FullName.Substring($srcDir.FullName.Length + 1) -replace '\\', '/'
    }
    # 两遍都要跑，幂等：
    # ① 带 filter —— 让仓库 .gitattributes 生效。关键例子：`*.ps1 text eol=crlf` 会让归档里的 .ps1
    #    是 CRLF，而库里存的是 LF；不转就得到 42 个对不上的 blob（实测）。
    # ② --no-filters —— 兜底：归档本身已是库内字节（无 attributes 命中）时也能补上。
    $list | & git --git-dir="$($i.Dir)/.git" hash-object -w --stdin-paths 2>$null | Out-Null
    $list | & git --git-dir="$($i.Dir)/.git" hash-object -w --no-filters --stdin-paths 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Warn '  灌对象时有失败项（继续尝试 checkout）' }
  } finally { Pop-Location }

  Say ("  checkout -f {0} ..." -f $target.Sha.Substring(0, 12)) 'DarkGray'
  & git -C $i.Dir checkout -f $target.Sha 2>&1 | Out-Null
  $now = (& git -C $i.Dir rev-parse HEAD 2>$null | Out-String).Trim()
  if ($now -ne $target.Sha) {
    Warn ("  checkout 没成功（HEAD 仍是 {0}），多半还有 blob 缺失" -f $now)
    Warn '  → 补的办法：git -C <安装目录> fetch origin <tag>，或把 tar 里的文件再灌一遍'
    return $false
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Ok '  源码树已对齐目标 commit（全程离线）'
  $true
}

function Invoke-Rollback($i) {
  $bks = Get-ChildItem $i.Dir -Directory -Filter '.hermes-prebuild-backup-*' | Sort-Object Name -Descending
  if (-not $bks) { Fail '没有可回滚的备份' }
  $bk = $bks[0].FullName
  Say ("回滚到 {0}" -f $bk) 'Yellow'
  foreach ($rel in @('apps/desktop/release/win-unpacked', 'apps/desktop/dist', 'apps/desktop/build/install-stamp.json',
                     'apps/desktop/build/native-deps', 'apps/desktop/build/native-deps.prepared.json',
                     'hermes_cli/web_dist', 'ui-tui/dist')) {
    $src = Join-Path $bk $rel
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $i.Dir $rel
    Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
    Move-Item $src $dst
    Ok ("恢复 {0}" -f $rel)
  }
}

function Assert-DesktopClosed($i) {
  if (-not $i.Desktop) { return }
  $procs = @(Get-DesktopProcesses $i)
  if ($procs.Count -eq 0) { return }

  Warn ("Hermes 桌面正在运行（pid {0}）" -f ($procs.Id -join ','))
  Say '  Windows 会锁住 win-unpacked 里的 exe，必须先退出。' 'Yellow'

  if ($KillDesktop) {
    Say '  按 -KillDesktop 结束这些进程...' 'Yellow'
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $left = @(Get-DesktopProcesses $i)
    if ($left.Count) { Fail ("仍有 {0} 个桌面进程没退出，请手动结束" -f $left.Count) }
    Ok '已结束桌面进程'
    return
  }
  if ($Yes) { Fail '请先退出桌面版（或加 -KillDesktop 让脚本代劳）' }

  Say '    1) 我自己去关（脚本退出，关好再重跑）'
  Say '    2) 现在结束这些进程（未保存的内容会丢）'
  Say '    0) 取消'
  switch (Read-Host '选择') {
    '2' {
      $procs | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 3
      $left = @(Get-DesktopProcesses $i)
      if ($left.Count) { Fail ("仍有 {0} 个桌面进程没退出，请手动结束" -f $left.Count) }
      Ok '已结束桌面进程，继续'
    }
    default { Fail '已取消（退出桌面后重跑即可）' }
  }
}

# ─── 主流程 ────────────────────────────────────────────────────────────────
$i = Get-HermesInstall
# -Flavor 覆盖自动探测：桌面版取 hermes-<os>-<arch>-<sha>.zip，纯 CLI 版取 hermes-cli-<os>-<arch>-<sha>.zip
if ($Flavor -ne 'auto') {
  $wantDesktop = ($Flavor -eq 'desktop')
  if ($i.Desktop -ne $wantDesktop) {
    Warn ("按 -Flavor {0} 强制按{1}处理（自动探测结果是{2}）" -f $Flavor, $(if ($wantDesktop) {'桌面版'} else {'纯 CLI 版'}), $(if ($i.Desktop) {'桌面版'} else {'纯 CLI 版'}))
    $i.Desktop = $wantDesktop
  }
}
Show-Install $i
if ($i.Payload -eq 'legacy') {
  Warn '这台是老安装（没有 install-stamp.json）：产物可能对不上，建议先正常跑一次 hermes update 再回来用本脚本'
}

# 代理：命令行 > 系统设置 > 直连
$px = Resolve-Proxy
$script:ProxyUrl = $px.Url
Set-ProxyEnv $px.Url
Say ''
Say ("代理        : {0}  [{1}]" -f $(if ($px.Url) { $px.Url } else { '直连' }), $px.Source) 'Cyan'
if ($px.Url) {
  if (-not (Test-Proxy $px.Url)) {
    if ($Diagnose) {
      Warn '诊断模式：不提示，本次按直连继续'
      $script:ProxyUrl = $null; Set-ProxyEnv $null
    } elseif ($Yes) {
      Fail '代理不可用，且处于 -Yes 非交互模式；换 -Proxy 或加 -NoProxy'
    } else {
      $q = Read-Host '代理不通，改用直连继续？(y/N)'
      if ($q -match '^[Yy]') { $script:ProxyUrl = $null; Set-ProxyEnv $null; Say '  改为直连' 'Yellow' }
      else { return }
    }
  }
}

if ($Rollback) { Invoke-Rollback $i; return }
if ($Diagnose) {
  Show-Menu
  return
}

# 菜单循环：选 1（只检查）/6（代理）后回到菜单，选 2/3/4 才进主流程
if (-not $Ref -and -not $Yes) {
  $go = $false
  while (-not $go) {
    Show-Menu
    switch (Read-Host '选择') {
      '1' { Show-Plan $i }
      '2' { $SkipUpdate = $true; $go = $true }
      '3' { $go = $true }
      '4' {
        $k = Read-Host '  输入 tag / 分支 / SHA（如 v0.23.3）'
        if ($k) { $Ref = $k; $go = $true } else { Say '  没输入，回到菜单' 'Yellow' }
      }
      '5' { Invoke-Rollback $i; return }
      '6' {
        $p = Read-Host '  输入代理（ip:端口 或 http://ip:端口 / socks5://ip:端口，留空=直连）'
        if ($p) {
          $u = if ($p -match '^[a-z0-9]+://') { $p } else { "http://$p" }
          $script:ProxyUrl = $u; Set-ProxyEnv $u
          if (-not (Test-Proxy $u)) { Warn '代理不通，仍会尝试（下载失败会报错）' }
        } else { $script:ProxyUrl = $null; Set-ProxyEnv $null; Say '  已改为直连' 'Yellow' }
      }
      '0' { return }
      default { Say '  无效选择' 'Yellow' }
    }
  }
}

$target = Resolve-TargetSha $i $Ref
Say ''
Say ("目标：{0} @ {1}" -f $target.Ref, $target.Sha.Substring(0, 12)) 'Cyan'
if ($i.Commit -eq $target.Sha) { Warn '本机已经在这个 commit 上，覆盖没有意义（除非产物丢了）' }

# 先把「桌面还开着」挡在下载之前：否则白下 200 MB 才被断言拦下（实测踩过）
if (-not $DryRun -and -not $CheckOnly) { Assert-DesktopClosed $i }

$art = Locate-Payload $i $target.Sha.Substring(0, 12) $target.Ref
if (-not $art) {
  Warn ("找不到产物 {0}（CI 可能还没编这个 SHA，或已过期）" -f $target.Sha.Substring(0, 12))
  Say '  处理：在 hermes-prebuild 上手动 dispatch：' 'Yellow'
  Say ("    gh workflow run prebuild.yml -R {0} -f ref={1}" -f $BuilderRepo, $target.Ref) 'Yellow'
  return
}
Ok ("找到产物 {0}（{1:N0} MB，通道={2}）" -f $art.Name, ($art.Size / 1MB), $art.Kind)

if ($CheckOnly) {
  Say ''
  $same = ($i.Commit -eq $target.Sha)
  $curV = if ($i.Version -and $i.Version -ne 'unknown') { "v$($i.Version)" } else { 'unknown' }
  Say ("  当前版本：{0}    HEAD {1}" -f $curV, (SafeShort $i.Commit)) 'Cyan'
  Say ("  目标版本：{0}    SHA  {1}" -f $target.Ref, (SafeShort $target.Sha)) 'Cyan'
  Say ("  本机 HEAD {0}   目标 {1}   → {2}" -f (SafeShort $i.Commit), (SafeShort $target.Sha),
       $(if ($same) { '已对齐，直接覆盖产物即可' } else { '落后：脚本会先补源码快照再 checkout' })) 'Cyan'
  if ($same) { Ok '  结论：可以升级，覆盖 + 重签约 2 分钟，build 段 0 秒' }
  else       { Ok '  结论：可以升级，多一步源码灌对象（约 3-6 分钟）' }
  Say ''
  Say '  真正升级：重跑并选 3（覆盖 + hermes update）' 'Yellow'
  Say '  只下载并完整校验、不落地：重跑并加 -DryRun' 'Yellow'
  return
}

$root = Get-Artifact $art
if (-not (Verify-Payload $root $target $i)) {
  Say '  产物校验不过 → 不覆盖，保持现状（下次 hermes update 会本地全量编译）' 'Yellow'
  return
}
# 版本号从产物自带的 manifest.json 读：一条 release 一份，不依赖任何滚动覆盖的文件
try {
  $m = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
  if ($m.version) { Ok ("对应版本：{0}" -f $m.version) }
} catch {}

if ($DryRun) { Say ''; Say '[DryRun] 检查全部通过，未改动任何文件' 'Cyan'; return }

if (-not $Yes) {
  $go = Read-Host '确认覆盖？(y/N)'
  if ($go -notmatch '^[Yy]') { Say '已取消' 'Yellow'; return }
}

$srcOk = Ensure-SourceTree $i $target
if (-not $srcOk) {
  Warn '  源码树没对齐：产物照常覆盖，但 hermes update 的 git checkout 可能卡住（有网才行）'
}

$bk = Backup-Current $i
try {
  Apply-Payload $root $i
  Invoke-SignReceipts $i
  Ok '覆盖完成'
} catch {
  Warn ("覆盖失败：{0}" -f $_.Exception.Message)
  Say '  正在回滚...' 'Yellow'
  Invoke-Rollback $i
  Fail '已回滚到覆盖前状态'
}

if (-not $SkipUpdate) {
  Say ''
  # stable 渠道解析要 git ls-remote；Hermes 内部把 core.sshCommand 钉成 `ssh -o BatchMode=yes`，
  # 会丢掉全局配置里的 -i <key>，origin 是 SSH 时必然 exit 128。GIT_SSH_COMMAND 优先级更高。
  if (-not $env:GIT_SSH_COMMAND) {
    $sc = (& git config --get core.sshCommand 2>$null)
    if ($sc) {
      $env:GIT_SSH_COMMAND = "$sc -o BatchMode=yes"
      Say ("  已把 core.sshCommand 传给 hermes update：{0}" -f $env:GIT_SSH_COMMAND) 'DarkGray'
    }
  }
  Say '── 运行 hermes update（build 段应命中 receipt 直接跳过）────────────' 'Cyan'
  $cli = if ($i.Cli) { $i.Cli } else { 'hermes' }
  & $cli update
  if ($LASTEXITCODE -ne 0) {
    Warn ("hermes update 退出码 {0}" -f $LASTEXITCODE)
    Say ("  产物备份在 {0}；需要的话： .\hermes-update.ps1 -Rollback" -f $bk) 'Yellow'
  }
} else {
  Say ''
  Ok '已跳过 hermes update。之后手动跑：hermes update'
}
Say ''
Say ("完成。备份目录：{0}" -f $bk) 'Cyan'
