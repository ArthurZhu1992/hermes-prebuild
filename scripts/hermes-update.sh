#!/usr/bin/env bash
# hermes-update.sh — Linux 端预编译产物同步器
#
# 探测本机 Hermes 安装 → 按渠道取目标版本 → 下载 hermes-prebuild 的产物 →
# 校验 manifest / 烘焙 stamp / receipt → 备份并覆盖 → 可选运行 hermes update。
#
# 校验不过什么都不改；覆盖失败自动回滚。永远不碰 HERMES_HOME 里的数据。
#
# 用法：
#   ./hermes-update.sh                      # 交互菜单
#   ./hermes-update.sh --diagnose           # 只看状态
#   ./hermes-update.sh --ref v0.23.1 --yes  # 非交互直接干
#   ./hermes-update.sh --dry-run            # 全部检查通过但不落地
#   ./hermes-update.sh --skip-update        # 只覆盖，不跑 hermes update
#   ./hermes-update.sh --rollback           # 回滚上一次覆盖
#   ./hermes-update.sh --proxy 127.0.0.1:7890        # 指定代理（ip:port 默认 http）
#   ./hermes-update.sh --proxy socks5://10.0.0.2:1080
#   ./hermes-update.sh --no-proxy           # 忽略系统代理，强制直连
#   ./hermes-update.sh --source release     # auto(默认) | artifact | release
#
#
# 代理来源优先级：--proxy > 环境变量(HTTPS_PROXY/ALL_PROXY/HTTP_PROXY) > GNOME 系统代理 > 直连
set -uo pipefail

BUILDER_REPO="${BUILDER_REPO:-ArthurZhu1992/hermes-prebuild}"
UPSTREAM="${UPSTREAM:-NousResearch/hermes-agent}"
REF=""; DIAGNOSE=0; DRY_RUN=0; YES=0; SKIP_UPDATE=0; ROLLBACK=0
PROXY_URL="${PROXY_URL:-}"; SKIP_PROXY=0
SOURCE="${SOURCE:-auto}"   # auto | artifact | release
STAMP_TS=$(date +%Y%m%d-%H%M%S)

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2;;
    --ref=*) REF="${1#*=}"; shift;;
    --proxy) PROXY_URL="$2"; shift 2;;
    --proxy=*) PROXY_URL="${1#*=}"; shift;;
    --no-proxy) SKIP_PROXY=1; shift;;
    --source) SOURCE="$2"; shift 2;;
    --source=*) SOURCE="${1#*=}"; shift;;
    --diagnose) DIAGNOSE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -y|--yes) YES=1; shift;;
    --skip-update) SKIP_UPDATE=1; shift;;
    --rollback) ROLLBACK=1; shift;;
    -h|--help) sed -n '2,26p' "$0"; exit 0;;
    *) echo "未知参数: $1" >&2; exit 2;;
  esac
done

c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
say() { c '0;37' "$1"; }
ok()  { c '0;32' "  OK   $1"; }
warn(){ c '0;33' "  !!   $1"; }
die() { c '0;31' "  XX   $1"; exit 1; }
head_() { c '0;36' "$1"; }

ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=x64;; aarch64) ARCH=arm64;; esac

