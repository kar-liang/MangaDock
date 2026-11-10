#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把打好的 IPA 推到 NAS 的 updates 目录，并更新 latest-ios.json。

App 里的「设置 → 检查更新」就是读这份清单：
  1. GET  <主机>/Document/Mangadock/updates/latest-ios.json
  2. build 比本机大 → 显示说明 → 下载 IPA 到沙盒 → 拉起分享面板
签名安装不在 App 里做（没有开发者账号），交给 SideStore / AltStore / 自签。

**和 Android 共用同一个 updates 目录**，只是清单文件名不同
（`latest-android.json` / `latest-ios.json`）—— 两套包的版本号不是一个体系，
共用一份清单会互相判定成"有新版"，然后把对方的包装上去。

用法::

    DAV_BASE=https://<你的WebDAV地址> \
      python scripts/publish_update.py --ipa MangaDock-2.5.ipa --notes-file CHANGELOG.md

服务器地址（**不写进仓库**：这是公开仓库，不留自家入口）：
  1. 环境变量 DAV_BASE
  2. --base 参数
  两者都没给就拒绝运行。地址只存在本地环境/命令行里。

凭据来源（按优先级）：
  1. 环境变量 DAV_USER / DAV_PASS
  2. --creds 指定的文件（两行：用户名 / 密码）
  3. 环境变量 DAV_CREDS 指定的文件
  4. 本地 `_out/.dav-creds`（已 gitignore）
