# hermes-prebuild

给 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) **预编译**的构建器仓库。
本仓库不含任何上游代码——它只在 GitHub Actions 里 checkout 上游的某个 ref，编一遍，把**编译产物**打成交付包。

目的只有一个：让各机器上的 `hermes update` 不再本地跑 `electron-builder` / `vite` / `pnpm install`，
改成「下载已经编好的目录树 → 覆盖 → update 命中 receipt 直接跳过编译」。

> 这是**产物覆盖**方案，不是安装包。产物不是 `.deb` / `.AppImage` / `.MSIX`，
> 而是与 git 源码安装对位的已编译目录（`*-unpacked/`、`dist/`、receipts、烘焙 stamp）。

---

## 0. 一行命令（推荐）

PowerShell 里粘这一行，脚本自检本机安装，再给交互菜单（1 只检查 / 2 覆盖 / 3 覆盖+update / 4 指定版本 / 5 回滚 / 6 代理 / 0 退出）：

```powershell
$r=iwr 'https://github.com/ArthurZhu1992/hermes-prebuild/releases/latest/download/hermes-bootstrap.ps1';iex $(if($r.Content-is[byte[]]){[Text.Encoding]::UTF8.GetString($r.Content)}else{$r.Content})
```

> 为什么不是简单 `irm ... | iex`：release 资产的 `Content-Type` 是 `application/octet-stream`，
> PowerShell 5.1 的 `irm` 会把它当 `Byte[]`，直接 `| iex` 拿到的是字节数组而不是文本。
> 上面这行做了类型判断再解码。另外引导脚本本身是纯 ASCII —— `irm|iex` 按系统 ANSI 码页解码，
> 中文会被打散成解析错误。

如果 `raw.githubusercontent.com` 在你那边能直连（它返回 `text/plain; charset=utf-8`），一行更短：

```powershell
irm https://raw.githubusercontent.com/ArthurZhu1992/hermes-prebuild/main/scripts/hermes-bootstrap.ps1 | iex
```

## 0.1 手动快速上手（30 秒）

脚本**随每个正式版一起发在 release 里**，不用碰 `raw.githubusercontent.com`（国内常年不通）：

```bash
# Linux —— REL 换成你要的版本号即可
REL=https://github.com/ArthurZhu1992/hermes-prebuild/releases/download/v0.23.2
curl -fsSLO "$REL/hermes-update.sh"
curl -fsSLO "$REL/sign-receipts.mjs"     # 覆盖后重签 receipt 要用，必须和 .sh 放同一个目录
chmod +x hermes-update.sh
./hermes-update.sh --diagnose            # 只读：看本机安装状态
./hermes-update.sh --ref v0.23.2 --yes   # 覆盖 + hermes update
```

```powershell
# Windows
$rel = 'https://github.com/ArthurZhu1992/hermes-prebuild/releases/download/v0.23.2'
irm "$rel/hermes-update.ps1" -OutFile hermes-update.ps1
irm "$rel/sign-receipts.mjs" -OutFile sign-receipts.mjs   # 同上，必须同目录
powershell -ExecutionPolicy Bypass -File .\hermes-update.ps1 -Diagnose
powershell -ExecutionPolicy Bypass -File .\hermes-update.ps1 -Ref v0.23.2 -Yes
```

脚本本身与版本无关（通用），每个 release 带一份**当时的**快照；想拿最新未发版的脚本才走 raw：

```
https://raw.githubusercontent.com/ArthurZhu1992/hermes-prebuild/main/scripts/hermes-update.ps1
https://raw.githubusercontent.com/ArthurZhu1992/hermes-prebuild/main/scripts/sign-receipts.mjs
```

不带参数运行 = 交互菜单。**不需要 GitHub token**：产物走 release 匿名直链，公开 API 匿名配额够用。


## 1. 产物

每次构建按 ref 产四种 artifact（名字 = `hermes-<os>-<arch>-<sha12>`，保留 7 天）：

| artifact | 内容 | zip 后 |
|---|---|---|
| `hermes-win-x64-<sha12>` | `apps/desktop/release/win-unpacked`、`apps/desktop/dist`、`apps/desktop/build/install-stamp.json`、`hermes_cli/web_dist`、`ui-tui/dist` | ~150 MB |
| `hermes-linux-x64-<sha12>` | 同上，`linux-unpacked` | ~150 MB |
| `hermes-cli-linux-<sha12>` | 只有 `hermes_cli/web_dist` + `ui-tui/dist`（纯 CLI 机器，无 Electron） | ~2.4 MB |
| `hermes-cli-win-x64-<sha12>` | 同上，`manifest.platform=win32`（Windows 纯 CLI 机器） | ~2.4 MB |

同一批产物还会再发一份到 **Releases** —— **一个上游正式版一条 release**：

| 来源 | release tag | 标题 | 保留策略 |
|---|---|---|---|
| 上游最新 release tag（自动） | `v0.23.1` | `v0.23.1` | **永久**，回退锚点 |
| 手动指定历史 tag（`--ref v0.22.7`） | `v0.22.7` | `v0.22.7` | **永久**，每个正式版都能回退 |