# ─── 0. 代理 ────────────────────────────────────────────────────────────────
PX=""; PX_SRC="无（直连）"
detect_proxy() {
  if [ "$SKIP_PROXY" = 1 ]; then PX=""; PX_SRC="已禁用(--no-proxy)"; return; fi
  if [ -n "$PROXY_URL" ]; then
    case "$PROXY_URL" in *://*) PX="$PROXY_URL";; *) PX="http://$PROXY_URL";; esac
    PX_SRC="命令行 --proxy"; return
  fi
  # 1) 环境变量
  local v
  for v in "${HTTPS_PROXY:-}" "${https_proxy:-}" "${ALL_PROXY:-}" "${all_proxy:-}" "${HTTP_PROXY:-}" "${http_proxy:-}"; do
    if [ -n "$v" ]; then PX="$v"; PX_SRC="环境变量"; return; fi
  done
  # 2) GNOME 系统代理（Linux 桌面）
  if command -v gsettings >/dev/null 2>&1; then
    local mode h p sch
    mode=$(gsettings get org.gnome.system.proxy mode 2>/dev/null | tr -d "'")
    if [ "$mode" = "manual" ]; then
      for sch in http https socks; do
        h=$(gsettings get "org.gnome.system.proxy.$sch" host 2>/dev/null | tr -d "'")
        p=$(gsettings get "org.gnome.system.proxy.$sch" port 2>/dev/null)
        if [ -n "$h" ] && [ "${p:-0}" != "0" ]; then
          if [ "$sch" = socks ]; then PX="socks5://$h:$p"; else PX="http://$h:$p"; fi
          PX_SRC="GNOME 系统代理($sch)"; return
        fi
      done
    fi
  fi
}

apply_proxy() {
  if [ -n "$PX" ]; then
    export HTTPS_PROXY="$PX" HTTP_PROXY="$PX" ALL_PROXY="$PX"
    export https_proxy="$PX" http_proxy="$PX" all_proxy="$PX"
    export NO_PROXY="localhost,127.0.0.1,::1"
  fi
}

test_proxy() {
  [ -z "$PX" ] && return 0
  say "  探测代理 $PX ..."
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -x "$PX" --connect-timeout 10 --max-time 20 https://api.github.com/ 2>/dev/null)
  if [ "$code" = "200" ]; then ok '代理可用（api.github.com → 200）'; return 0; fi
  warn "代理没通（返回 '$code'）：用 --proxy 换一个，或 --no-proxy 直连"
  return 1
}

# ─── 1. 探测 ────────────────────────────────────────────────────────────────
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
INSTALL_DIR="$HERMES_HOME/hermes-agent"

probe() {
  python3 - "$HERMES_HOME" "$INSTALL_DIR" <<'PY'
import json, os, shutil, subprocess, sys
home, d = sys.argv[1], sys.argv[2]
out = {"home": home, "dir": d, "exists": os.path.isdir(d), "version": "unknown",
       "commit": "unknown", "channel": "unknown", "payload": "unknown", "mech": "unknown",
       "desktop": False, "node": "unknown", "cli": shutil.which("hermes") or ""}
st = os.path.join(d, "install-stamp.json")
if os.path.isfile(st):
    try:
        s = json.load(open(st, encoding="utf-8-sig"))
        out.update(version=s.get("displayVersion") or "unknown", commit=s.get("commit") or "unknown",
                   payload=s.get("payload") or "unknown", mech=s.get("updateMechanism") or "unknown")
        if s.get("branch"): out["channel"] = s["branch"]
        # 没记录渠道时按 stamp 推：distance=0 = 停在 release tag 上（stable），否则在 tag 之后（main）
        if out["channel"] == "unknown" and s.get("distance") is not None:
            out["channel"] = "stable" if int(s["distance"]) == 0 else "main"
    except Exception: pass
else:
    out["payload"] = "legacy"
cfg = os.path.join(home, "config.yaml")
if os.path.isfile(cfg):
    import re
    m = re.search(r"^\s+channel:\s*(\S+)", open(cfg, encoding="utf-8", errors="replace").read(), re.M)
    if m: out["channel"] = m.group(1).strip("\"'")
lk = os.path.join(d, "pm/lock.json")
if os.path.isfile(lk):
    try: out["node"] = json.load(open(lk, encoding="utf-8"))["packages"]["node"]["version"]
    except Exception: pass
for p in ("apps/desktop/release/linux-unpacked/Hermes", "apps/desktop/release/linux-unpacked/hermes"):
    if os.path.isfile(os.path.join(d, p)): out["desktop"] = True
out["free_gb"] = round(shutil.disk_usage(home if os.path.isdir(home) else "/").free / 2**30, 1)
print(json.dumps(out))
PY
}

