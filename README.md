# hermes-prebuild

给 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) **预编译**的构建器仓库。
本仓库不含任何上游代码——它只在 GitHub Actions 里 checkout 上游的某个 ref，编一遍，把**编译产物**打成交付包。

目的只有一个：让各机器上的 `hermes update` 不再本地跑 `electron-builder` / `vite` / `pnpm install`，
改成「下载已经编好的目录树 → 覆盖 → update 命中 receipt 直接跳过编译」。

> 这是**产物覆盖**方案，不是安装包。产物不是 `.deb` / `.AppImage` / `.MSIX`，
> 而是与 git 源码安装对位的已编译目录（`*-unpacked/`、`dist/`、receipts、烘焙 stamp）。

---

## 0. 一行命令（推荐）

**Windows（PowerShell）** —— 粘贴即用，脚本自检本机安装再给交互菜单：

```powershell
$r=iwr 'https://github.com/ArthurZhu1992/hermes-prebuild/releases/latest/download/hermes-bootstrap.ps1';iex $(if($r.Content-is[byte[]]){[Text.Encoding]::UTF8.GetString($r.Content)}else{$r.Content})
```

> 为什么不是简单 `irm ... | iex`：release 资产的 `Content-Type` 是 `application/octet-stream`，
> PowerShell 5.1 的 `irm` 会把它当 `Byte[]`，直接 `| iex` 拿到的是字节数组而不是文本。
> 上面这行先判类型再解码。引导脚本本身是纯 ASCII —— `irm|iex` 按系统 ANSI 码页解码，中文会被打散成解析错误。

**Linux（bash）** —— 粘贴即用：

```bash
curl -fsSL https://github.com/ArthurZhu1992/hermes-prebuild/releases/latest/download/hermes-bootstrap.sh | bash
```

> 用 release 直链而不是 `raw.githubusercontent.com`：raw 有 CDN 缓存（改完脚本可能几分钟内还拿到旧版），
> release 资产是刚发的那一份。raw 能连的话也可以替换成
> `https://raw.githubusercontent.com/ArthurZhu1992/hermes-prebuild/main/scripts/hermes-bootstrap.sh`。

> `curl | bash` 会把管道接到 bash 的 stdin，菜单里的 `read` 就读不到键盘了 —— 引导脚本最后用
> `</dev/tty` 把终端还回来，所以菜单照常可用。非交互用法把参数透传进去：
>
> ```bash
> curl -fsSL <上面那条 URL> | bash -s -- --check            # 零下载，只看有没有得升
> curl -fsSL <上面那条 URL> | bash -s -- --ref v0.23.3 --yes
> ```