**只构建上游正式版（release tag）。** `main` 与任意分支/裸 sha 不再出产物：
dispatch 给了非 tag ref，resolve 会直接跳过、什么都不编；`hermes-update.sh -Ref main` 也找不到东西，
只会在本机走 `hermes update` 的本地全量编译。

版本号只出上游语义版本，等于上游 release tag，不掺 git describe 尾巴（不会出现 `v0.23.1.7919` 或
`v0.23.1+7919.gb9cb7a2`）。

每条 release 自带一份 `manifest.json`（`{version, ref, sha, base, persisted, built_at, assets[]}`），
脚本从这份文件读版本号。

| 通道 | 位置 | 有效期 | 下载是否需要登录 | 实际走哪个域 |
|---|---|---|---|---|
| artifact | Actions 产物 | 7 天 | **需要** | Azure blob（国内常可达） |
| release | 一个版本一条 release，资产名带 sha12 | **永久** | **不需要** | api.github.com → release-assets.githubusercontent.com |

脚本用 `--source` 选通道（PS 是 `-Source`）：

```bash
./hermes-update.sh --source auto       # 默认：先 release（匿名、不过期、本机实测 4.7 MB/s），找不到再 artifact
./hermes-update.sh --source release    # 强制走 release（匿名直链）
./hermes-update.sh --source artifact   # 强制走 Actions 产物
```

每个 artifact 根目录有 `manifest.json`：

```json
{ "ref": "v0.23.1", "sha": "3b4215785882...", "platform": "linux",
  "arch": "x64", "node": "26.12.1", "built_at": "...", "workflow_run": "..." }
```

## 2. 触发

| 方式 | 说明 |
|---|---|
| `schedule`（每天 03:17 UTC） | 查上游最新 release tag，本仓库 `state/last-built.json` 里还没有这个 tag 的产物才构建；否则 10 秒早退 |
| `push`（main） | 构建器自身（workflow / scripts）改动推上来就自动跑一次检查 |
| `workflow_dispatch` | 手动指定上游 tag（如 `v0.22.7`）补历史版本；给非 tag ref 会被跳过 |

**只编稳定版**：上游一发新版，下一次 schedule 就会自动出包（`v0.24.0` 这种），一条 release 永久保留。
`main` / 分支 / 裸 sha 不再出产物，`--force` 也只是重编当前稳定版。

```bash
# 上游发新版后手动出包（留空即取上游最新 release tag）
gh workflow run prebuild.yml -R ArthurZhu1992/hermes-prebuild -f ref=v0.23.1

# 强制重编稳定版（忽略 last-built 状态）
gh workflow run prebuild.yml -R ArthurZhu1992/hermes-prebuild -f ref=v0.23.1 -f force=true
```

构建用的是 `hermes update` 自己那套函数（`hermes_cli.source_build.build_update_products`），
所以产出的 `hermes-build.json` receipt 与目标机同 SHA 时逐字段一致（`platform`/`arch`/`node`）。
Node 版本固定 `26.12.1`（取自 `pm/lock.json`），这是 receipt 校验的一部分。

## 3. 用脚本升级（推荐）

两个脚本做同一件事，只在平台实现上不同：

| 平台 | 脚本 |
|---|---|
| Windows | `scripts/hermes-update.ps1` |
| Linux | `scripts/hermes-update.sh` |

下载后：

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\hermes-update.ps1
```
```bash
# Linux
chmod +x hermes-update.sh && ./hermes-update.sh
```

脚本依次做：

1. **探测**：`HERMES_HOME`、安装目录、版本、commit、渠道（main/stable）、
   `payload`/`updateMechanism`、有没有桌面壳、`pm/lock.json` 的 Node pin、磁盘余量
2. **选目标**：渠道 `stable` → 最新正式 tag；`main` → 上游 HEAD；或 `--ref` 指定
3. **找产物**：按 `hermes-<os>-<arch>-<sha12>` 匹配，没有桌面壳就用 `hermes-cli-*` 轻包
4. **校验**：`manifest.sha` / `platform` / `arch` / `node`、烘焙 stamp 的 `commit`、三个 receipt 是否存在
5. **备份 → 覆盖 → 可选跑 `hermes update`**：备份在 `<安装目录>/.hermes-prebuild-backup-<时间戳>/`

### 交互菜单

不带参数运行会先打印安装状态，然后给菜单：

```
  1) 只检查：本机版本 vs 目标版本，看有没有对应产物
  2) 下载并覆盖产物（不跑 hermes update）
  3) 下载覆盖 + 运行 hermes update（推荐）
  4) 选一个具体 tag/SHA 再执行
  5) 回滚到上一次备份
  6) 手动指定代理（ip:端口 / http://… / socks5://…，留空=直连）
  0) 退出