show_install() {
  head_ ''
  head_ '── 本机 Hermes 安装 ─────────────────────────────────────────────'
  printf '  HERMES_HOME : %s\n' "$(jget home)"
  printf '  安装目录    : %s\n' "$(jget dir)"
  printf '  版本        : %s\n' "$(jget version)"
  printf '  commit      : %s\n' "$(jget commit)"
  printf '  渠道        : %s\n' "$(jget channel)"
  printf '  形态        : payload=%s  updateMechanism=%s\n' "$(jget payload)" "$(jget mech)"
  if [ "$(jget desktop)" = "True" ]; then printf '  桌面壳      : 有 (apps/desktop/release/linux-unpacked)\n'
  else printf '  桌面壳      : 无（纯 CLI）\n'; fi
  printf '  Node 版本   : %s\n' "$(jget node)"
  printf '  磁盘余量    : %s GB\n' "$(jget free_gb)"
  head_ '─────────────────────────────────────────────────────────────────'
}
jget() { printf '%s' "$PROBE" | python3 -c "import json,sys;print(json.load(sys.stdin)['$1'])"; }
[ -d "$INSTALL_DIR" ] || warn "安装目录不存在：$INSTALL_DIR（下面会照常显示，但覆盖会失败）"
PROBE=$(probe)

# ─── 2. 目标版本 ────────────────────────────────────────────────────────────
API_MODE=""; TOKEN=""
init_api() {
  TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if command -v gh >/dev/null 2>&1; then
    API_MODE=gh
    [ -n "$TOKEN" ] || { gh auth status >/dev/null 2>&1 && TOKEN=$(gh auth token); }
  else
    API_MODE=curl
    command -v jq >/dev/null 2>&1 || die '这台没有 gh 也没有 jq；装其中任一个即可'
    # 无 token 也能读公开仓库（匿名 60 次/小时），release 通道全程不需要认证
  fi
}

# api_get <path> <jq-filter>；两种后端输出一致
api_get() {
  local path="$1" jqf="$2"
  if [ "$API_MODE" = gh ]; then
    gh api "$path" --jq "$jqf"
  else
    local px=() auth=()
    [ -n "$PX" ] && px=(-x "$PX")
    [ -n "$TOKEN" ] && auth=(-H "Authorization: token $TOKEN")
    curl -fsSL ${px[@]+"${px[@]}"} ${auth[@]+"${auth[@]}"}          -H 'Accept: application/vnd.github+json' -H 'User-Agent: hermes-prebuild'          --retry 2 --connect-timeout 20 "https://api.github.com/$path" | jq -r "$jqf"
  fi
}

resolve_target() {
  init_api
  if [ -n "$REF" ]; then
    T_SHA=$(api_get "repos/$UPSTREAM/commits/$REF" '.sha' 2>/dev/null) || die "解析不了 ref '$REF'"
    T_REF="$REF"; return
  fi
  if [ "$(jget channel)" = "stable" ]; then
    T_REF=$(api_get "repos/$UPSTREAM/releases/latest" '.tag_name')
    T_SHA=$(api_get "repos/$UPSTREAM/commits/$T_REF" '.sha')
  else
    T_REF="main"; T_SHA=$(api_get "repos/$UPSTREAM/commits/main" '.sha')
  fi
}