"""

import argparse
import base64
import datetime
import hashlib
import json
import os
import plistlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile


def _load_local_env():
    """读本地配置（绝不进仓库）：~/.mangadock-dav.env，每行 KEY=VALUE。

    优先级：已有的环境变量 > 这个文件。文件不存在就什么都不做。
    这样公开仓库里干净，本机发布时也不用每次手敲地址。
    """
    path = os.environ.get("DAV_ENV_FILE") or os.path.expanduser("~/.mangadock-dav.env")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_local_env()

# 服务器地址只从本地环境变量 / 命令行取，仓库里不留任何自家域名、IP 或端口。
DEFAULT_BASE = os.environ.get("DAV_BASE", "")
# 清单目录是 App 端约定的固定路径（不是主机地址），可用 DAV_DIR 覆盖。
DEFAULT_DIR = os.environ.get("DAV_DIR", "/Document/Mangadock/updates")
MANIFEST = "latest-ios.json"
# 凭据文件只在本地，不进仓库。保留原有默认位置，功能不降级；可用 DAV_CREDS 覆盖。
FALLBACK_CREDS = os.environ.get("DAV_CREDS") or os.path.expanduser(
    "~/WorkBuddy/2026-10-27-16-03-49/mangadock-android/_out/.dav-creds")


def die(msg):
    print("[X] " + msg)
    sys.exit(1)


def read_info(ipa):
    with zipfile.ZipFile(ipa) as zf:
        names = [n for n in zf.namelist() if n.endswith(".app/Info.plist")]
        if not names:
            die("IPA 里找不到 Info.plist，这不是一个合法的 .app 包")
        return plistlib.loads(zf.read(names[0]))


def creds(path):
    user, password = os.environ.get("DAV_USER"), os.environ.get("DAV_PASS")
    if user and password:
        return user, password
    for candidate in [path, FALLBACK_CREDS]:
        if candidate and os.path.exists(candidate):
            with open(candidate, encoding="utf-8") as fh:
                lines = [x.rstrip("\r\n") for x in fh.readlines()]
            if len(lines) >= 2 and lines[0].strip():
                return lines[0].strip(), lines[1].strip()
    die("没有 WebDAV 凭据：设 DAV_USER/DAV_PASS，或设 DAV_CREDS / 用 --creds 指定两行文件")


def request(method, url, user, password, data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method)
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", "Basic " + token)
    req.add_header("User-Agent", "MangaDock-publish/1.0")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read() or b""


def put(url, payload, user, password, content_type):
    status, _ = request("PUT", url, user, password, payload,
                        {"Content-Type": content_type})
    if status not in (200, 201, 204):
        die(f"PUT 失败：HTTP {status} {url}")
    return status


def remote_size(url, user, password):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:getcontentlength/><d:getcontenttype/>'
        '</d:prop></d:propfind>'
    ).encode()
    status, data = request("PROPFIND", url, user, password, body,
                           {"Depth": "0", "Content-Type": "application/xml"})
    if status not in (200, 207):
        return None
    match = re.search(rb"<[^>]*getcontentlength[^>]*>\s*(\d+)\s*<", data)
    return int(match.group(1)) if match else None


def release_notes(path):
    """取 CHANGELOG 最新一节的前 8 条，格式和 Android 那边一致。"""
    if not path or not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    out, started = [], False
    for line in lines:
        if line.startswith("## "):
            if started:
                break
            started = True
            continue
        if not started:
            continue
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("- "):
            out.append("· " + stripped[2:].strip())
        elif stripped.startswith("#"):
            continue
        else:
            out.append(stripped)
        if len(out) >= 8:
            break
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--notes-file", help="CHANGELOG.md，取最新一节当更新说明")
    ap.add_argument("--notes", help="直接给一段说明，优先于 --notes-file")
    ap.add_argument("--base", default=DEFAULT_BASE,
                    help="WebDAV 根地址；也可设 DAV_BASE 环境变量（二选一，必填）")
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--creds", help="两行文件：用户名 / 密码")
    args = ap.parse_args()

    if not args.base.strip():
        die("没配 WebDAV 地址：设 DAV_BASE 环境变量，或传 --base https://<你的WebDAV地址>")
    if not os.path.exists(args.ipa):
        die(f"找不到 IPA：{args.ipa}")

    info = read_info(args.ipa)
    version = info.get("CFBundleShortVersionString", "?")
    build = int(info.get("CFBundleVersion", "0"))
    if build <= 0:
        die("读不到 CFBundleVersion，拒绝发布")

    size = os.path.getsize(args.ipa)
    with open(args.ipa, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()

    file_name = f"MangaDock-{version}.ipa"
    notes = args.notes if args.notes else release_notes(args.notes_file)

    manifest = {
        "versionName": version,
        "build": build,
        "ipa": file_name,
        "sha256": digest,
        "size": size,
        "notes": notes,
        "releasedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    }

    user, password = creds(args.creds)
    base = args.base.rstrip("/")
    folder = "/" + args.dir.strip("/")

    print(f"[1/4] 包信息  {os.path.basename(args.ipa)}  build={build}  {version}  {size} B")
    print(f"      sha256 {digest}")

    ipa_url = base + urllib.parse.quote(folder + "/" + file_name)
    put(ipa_url, open(args.ipa, "rb").read(), user, password, "application/octet-stream")
    remote = remote_size(ipa_url, user, password)
    if remote != size:
        die(f"上传后大小不一致：远端 {remote} / 本地 {size}")
    print(f"[2/4] IPA 已上传  {folder}/{file_name}  远端 {remote} B")

    payload = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
    manifest_url = base + urllib.parse.quote(folder + "/" + MANIFEST)
    put(manifest_url, payload, user, password, "application/json")
    print(f"[3/4] 清单已上传  {folder}/{MANIFEST}")

    _, back = request("GET", manifest_url, user, password)
    parsed = json.loads(back.decode("utf-8"))
    if parsed.get("build") != build or parsed.get("sha256") != digest:
        die("回读校验不通过：远端清单和本地对不上")
    print(f"[4/4] 回读校验通过  远端 build={parsed.get('build')}")

    local = os.path.join(os.path.dirname(os.path.abspath(args.ipa)), MANIFEST)
    with open(local, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"\n完成：NAS 上的 iOS 版本现在是 {version} (build {build})")
    print("手机上「设置 → 检查更新」即可拉到。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
