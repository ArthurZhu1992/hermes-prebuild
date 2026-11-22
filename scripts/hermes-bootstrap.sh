#!/usr/bin/env bash
# hermes-bootstrap.sh — Linux 一行命令入口（自检 + 交互菜单）
#
#   curl -fsSL https://raw.githubusercontent.com/ArthurZhu1992/hermes-prebuild/main/scripts/hermes-bootstrap.sh | bash
#
# 它把 hermes-update.sh 与它依赖的 sign-receipts.mjs 下到 $TMPDIR/hermes-prebuild/，
# 再交给 hermes-update.sh 的菜单（不传参数 = 菜单；可透传 --check / --ref v0.23.3 --yes 等）：
#
#   curl -fsSL .../hermes-bootstrap.sh | bash -s -- --check
#   curl -fsSL .../hermes-bootstrap.sh | bash -s -- --ref v0.23.3 --yes
#
# 注意：`curl | bash` 会把管道接到 bash 的 stdin，脚本里的 read 读不到键盘。
# 所以最后 exec 时显式 `</dev/tty` 把终端还给菜单；没有 tty（纯管道/CI）就保持原样。
set -uo pipefail

REPO="${BUILDER_REPO:-ArthurZhu1992/hermes-prebuild}"
DIR="${TMPDIR:-/tmp}/hermes-prebuild"
mkdir -p "$DIR" || { echo "!! 建不了目录 $DIR" >&2; exit 1; }

BASES=(
  "https://github.com/$REPO/releases/latest/download"
  "https://ghproxy.net/https://github.com/$REPO/releases/latest/download"
  "https://ghfast.top/https://github.com/$REPO/releases/latest/download"
  "https://raw.githubusercontent.com/$REPO/main/scripts"
)

printf '\033[0;36m── Hermes 预编译升级器 ──────────────────────────\033[0m\n'
hit=""
for b in "${BASES[@]}"; do
  printf '\033[0;90m  取脚本：%s\033[0m\n' "$b"
  if curl -fsSL --retry 2 --connect-timeout 20 -o "$DIR/hermes-update.sh.tmp" "$b/hermes-update.sh" 2>/dev/null \
     && curl -fsSL --retry 2 --connect-timeout 20 -o "$DIR/sign-receipts.mjs.tmp" "$b/sign-receipts.mjs" 2>/dev/null; then
    # 防 404 页面：主脚本至少几 KB，mjs 至少几百字节
    if [ "$(wc -c < "$DIR/hermes-update.sh.tmp")" -lt 5000 ] || [ "$(wc -c < "$DIR/sign-receipts.mjs.tmp")" -lt 800 ]; then
      printf '\033[0;33m    × 文件不完整（可能拿到 404 页面）\033[0m\n'
      rm -f "$DIR"/*.tmp
      continue
    fi
    mv "$DIR/hermes-update.sh.tmp" "$DIR/hermes-update.sh"
    mv "$DIR/sign-receipts.mjs.tmp" "$DIR/sign-receipts.mjs"
    chmod +x "$DIR/hermes-update.sh"
    hit="$b"
    break
  fi
  rm -f "$DIR"/*.tmp
  printf '\033[0;33m    × 这个源不可用\033[0m\n'
done

if [ -z "$hit" ]; then
  printf '\033[0;31m!! 所有来源都失败。手动下载这两个文件到同一目录后运行 hermes-update.sh：\033[0m\n' >&2
  printf '   https://github.com/%s/releases/latest\n' "$REPO" >&2
  exit 1
fi

printf '\033[0;32m  脚本就位：%s\033[0m\n\n' "$DIR"
if [ -r /dev/tty ]; then
  exec bash "$DIR/hermes-update.sh" "$@" </dev/tty
else
  exec bash "$DIR/hermes-update.sh" "$@"
fi