find_artifact() {
  short="${T_SHA:0:12}"
  if [ "$(jget desktop)" = "True" ]; then want="hermes-linux-$ARCH-$short"; else want="hermes-cli-linux-$short"; fi
  ART=$(api_get "repos/$BUILDER_REPO/actions/artifacts?per_page=100" \
        ".artifacts[] | select(.name==\"$want\" and .expired==false) | \"\(.id) \(.size_in_bytes)\"" \
        | sort -k1 -n | tail -1)
  [ -n "${ART:-}" ] || return 1
  ART_ID=${ART%% *}; ART_SIZE=${ART##* }; ART_NAME="$want"; PAYLOAD_KIND=artifact
}

# release 通道：资产名 = <artifact 名>.zip
# 发布结构：只有稳定版一条线 —— tag = 版本号本身（v0.23.1），永久保留，回退锚点
#           main / 分支的滚动产物已停出，main 渠道没有预编译可命中
release_asset() {   # <release-tag> <asset-name>  →  "id size url"
  api_get "repos/$BUILDER_REPO/releases/tags/$1" \
    ".assets[] | select(.name==\"$2\") | \"\(.id) \(.size) \(.browser_download_url)\"" 2>/dev/null
}

find_release_asset() {
  local want_zip="$want.zip" line slug slugs=()
  if [ -n "${T_REF:-}" ]; then case "$T_REF" in v*) slugs+=("$T_REF");; esac; fi
  if [ ${#slugs[@]} -eq 0 ]; then
    say "  目标 ref「${T_REF:-?}」不是正式版 tag —— 预编译只出稳定版，这条渠道没有产物（改用 stable 渠道或让 update 本地编译）"
    return 1
  fi
  for slug in "${slugs[@]}"; do
    if line=$(release_asset "$slug" "$want_zip") && [ -n "${line:-}" ]; then
      ART_ID=${line%% *}; line=${line#* }
      ART_SIZE=${line%% *}; ART_URL=${line#* }
      ART_NAME="$want_zip"; PAYLOAD_KIND=release
      say "  命中 release「$slug」"
      return 0
    fi
  done
  return 1
}

locate_payload() {
  case "$SOURCE" in
    artifact) find_artifact ;;
    release)  find_release_asset ;;
    *)        find_release_asset || find_artifact ;;
  esac
}

# ─── 3. 下载 + 校验 ─────────────────────────────────────────────────────────
download() {
  TMP=$(mktemp -d "/tmp/hermes-prebuild.XXXXXX")
  local px=() auth=()
  [ -n "$PX" ] && px=(-x "$PX")
  [ -n "${TOKEN:-}" ] && auth=(-H "Authorization: token $TOKEN")
  say "  下载 $ART_NAME（$((ART_SIZE/1024/1024)) MB，通道=$PAYLOAD_KIND）${PX:+（经代理 $PX）}..."
  if [ "$PAYLOAD_KIND" = release ]; then
    # 优先 api.github.com（资产 id → 302 到 release-assets.githubusercontent.com）：
    # github.com 在国内常被整段 RST，browser_download_url 直接 0 B/s，而 api 域名一般可达。
    local got=0
    if [ -n "${ART_ID:-}" ]; then
      curl -fsSL ${px[@]+"${px[@]}"} ${auth[@]+"${auth[@]}"} -H 'Accept: application/octet-stream' \
           --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
           -o "$TMP/payload.zip" "https://api.github.com/repos/$BUILDER_REPO/releases/assets/$ART_ID" \
           && got=1
    fi
    if [ "$got" = 0 ]; then
      curl -fsSL ${px[@]+"${px[@]}"} --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
           -o "$TMP/payload.zip" "$ART_URL" \
           || die 'release 资产下载失败（api 与 github.com 都不通，加 --proxy 再试）'
    fi
  else
    [ -n "$TOKEN" ] || die 'artifact 通道需要 GitHub token；改用 --source release（匿名可下）'
    curl -fsSL ${px[@]+"${px[@]}"} -H "Authorization: token $TOKEN" -H "Accept: application/zip" \
         --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 20 \
         -o "$TMP/payload.zip" "https://api.github.com/repos/$BUILDER_REPO/actions/artifacts/$ART_ID/zip" \
         || die '下载失败（换个 --proxy 或检查 gh auth）'
  fi
  mkdir -p "$TMP/x"
  if command -v unzip >/dev/null; then unzip -q "$TMP/payload.zip" -d "$TMP/x"
  else python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/payload.zip" "$TMP/x"; fi
  ROOT="$TMP/x"
  # 产物 zip 顶层带一层目录（artifact 名 / release 资产名），manifest.json 因此不在根上 → 降一层。
  # 少了这段，release / artifact 两条通道的 verify 都会判 manifest.json 缺失，覆盖永远不执行。
  if [ ! -f "$ROOT/manifest.json" ]; then
    mj=$(find "$ROOT" -maxdepth 3 -name manifest.json -print -quit 2>/dev/null)
    [ -n "${mj:-}" ] && ROOT=$(dirname "$mj")
  fi
  ok "已解包到 ${ROOT#$TMP/x/}"
}

verify() {
  local bad=()
  [ -f "$ROOT/manifest.json" ] || bad+=('manifest.json 缺失')
  if [ -f "$ROOT/manifest.json" ]; then
    m=$(python3 -c "import json;d=json.load(open('$ROOT/manifest.json'));print(d['sha'],d['platform'],d['arch'],d['node'])")
    set -- $m
    [ "$1" = "$T_SHA" ] || bad+=("manifest.sha=$1 != 目标 $T_SHA")
    [ "$2" = linux ]    || bad+=("manifest.platform=$2 不是 linux")
    [ "$3" = "$ARCH" ]  || bad+=("manifest.arch=$3 不是 $ARCH")
    if [ "$(jget node)" != unknown ] && [ "$4" != "$(jget node)" ]; then bad+=("manifest.node=$4 != 本机 $(jget node)"); fi
  fi
  if [ "$(jget desktop)" = "True" ]; then
    st="$ROOT/apps/desktop/release/linux-unpacked/resources/install-stamp.json"
    if [ ! -f "$st" ]; then bad+=('linux-unpacked/resources/install-stamp.json 缺失')
    else
      sc=$(python3 -c "import json;print(json.load(open('$st',encoding='utf-8-sig')).get('commit',''))")
      [ "$sc" = "$T_SHA" ] || bad+=("烘焙 stamp.commit=$sc != 目标 $T_SHA（覆盖也不会命中）")
    fi
  fi
  for r in hermes_cli/web_dist/hermes-build.json ui-tui/dist/hermes-build.json; do
    [ -f "$ROOT/$r" ] || bad+=("$r 缺失")
  done
  if [ ${#bad[@]} -gt 0 ]; then
    c '0;31' '  校验未通过：'; printf '    - %s\n' "${bad[@]}"
    return 1
  fi
  ok '校验通过：manifest / 烘焙 stamp / receipts 全部匹配'
}

# ─── 4. 备份 / 覆盖 / 回滚 ─────────────────────────────────────────────────
ITEMS=(apps/desktop/release/linux-unpacked apps/desktop/dist apps/desktop/build/install-stamp.json \
       apps/desktop/build/native-deps apps/desktop/build/native-deps.prepared.json \
       hermes_cli/web_dist ui-tui/dist)

backup() {
  BK="$INSTALL_DIR/.hermes-prebuild-backup-$STAMP_TS"
  mkdir -p "$BK"
  local n=0
  for rel in "${ITEMS[@]}"; do
    [ -e "$INSTALL_DIR/$rel" ] || continue
    mkdir -p "$BK/$(dirname "$rel")"
    mv "$INSTALL_DIR/$rel" "$BK/$rel"; n=$((n+1))
  done
  ok "旧产物已备份到 $BK（$n 项）"
}

apply_payload() {
  for rel in "${ITEMS[@]}"; do
    [ -e "$ROOT/$rel" ] || continue
    mkdir -p "$INSTALL_DIR/$(dirname "$rel")"
    cp -a "$ROOT/$rel" "$INSTALL_DIR/$rel" || return 1
    ok "覆盖 $rel"
  done
}

# CI 烘焙的 receipt 里 prepared[].path 记的是构建机的绝对路径（…/src/…）。
# freshness.mjs 拿这些 path 重算内容 hash 并逐字段比对，路径在目标机不存在就判「产物过期」→ 桌面壳白编一遍。
# hash 是内容 hash（与路径无关），所以只把 "/src/" 之前的前缀换成本机安装目录即可。
repair_receipt_paths() {
  python3 - "$INSTALL_DIR" <<'PY'
import json, os, re, sys
root = sys.argv[1]
fixed = 0
for rel in ("apps/desktop/dist/hermes-build.json",
            "hermes_cli/web_dist/hermes-build.json",
            "ui-tui/dist/hermes-build.json"):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        continue
    with open(p, encoding="utf-8") as f:
        raw = f.read()
    try:
        doc = json.loads(raw)
    except Exception:
        continue
    prepared = (doc.get("inputs") or {}).get("prepared") or []
    text = raw
    for item in prepared:
        old = item.get("path") or ""
        # CI 的 path 值里反斜杠是成对出现的（D:\\a\\...），按分隔符切最稳，别跟正则转义较劲
        parts = [x for x in re.split(r"[\\/]+", old) if x]
        if "src" not in parts:
            continue
        idx = len(parts) - 1 - parts[::-1].index("src")
        if idx >= len(parts) - 1:
            continue
        new = os.path.join(root, *parts[idx + 1:])
        if new == old:
            continue
        text = text.replace(json.dumps(old)[1:-1], json.dumps(new)[1:-1])
        fixed += 1
    if text != raw:
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(text)
print(fixed)
PY
}

rollback() {
  local bk
  bk=$(ls -1d "$INSTALL_DIR"/.hermes-prebuild-backup-* 2>/dev/null | sort | tail -1)
  [ -n "${bk:-}" ] || die '没有可回滚的备份'
  warn "回滚到 $bk"
  for rel in "${ITEMS[@]}"; do
    [ -e "$bk/$rel" ] || continue
    rm -rf "$INSTALL_DIR/$rel"
    mkdir -p "$INSTALL_DIR/$(dirname "$rel")"
    mv "$bk/$rel" "$INSTALL_DIR/$rel"
    ok "恢复 $rel"
  done
}

assert_closed() {
  [ "$(jget desktop)" = "True" ] || return 0
  if pgrep -f 'linux-unpacked/Hermes' >/dev/null 2>&1; then
    die 'Hermes 桌面正在运行，请先退出（它锁着 linux-unpacked）'
  fi
}

# ─── 主流程 ────────────────────────────────────────────────────────────────
show_install
if [ "$(jget payload)" = "legacy" ]; then
  warn '这台是老安装（没有 install-stamp.json）：产物可能对不上，建议先正常跑一次 hermes update 再回来用本脚本'
fi

detect_proxy
apply_proxy
head_ ''
c '0;36' "代理        : ${PX:-直连}  [$PX_SRC]"
if [ -n "$PX" ] && ! test_proxy; then
  if [ "$DIAGNOSE" = 1 ]; then
    warn '诊断模式：不提示，本次按直连继续'
    PX=""; unset HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy
  elif [ "$YES" = 1 ]; then
    die '代理不可用且处于 --yes 模式；换 --proxy 或加 --no-proxy'
  else
    read -r -p '代理不通，改用直连继续？(y/N) ' q
    if [[ "$q" =~ ^[Yy] ]]; then PX=""; unset HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy; warn '改为直连'
    else exit 1; fi
  fi
fi

[ "$ROLLBACK" = 1 ] && { rollback; exit 0; }

if [ "$DIAGNOSE" = 1 ] || { [ -z "$REF" ] && [ "$YES" = 0 ]; }; then
  head_ ''; head_ '── 可选操作 ─────────────────────────────────────────────────────'
  cat <<'MENU'
  1) 只检查：本机版本 vs 目标版本，看有没有对应产物
  2) 下载并覆盖产物（不跑 hermes update）
  3) 下载覆盖 + 运行 hermes update（推荐）
  4) 选一个具体 tag/SHA 再执行
  5) 回滚到上一次备份
  6) 手动指定代理（ip:端口 / http://… / socks5://…，留空=直连）
  0) 退出
