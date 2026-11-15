#!/usr/bin/env python3
"""从 Actions artifact zip 里按 HTTP Range 取单个小文件，不下载整个包。

用法: python zip_probe.py <owner/repo> <artifact-name> <entry> [<entry> ...]
"""
import json, struct, subprocess, sys, zlib

def sh(args):
    return subprocess.run(args, capture_output=True).stdout

def api(path, token):
    out = sh(["curl", "-fsSL", "-H", f"Authorization: token {token}",
              "-H", "Accept: application/vnd.github+json", f"https://api.github.com/{path}"])
    return json.loads(out)

def rng(url, token, a, b):
    out = sh(["curl", "-fsSL", "-H", f"Authorization: token {token}",
              "--range", f"{a}-{b}", url])
    return out

def main():
    repo, name = sys.argv[1], sys.argv[2]
    want = sys.argv[3:]
    token = sh(["gh", "auth", "token"]).decode().strip()
    arts = api(f"repos/{repo}/actions/artifacts?per_page=100", token)["artifacts"]
    art = next((a for a in arts if a["name"] == name and not a["expired"]), None)
    if not art:
        sys.exit(f"找不到 artifact {name}")
    url = art["archive_download_url"]
    head = sh(["curl", "-fsSIL", "-H", f"Authorization: token {token}", url]).decode()
    size = None
    for line in head.splitlines():
        if line.lower().startswith("content-length:"):
            size = int(line.split(":")[1].strip())
    if not size:
        sys.exit("拿不到 Content-Length")
    print(f"{name}: {size/1048576:.1f} MB (zip)")

    tail_n = min(size, 65536)
    tail = rng(url, token, size - tail_n, size - 1)
    i = tail.rfind(b"PK\x05\x06")
    cd_off = cd_size = None
    if i >= 0:
        _, _, _, _, _, cdsize, cdoff, _ = struct.unpack("<IHHHHIIH", tail[i:i + 22])
        cd_off, cd_size = cdoff, cdsize
        if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:      # zip64
            j = tail.rfind(b"PK\x06\x07")
            if j >= 0:
                e64 = struct.unpack("<Q", tail[j + 8:j + 16])[0]
                k = tail.find(b"PK\x06\x06")
                rec = tail[k:k + 56]
                cd_size, cd_off = struct.unpack("<QQ", rec[40:56])
    if cd_off is None:
        sys.exit("解析不到中央目录")

    cd = rng(url, token, cd_off, cd_off + cd_size - 1)
    entries, p = {}, 0
    while True:
        p = cd.find(b"PK\x01\x02", p)
        if p < 0:
            break
        nlen = struct.unpack("<H", cd[p + 28:p + 30])[0]
        xlen = struct.unpack("<H", cd[p + 30:p + 32])[0]
        clen = struct.unpack("<H", cd[p + 32:p + 34])[0]
        method = struct.unpack("<H", cd[p + 10:p + 12])[0]
        csize = struct.unpack("<I", cd[p + 20:p + 24])[0]
        usize = struct.unpack("<I", cd[p + 24:p + 28])[0]
        lho = struct.unpack("<I", cd[p + 42:p + 46])[0]
        name_b = cd[p + 46:p + 46 + nlen]
        entries[name_b.decode("utf-8", "replace")] = (method, csize, usize, lho)
        p += 46 + nlen + xlen + clen

    for w in want:
        if w == "manifest.json":
            hit = "manifest.json" if "manifest.json" in entries else None
        else:
            hit = next((k for k in entries if k.replace("\\", "/").endswith(w)), None)
        if not hit:
            print(f"  !! 没有 {w}")
            continue
        method, csize, usize, lho = entries[hit]
        hdr = rng(url, token, lho, lho + 29)
        hlen = struct.unpack("<H", hdr[26:28])[0]
        xlen = struct.unpack("<H", hdr[28:30])[0]
        start = lho + 30 + hlen + xlen
        data = rng(url, token, start, start + csize - 1)
        raw = zlib.decompress(data, -15) if method == 8 else data
        print(f"  ── {hit}  ({usize} B)")
        try:
            obj = json.loads(raw)
            keys = {k: obj[k] for k in ("commit", "branch", "source", "dirty", "payload",
                                        "updateMechanism", "distribution", "tag", "schemaVersion",
                                        "displayVersion", "baseVersion", "distance", "product",
                                        "platform", "arch", "node", "ref", "sha", "built_at") if k in obj}
            print("     ", json.dumps(keys, ensure_ascii=False))
        except Exception:
            print("     ", raw[:200])

main()
