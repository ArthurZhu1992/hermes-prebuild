#!/usr/bin/env bash
# 一次性迁移：把旧的单一滚动 release「prebuild」换成「一个版本一条 release」。
# 前提：新的 prebuild.yml 已经推到 main。
# 用法：GH_TOKEN=... ./migrate-release-layout.sh     （需要能访问 github.com）
set -euo pipefail
R="${BUILDER_REPO:-ArthurZhu1992/hermes-prebuild}"
UP="${UPSTREAM:-NousResearch/hermes-agent}"

echo "== 0. 确认新版 workflow 已在远端"
gh api "repos/$R/contents/.github/workflows/prebuild.yml" --jq '.size' >/dev/null \
  || { echo "读不到 workflow，先 push 再说"; exit 1; }

echo "== 1. 删掉旧滚动 release（里面的资产是 main 线连续两次构建，重编即可，不必搬 400 MB）"
if gh release view prebuild -R "$R" >/dev/null 2>&1; then
  gh release view prebuild -R "$R" --json assets --jq '.assets[].name' | sed 's/^/   - /'
  gh release delete prebuild -R "$R" --yes --cleanup-tag && echo "   已删除 prebuild（含 tag）"
else
  echo "   没有 prebuild，跳过"
fi

echo "== 2. stable 线：上游最新正式版出包（永久回退锚点）"
TAG=$(gh api "repos/$UP/releases/latest" --jq .tag_name)
echo "   上游 latest = $TAG"
gh workflow run prebuild.yml -R "$R" -f ref="$TAG"

sleep 8
echo "== 3. main 线：滚动包"
gh workflow run prebuild.yml -R "$R" -f ref=main

echo
echo "== 4. 看进度 / 结果"
echo "   gh run list -R $R -L 3"
echo "   gh release list -R $R        # 期望：v$TAG 与 main 两条，标题里没有 +7919.g 这种尾巴"