MENU
  head_ '─────────────────────────────────────────────────────────────────'
  [ "$DIAGNOSE" = 1 ] && exit 0
  read -r -p '选择: ' choice
  case "$choice" in
    1) : ;;
    2) SKIP_UPDATE=1 ;;
    3) : ;;
    4) read -r -p '  输入 tag/分支/SHA（如 v0.23.1）: ' REF ;;
    5) rollback; exit 0 ;;
    6)
      read -r -p '  输入代理（留空=直连）: ' p
      if [ -n "$p" ]; then
        case "$p" in *://*) PX="$p";; *) PX="http://$p";; esac
        apply_proxy; test_proxy || warn '代理不通，仍会尝试（下载失败会报错）'
      else
        PX=""; unset HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy all_proxy; warn '已改为直连'
      fi
      ;;
    *) exit 0 ;;
  esac
fi

resolve_target
head_ ''
c '0;36' "目标：$T_REF @ ${T_SHA:0:12}"
[ "$(jget commit)" = "$T_SHA" ] && warn '本机已经在这个 commit 上，覆盖没有意义（除非产物丢了）'

if ! locate_payload; then
  warn "找不到产物 ${T_SHA:0:12}（CI 还没编这个 SHA，或已过期）"
  say "  处理：gh workflow run prebuild.yml -R $BUILDER_REPO -f ref=$T_REF"
  exit 1
