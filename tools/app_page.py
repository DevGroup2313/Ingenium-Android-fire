#!/usr/bin/env python3
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# The installed apps run models with their own native engine, so their copy of
# the page leaves out the baked WebAssembly engine (about 9 MB the app would
# only have to read past).   python3 tools/app_page.py ingenium.html <dest> [--build 2.1.20261002.7]
#
# --build stamps the build number into the copy (<meta name="ingenium-build">),
# so the app shows which build it is in About, on the welcome card and in the
# footer. The cloud builds pass it; a copy made without it shows the page's date.
import re
import sys

args = sys.argv[1:]
build = ""
if "--build" in args:
    i = args.index("--build")
    build = args[i + 1] if i + 1 < len(args) else ""
    del args[i:i + 2]
    if not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.\-]{0,39}", build):
        raise SystemExit("--build takes letters, digits, dots and dashes, for example 2.1.20261002.7")
src, dst = args[0], args[1]
html = open(src, encoding="utf-8").read()
out, n = re.subn(r'\n?<script id="ingenium-engine-(?:js|wasm|compat-worker|compat-wasm)"[^>]*>[\s\S]*?</script>', "", html)
# the kit store (Ingenium's builder) is for computers; the apps leave it out too
out, k = re.subn(r'\n?<script id="ingenium-kit-bundle"[^>]*>[\s\S]*?</script>', "", out)
out, stamped = re.subn(r'<meta name="ingenium-build" content="[^"]*">', '<meta name="ingenium-build" content="%s">' % build, out, count=1)
if build and not stamped:
    raise SystemExit("the page has no build-number tag to stamp; nothing was written")
if not out.rstrip().endswith("</html>"):
    raise SystemExit("the page did not survive the strip; nothing was written")
open(dst, "w", encoding="utf-8").write(out)
print("app page written to %s (%d engine parts%s left out, %.1f MB%s)" % (dst, n, " and the kit store" if k else "", len(out.encode("utf-8")) / 1e6,
      ", build " + build if build else ""))