两边都能**手动**跑等价命令（已经下过脚本时）：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:TEMP\hermes-prebuild\hermes-update.ps1" -CheckOnly
```
```bash
bash "${TMPDIR:-/tmp}/hermes-prebuild/hermes-update.sh" --check
```

## 0.1 手动快速上手（30 秒）## 0.1 手动快速上手（30 秒）

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

| 平台 | 脚本 | 依赖 |
|---|---|---|
| Windows | `scripts/hermes-update.ps1` | `sign-receipts.mjs`（同目录）、`curl.exe`（Win10+ 自带） |
| Linux | `scripts/hermes-update.sh` | `sign-receipts.mjs`（同目录）、`curl`、`python3`、目标机自带的 node |

**`sign-receipts.mjs` 必须和主脚本放同一个目录**：覆盖产物后要用它按本机源码树重签三份 receipt，
缺了它脚本会静默跳过重签，结果是"能跑但下次 `hermes update` 又白编一遍"。

### 3.1 两种安装形态，脚本都会处理

| 形态 | 怎么认出来 | 用哪个产物包 | 覆盖哪些 | 升级前要关掉什么 |
|---|---|---|---|---|
| **桌面版**（Electron 壳 + CLI） | 安装目录里有 `apps/desktop/release/{win,linux}-unpacked/` | `hermes-<os>-<arch>-<sha12>.zip`（~203 MB） | `win-unpacked`/`linux-unpacked`、`apps/desktop/dist`、`build/install-stamp.json`、`build/native-deps*`、`hermes_cli/web_dist`、`ui-tui/dist` | **必须完全退出桌面版**（它锁着 unpacked 里的可执行文件） |
| **纯 CLI 版**（服务器/无 Electron） | 没有 unpacked 目录 | `hermes-cli-<os>-<arch>-<sha12>.zip`（~2 MB） | 只有 `hermes_cli/web_dist` + `ui-tui/dist` | 不用关任何窗口 |

自动识别靠"有没有 unpacked"，也可以用参数强制：`-Flavor desktop|cli`（Windows）/ `--flavor desktop|cli`（Linux）。
强制时会打印一行提示，说明自动探测结果与你的选择不一致。

### 3.2 一次升级实际做的事

1. **探测**：`HERMES_HOME`、安装目录、版本、commit、渠道（stable/main）、`payload`/`updateMechanism`、
   有没有桌面壳、`pm/lock.json` 的 Node pin、磁盘余量
2. **选目标**：渠道 `stable` → 上游最新正式 tag；`main` → 上游 HEAD；或 `-Ref/--ref` 指定
3. **找产物**：按 `<形态>-<os>-<arch>-<sha12>` 在 release 里精确匹配（`--check` 到这一步就停，不下载）
4. **下载 + 五道校验**：`manifest.sha` / `platform` / `arch` / `node`、`win-unpacked|linux-unpacked/resources/install-stamp.json`
   的 `commit`。任一不过 → **什么都不改**
5. **（HEAD 落后时）补源码**：从 release 取 `hermes-src-<tag>.tar.gz`，两遍 `git hash-object -w`
   （带 filter + `--no-filters`）灌进对象库，再 `git checkout -f <sha>` —— 全程不需要 git 网络
6. **备份 → 覆盖 → 重签 receipt → `hermes update`**
   - 备份在 `<安装目录>/.hermes-prebuild-backup-<时间戳>/`，覆盖失败自动回滚
   - 重签：`node sign-receipts.mjs <安装目录>` 让 `productCurrent` 变 true，`hermes update` 的 build 段才会真的跳过
   - 桌面进程检查在**下载之前**（不然白下 200 MB 才被拦）

### 3.3 交互菜单

不带参数运行 = 先打印安装状态，再给菜单：

```
  1) 只检查：本机版本 vs 目标版本，看有没有对应产物（不下载、不落地）
  2) 下载并覆盖产物（不跑 hermes update）
  3) 下载覆盖 + 运行 hermes update（推荐）
  4) 选一个具体 tag/SHA 再执行
  5) 回滚到上一次备份
  6) 手动指定代理（ip:端口 / http://… / socks5://…，留空=直连）
  0) 退出
```

### 3.4 非交互 / 自动化

| 用途 | Windows | Linux |
|---|---|---|
| 只打印安装状态 | `-Diagnose` | `--diagnose` |
| 只查产物与版本差异（零下载） | `-CheckOnly` | `--check` |
| 下载并全部校验、不落地 | `-DryRun` | `--dry-run` |
| 直接升到某版本 | `-Ref v0.23.3 -Yes` | `--ref v0.23.3 --yes` |
| 只覆盖不更新 | `-SkipUpdate` | `--skip-update` |
| 回滚 | `-Rollback` | `--rollback` |
| 指定代理 | `-Proxy http://127.0.0.1:7890` | `--proxy http://127.0.0.1:7890` |
| 强制直连 | `-NoProxy` | `--no-proxy` |
| 产物通道 | `-Source auto\|release\|artifact` | `--source …` |
| 安装形态 | `-Flavor auto\|desktop\|cli` | `--flavor …` |

```powershell
# Windows
.\hermes-update.ps1 -CheckOnly                 # 零下载，先看有没有得升
.\hermes-update.ps1 -Ref v0.23.3 -Yes          # 升级（必须先退出桌面版）
.\hermes-update.ps1 -Flavor cli -Ref v0.23.3 -Yes   # 纯 CLI 服务器
.\hermes-update.ps1 -Rollback
```

```bash
# Linux
./hermes-update.sh --check
./hermes-update.sh --ref v0.23.3 --yes
./hermes-update.sh --flavor cli --ref v0.23.3 --yes
./hermes-update.sh --rollback
```

### 3.5 失败与回滚

- 五道校验任一不过：直接退出，**不改任何文件**。
- 覆盖中途失败：脚本自动执行回滚（把备份移回来）。
- 回滚后仍是升级前的版本，可以照常启动。

### 3.6 要 token 吗

**不需要。** release 通道匿名可下，公开 API 匿名 60 次/小时够这个脚本用。
只有强制 `--source artifact` 才需要 token（Actions artifact 下载必须认证）。

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