fi
ok "找到产物 $ART_NAME（$((ART_SIZE/1024/1024)) MB，通道=$PAYLOAD_KIND）"
download
verify || { warn '产物校验不过 → 不覆盖，保持现状（下次 hermes update 会本地全量编译）'; exit 1; }
# 版本号从产物自带的 manifest.json 读：一条 release 一份，不依赖任何滚动覆盖的文件
ver=$(python3 -c "import json;print(json.load(open('$ROOT/manifest.json')).get('version',''))" 2>/dev/null || true)
[ -n "${ver:-}" ] && ok "对应版本：$ver" 
[ "$DRY_RUN" = 1 ] && { head_ ''; c '0;36' '[DryRun] 检查全部通过，未改动任何文件'; exit 0; }

assert_closed
if [ "$YES" = 0 ]; then read -r -p '确认覆盖？(y/N) ' go; [[ "$go" =~ ^[Yy] ]] || { warn '已取消'; exit 0; }; fi

backup
if ! apply_payload; then
  warn '覆盖失败，正在回滚...'; rollback; die '已回滚到覆盖前状态'
fi
n=$(repair_receipt_paths 2>/dev/null || echo 0)
[ "${n:-0}" != "0" ] && ok "receipt 路径改写 $n 项 → 本机安装目录（让 hermes update 认得出这批产物）"
ok '覆盖完成'

if [ "$SKIP_UPDATE" = 0 ]; then
  head_ ''
  # stable 渠道解析要 git ls-remote；Hermes 内部把 core.sshCommand 钉成 `ssh -o BatchMode=yes`，
  # 会丢掉全局配置里的 -i <key>，origin 是 SSH 时必然 exit 128。GIT_SSH_COMMAND 优先级更高。
  if [ -z "${GIT_SSH_COMMAND:-}" ] && command -v git >/dev/null 2>&1; then
    sc=$(git config --get core.sshCommand 2>/dev/null || true)
    if [ -n "${sc:-}" ]; then
      export GIT_SSH_COMMAND="$sc -o BatchMode=yes"
      c '0;90' "  已把 core.sshCommand 传给 hermes update：$GIT_SSH_COMMAND"
    fi
  fi
  head_ '── 运行 hermes update（build 段应命中 receipt 直接跳过）────────────'
  cli=$(jget cli); [ -n "$cli" ] || cli=hermes
  "$cli" update || warn "hermes update 退出码非 0；产物备份在 $BK，需要时 --rollback"
else
  head_ ''; ok '已跳过 hermes update。之后手动跑：hermes update'
fi
head_ ''; c '0;36' "完成。备份目录：$BK"
