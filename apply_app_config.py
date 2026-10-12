#!/usr/bin/env python3
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Writes who the app is (app.json) into the iPhone and iPad project before
# Xcode builds it: the app's id (bundle identifier, in project.yml) and the
# name shown under its icon (Info.plist). The Android build reads app.json by
# itself (app/build.gradle).        python3 tools/apply_app_config.py
#
# With INGENIUM_BUILD set (the cloud build sets it, for example 2.1.20261002.7)
# it also writes the version (2.1) and the build number (20261002.7) that iOS
# shows for the app.
import json
import os
import re
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    cfg = json.load(open(os.path.join(ROOT, "app.json"), encoding="utf-8"))
    app_id = str(cfg.get("app_id", "com.yannieforest.ingenium"))
    name = re.sub(r"\s+", " ", re.sub(r"[^A-Za-z0-9 ._-]", "", str(cfg.get("name", "Ingenium")))).strip() or "Ingenium"
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+", app_id):
        sys.exit("app.json: app_id '%s' must look like com.example.myapp (letters and digits, dots between)" % app_id)

    yml = os.path.join(ROOT, "ingenium_ios_project", "project.yml")
    text = open(yml, encoding="utf-8").read()
    text, n = re.subn(r"(?m)^(\s*PRODUCT_BUNDLE_IDENTIFIER:\s*).*$", lambda m: m.group(1) + app_id, text)
    if n != 1:
        sys.exit("project.yml: expected one PRODUCT_BUNDLE_IDENTIFIER line, found %d" % n)
    build = os.environ.get("INGENIUM_BUILD", "").strip()
    m = re.fullmatch(r"(\d+\.\d+)\.(\d+(?:\.\d+)?)", build)
    if build and not m:
        sys.exit("INGENIUM_BUILD '%s' must look like 2.1.20261002.7" % build)
    if m:
        for key, value in (("MARKETING_VERSION", m.group(1)), ("CURRENT_PROJECT_VERSION", m.group(2))):
            text, n = re.subn(r'(?m)^(\s*%s:\s*).*$' % key, lambda mm: mm.group(1) + '"%s"' % value, text)
            if n != 1:
                sys.exit("project.yml: expected one %s line, found %d" % (key, n))
    open(yml, "w", encoding="utf-8").write(text)

    plist = os.path.join(ROOT, "ingenium_ios_project", "Ingenium", "Info.plist")
    text = open(plist, encoding="utf-8").read()
    text, n = re.subn(r"(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)",
                      lambda m: m.group(1) + escape(name) + m.group(2), text)
    if n != 1:
        sys.exit("Info.plist: expected one CFBundleDisplayName, found %d" % n)
    open(plist, "w", encoding="utf-8").write(text)
    print("The iPhone and iPad app is %s (%s)%s." % (name, app_id, (", version %s, build %s" % (m.group(1), m.group(2))) if m else ""))


if __name__ == "__main__":
    main()
