#!/usr/bin/env python3
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Puts the built-in models for one platform into an app's model folder:
#   python3 tools/prepare_builtin_model.py android ingenium_android_project/app/src/main/assets/models
#   python3 tools/prepare_builtin_model.py ios     ingenium_ios_project/Ingenium/Models
#
# Each model is downloaded from Hugging Face once (kept in a cache folder, by
# default ~/.cache/ingenium-models) and is refused unless its SHA-256 matches
# mobile_models.json. Beside them go builtin.json (what the app reads: R70
# lists every model) and each model's licence.
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest, size):
    tmp = dest + ".part"
    for attempt in range(1, 5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Ingenium-build"})
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as out:
                got, last = 0, 0.0
                while True:
                    chunk = r.read(1 << 22)
                    if not chunk:
                        break
                    out.write(chunk)
                    got += len(chunk)
                    if time.time() - last > 10:
                        last = time.time()
                        print("  %.0f of %.0f MB" % (got / 1e6, size / 1e6), flush=True)
            os.replace(tmp, dest)
            return
        except Exception as e:  # network trouble: wait and try again
            print("  download attempt %d failed: %s" % (attempt, e), flush=True)
            time.sleep(5 * attempt)
    raise SystemExit("could not download %s" % url)


def models_for(platform):
    """The platform's built-in models: a list (R70), or one model (before R70), or none."""
    cfg = json.load(open(os.path.join(ROOT, "mobile_models.json"))).get(platform)
    if not cfg:
        return []
    return cfg if isinstance(cfg, list) else [cfg]


def main():
    platform, out_dir = sys.argv[1], sys.argv[2]
    models = models_for(platform)
    os.makedirs(out_dir, exist_ok=True)
    keep = set()
    for m in models:
        keep.update((m["file"], m["licence"]))
    for name in os.listdir(out_dir):   # only this build's models stay (hidden files too)
        path = os.path.join(out_dir, name)
        if not name.startswith(".") and os.path.isfile(path) and name not in keep:
            os.remove(path)
    if not models:
        print("No built-in model for %s: the app is built without one." % platform, flush=True)
        return
    total = sum(m["size"] for m in models)
    if total > 2_000_000_000 * 1.06:
        raise SystemExit("the built-in models come to %.2f GB; one release file may hold at most 2 GB" % (total / 1e9))
    cache = os.environ.get("INGENIUM_MODEL_CACHE", os.path.expanduser("~/.cache/ingenium-models"))
    os.makedirs(cache, exist_ok=True)
    listed = []
    for cfg in models:
        cached = os.path.join(cache, cfg["file"])
        if not (os.path.isfile(cached) and os.path.getsize(cached) == cfg["size"] and sha256_of(cached) == cfg["sha256"]):
            print("Downloading a built-in model for %s: %s (%.0f MB)" % (platform, cfg["name"], cfg["size"] / 1e6), flush=True)
            download(cfg["url"], cached, cfg["size"])
            got = sha256_of(cached)
            if got != cfg["sha256"]:
                os.remove(cached)
                raise SystemExit("the downloaded model %s does not match its checksum (got %s); refusing it" % (cfg["file"], got))
        print("Built-in model verified: %s" % cfg["file"], flush=True)
        dest = os.path.join(out_dir, cfg["file"])
        if not (os.path.isfile(dest) and os.path.getsize(dest) == cfg["size"]):
            shutil.copyfile(cached, dest)
        shutil.copyfile(os.path.join(ROOT, "licences", cfg["licence"]), os.path.join(out_dir, cfg["licence"]))
        listed.append({"file": cfg["file"], "name": cfg["name"], "size": cfg["size"], "licence": cfg["licence"],
                       "sha256": cfg["sha256"], "source": cfg["url"], "lineup": cfg.get("lineup", "")})
    with open(os.path.join(out_dir, "builtin.json"), "w", encoding="utf-8") as fh:
        json.dump({"models": listed}, fh, indent=1)
    print("Ready in %s: %s" % (out_dir, ", ".join(m["name"] for m in listed)), flush=True)


if __name__ == "__main__":
    main()