```

### 非交互 / 自动化

```bash
./hermes-update.sh --diagnose            # 只打印状态
./hermes-update.sh --dry-run             # 走完所有检查，不落地
./hermes-update.sh --ref v0.23.1 --yes   # 直接干到 v0.23.1
./hermes-update.sh --skip-update --yes   # 只覆盖，不更新
./hermes-update.sh --rollback            # 回滚上一次覆盖
```

```powershell
.\hermes-update.ps1 -Diagnose
.\hermes-update.ps1 -DryRun
.\hermes-update.ps1 -Ref v0.23.1 -Yes
.\hermes-update.ps1 -Rollback
```

### 要 token 吗

**不需要。** release 通道匿名可下，公开 API 匿名 60 次/小时够这个脚本用。
只有强制 `--source artifact` 才需要 token（`gh auth login` 或 `export GITHUB_TOKEN=…`）。

没有 `gh` 也行：脚本自动退化到 `curl` + `jq`；两者都没有时会提示你装哪个。

环境变量可覆盖仓库名：`BUILDER_REPO`（bash）/ 参数 `-BuilderRepo`（PS）。

### 代理（下载 artifact 与 `gh api` 都要用）

优先级：**命令行 `--proxy` > 环境变量 > 系统代理 > 直连**。

| 平台 | 自动读取的系统代理 |
|---|---|
| Windows | 注册表 `HKCU\...\Internet Settings` 的 `ProxyEnable`/`ProxyServer`（支持 `http=host:port;https=host:port` 写法），以及 `HTTPS_PROXY`/`ALL_PROXY`/`HTTP_PROXY` |
| Linux | `HTTPS_PROXY`/`ALL_PROXY`/`HTTP_PROXY`；GNOME 桌面读 `gsettings get org.gnome.system.proxy mode` == `manual` 时的 host/port（含 socks） |

```bash
./hermes-update.sh --proxy 127.0.0.1:7890         # 只写 ip:端口时默认按 http://
./hermes-update.sh --proxy socks5://10.0.0.2:1080
./hermes-update.sh --no-proxy                     # 无视系统代理，强制直连
```
```powershell
.\hermes-update.ps1 -Proxy 127.0.0.1:7890
.\hermes-update.ps1 -NoProxy
```

行为细节：

- 解析到代理后**先实测**（`curl -x <proxy> https://api.github.com/` 必须 200 才算通）
- 不通时：交互模式问你要不要改直连；`--yes` 直接报错退出；`--diagnose` 只警告并按直连继续
- 交互菜单里有 `6) 手动指定代理`，可现场输入 `ip:端口`
- 代理只作用于**本脚本的下载与 API 调用**（`curl` + `gh`）；`hermes update` 自己的 git/uv/pnpm 走它自己的镜像与 git 配置，不受影响

## 4. 覆盖之后会发生什么

`hermes update` 的三个判定会被满足，于是编译被跳过：

- `ui-tui/dist/hermes-build.json` 与 `hermes_cli/web_dist/hermes-build.json` 的输入树 hash + Node 版本一致 → 打印 `✓ TUI is up to date`，不跑 tsc/vite
- `release/*-unpacked/resources/install-stamp.json` 的 `commit` == 本地 HEAD 且输入一致 → 不跑 electron-builder（最贵的一段）
- `pyproject.toml` / `uv.lock` / `pnpm-lock.yaml` 没变的更新里，依赖段本来就快

**任何一条校验不通过，脚本什么都不改**，`hermes update` 就退回原来的本地全量编译——最差等于没用过这个仓库。

## 5. 前置条件与边界

- 目标机**不需要** `gh`/token（release 通道匿名可下）；强制 `--source artifact` 才需要用 token
- 覆盖前必须退出桌面应用（Windows 会锁 `win-unpacked` 里的 exe；Linux 锁 `linux-unpacked`）
- 脚本只动**被 gitignore 的编译产物**：`release/*-unpacked`、`dist/`、`web_dist/`、`build/install-stamp.json`
- **永远不碰** `HERMES_HOME` 里的数据（`sessions/`、`skills/`、`config.yaml`、`memories/`）
- 覆盖的只是编译输出；代码仍然由 `hermes update` 的 `git fetch/pull` 更新
- 不要手改 `install-stamp.json`：在 bundle 形态下运行中的 app 会比对启动 stamp，改错会反复重启

## 6. 已知坑

| 现象 | 原因 / 处理 |
|---|---|
| 找不到产物 | CI 没编这个 SHA（手动 `gh workflow run`），或已超过 7 天保留期 |
| `manifest.node != 本机` | 本机 `pm/lock.json` 的 Node pin 与构建机不同 → 换对应 SHA 的产物，或本地编译 |
| 覆盖后 update 仍全量编译 | 目标 SHA 与本地产物不一致；看日志里 `Desktop app build owed:` 后面的原因 |
| Windows 覆盖失败 | Hermes 桌面还在跑；退出后重跑（脚本会检测并直接报错） |
| Linux 产物起不来 | 构建镜像（ubuntu-24.04）比目标机新太多；本仓库固定用 24.04，26.04 目标机可运行 |

## 7. Linux 用哪个 bundle

`linux-unpacked` 的 Electron 二进制依赖 glibc。构建机固定 `ubuntu-24.04`：
24.04 打出的产物在 24.04 / 26.04 上都能跑（新 glibc 跑旧二进制没问题），反过来不行。
所以**不要**把 `runs-on` 改成比目标机更新的镜像。
