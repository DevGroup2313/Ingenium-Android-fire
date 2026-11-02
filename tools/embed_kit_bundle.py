#!/usr/bin/env python3
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Packs everything Ingenium's builder needs into ingenium.html, so the app can
# make its build kits by itself, offline: the build files of this repository,
# the Mac and Windows apps' files, the kit definitions and the guides. Files
# are taken as committed (HEAD) in each repository, never from unsaved edits.
#
#   python3 tools/embed_kit_bundle.py --mac ../Ingenium-here --windows ../Ingenium-Windows [ingenium.html]
#
# The store is one compressed block:
#   <script id="ingenium-kit-bundle" type="ingenium/kit-bundle-gz" data-bytes="N">...</script>
# tools/app_page.py leaves it out of the phone and tablet apps' copy.
import argparse
import base64
import datetime
import gzip
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SLOT = "ingenium-kit-bundle"


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), check=True, capture_output=True).stdout


def committed_files(repo):
    """{path: mode} of every file committed at HEAD."""
    out = {}
    for line in git(repo, "ls-tree", "-r", "HEAD").decode("utf-8").splitlines():
        meta, path = line.split("\t", 1)
        mode, kind = meta.split()[0], meta.split()[1]
        if kind == "blob":
            out[path] = 0o755 if mode == "100755" else 0o644
    return out


def wanted(path, kits, source, shared, generated):
    if path == "ingenium.html" or path in generated:
        return False
    for kit in kits:
        if kit["source"] != source:
            continue
        if kit["paths"] is None:
            return True
        for p in kit["paths"] + (shared if kit.get("shared") else []):
            if path == p or (p.endswith("/") and path.startswith(p)):
                return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("page", nargs="?", default=os.path.join(ROOT, "ingenium.html"))
    ap.add_argument("--mac", required=True, help="the Mac app's repository (Ingenium-here)")
    ap.add_argument("--windows", required=True, help="the Windows app's repository (Ingenium-Windows)")
    a = ap.parse_args()

    kitdef = json.load(open(os.path.join(ROOT, "kits", "kits.json"), encoding="utf-8"))
    tested = json.load(open(os.path.join(ROOT, "kits", "tested.json"), encoding="utf-8"))
    guides = {}
    for kit in kitdef["kits"]:
        g = kit["guide"]
        guides[g] = open(os.path.join(ROOT, "kits", "guides", g), encoding="utf-8").read()

    sources = {"fire": ROOT, "mac": a.mac, "windows": a.windows}
    files, commits, total = [], {}, 0
    for source, repo in sources.items():
        commits[source] = git(repo, "rev-parse", "--short=7", "HEAD").decode().strip()
        for path, mode in sorted(committed_files(repo).items()):
            if not wanted(path, kitdef["kits"], source, kitdef["shared_mobile"], kitdef["generated"]):
                continue
            data = git(repo, "show", "HEAD:" + path)
            total += len(data)
            entry = {"s": source, "p": path, "m": mode}
            try:
                text = data.decode("utf-8")
                if "\x00" in text:
                    raise UnicodeDecodeError("utf-8", data, 0, 1, "binary")
                entry["t"] = text
            except UnicodeDecodeError:
                entry["b"] = base64.b64encode(data).decode("ascii")
            files.append(entry)

    made = datetime.date.today()
    bundle = {"v": 1, "made": "%d %s %d" % (made.day, made.strftime("%B"), made.year),
              "commits": commits, "kits": kitdef, "guides": guides, "tested": tested, "files": files}
    raw = json.dumps(bundle, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    gz = gzip.compress(raw, compresslevel=9, mtime=0)
    b64 = base64.b64encode(gz).decode("ascii")
    block = '<script id="%s" type="ingenium/kit-bundle-gz" data-bytes="%d">%s</script>' % (SLOT, len(raw), b64)

    page = open(a.page, encoding="utf-8").read()
    pat = re.compile(r'<script id="%s"[^>]*>[^<]*</script>' % SLOT)
    if pat.search(page):
        page, n = pat.subn(lambda m: block, page, count=1)
    else:
        m = re.search(r'<script id="ingenium-engine-compat-wasm"[^>]*>[^<]*</script>', page)
        if m:
            page = page[:m.end()] + "\n" + block + page[m.end():]
        else:
            m = re.search(r"<body[^>]*>", page)
            if not m:
                sys.exit("no <body> in %s" % a.page)
            page = page[:m.end()] + "\n" + block + page[m.end():]
    if not page.rstrip().endswith("</html>"):
        sys.exit("the page did not survive; nothing was written")
    tmp = a.page + ".tmp"
    open(tmp, "w", encoding="utf-8").write(page)
    os.replace(tmp, a.page)
    print("kit store embedded: %d files (%.0f KB), %.0f KB compressed, from %s"
          % (len(files), total / 1024, len(b64) / 1024,
             ", ".join("%s %s" % kv for kv in commits.items())))


if __name__ == "__main__":
    main()
