#!/usr/bin/env node
// 把 CI 编好的产物在目标机上「重签」成一份本机自洽的 receipt。
//
// 为什么必须重签：hermes-build.json 里的 hash 是构建机算的，
//   - inputs.sourceHash 覆盖 .npmrc / pnpm-lock / 源码树，CI 与目标机必然不同（构建过程自己会改 .npmrc）
//   - inputs.prepared[].hash 里 nativeDeps 甚至与 CI 自己上传的目录都对不上（构建后期又被改过）
// 所以跨机器复用只看 hash 永远为 false，桌面壳会白编一遍（实测 237 s）。
// 真正可靠的证明在别处：manifest.sha == 目标 SHA、win-unpacked 烘焙 stamp.commit == 目标 SHA，
// 同步脚本已先校验这两条，并且只在这种情况下才调用本脚本。
//
// 用法（同步脚本内部调用，一般不用手敲）：
//   node sign-receipts.mjs <root>            # 三个产品全签
//   node sign-receipts.mjs <root> desktop    # 只签一个
import { readFileSync, existsSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const PRODUCTS = [
  ['desktop', 'apps/desktop/dist'],
  ['web', 'hermes_cli/web_dist'],
  ['tui', 'ui-tui/dist'],
]

const [root, only] = process.argv.slice(2)
if (!root) {
  console.error('usage: sign-receipts.mjs <project-root> [desktop|web|tui]')
  process.exit(2)
}
const slash = root.replace(/\\/g, '/').replace(/\/+$/, '')
const freshness = await import(pathToFileURL(`${slash}/scripts/build/freshness.mjs`).href)

// prepared 输入的落点由产品决定；名字沿用 CI 写进 receipt 的那套（icons / nativeDeps / stamp）。
function preparedFor(product, names) {
  const prepared = {}
  for (const name of names) {
    if (name === 'icons') {
      prepared.icons = (product === 'web' || product === 'webapp')
        ? `${slash}/web/public`
        : `${slash}/apps/desktop/public`
    } else if (name === 'nativeDeps') {
      prepared.nativeDeps = `${slash}/apps/desktop/build/native-deps`
    } else if (name === 'stamp') {
      prepared.stamp = `${slash}/apps/desktop/build/install-stamp.json`
    }
  }
  return prepared
}

let signed = 0
for (const [product, rel] of PRODUCTS) {
  if (only && only !== product) continue
  const out = `${slash}/${rel}`
  const receipt = `${out}/hermes-build.json`
  if (!existsSync(receipt)) {
    console.log(`skip ${product}: 没有 ${rel}/hermes-build.json`)
    continue
  }
  let saved
  try {
    saved = JSON.parse(readFileSync(receipt, 'utf8'))
  } catch (err) {
    console.error(`skip ${product}: receipt 读不动（${err.message}）`)
    continue
  }
  const names = (saved.inputs?.prepared ?? []).map(x => x.name)
  const prepared = preparedFor(product, names)
  for (const [name, path] of Object.entries(prepared)) {
    if (!existsSync(path)) {
      console.error(`skip ${product}: prepared.${name} 不存在 → ${path}`)
      continue
    }
  }
  // 缺了 prepared 目录就不签，免得写出一份永久 false 的 receipt
  if (Object.keys(prepared).some(k => !existsSync(prepared[k]))) continue

  const inputs = freshness.buildInputs(slash, product, prepared)
  const stampClock = prepared.stamp
    ? JSON.parse(readFileSync(prepared.stamp, 'utf8')).builtAt
    : undefined
  freshness.recordProduct({ source: slash, product, out, inputs, stampClock })
  const ok = freshness.productCurrent({ source: slash, product, out })
  console.log(`${product}: receipt 已重签（prepared=${Object.keys(prepared).join(',') || '无'}） productCurrent=${ok}`)
  if (!ok) process.exitCode = 1
  signed++
}
console.log(`共签 ${signed} 份`)
