#!/usr/bin/env python3
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# The installed apps run models with their own native engine, so their copy of
# the page leaves out the baked WebAssembly engine (about 9 MB the app would
# only have to read past).   python3 tools/app_page.py ingenium.html <dest> [--build 2.1.20261002.7]
#
# What the page carries for later at its end (Ingenium 6.8.1: the apps of its library,
# the picture reader, the typefaces of its documents) is written beside the copy as
# carried-<id>.txt, and the copy names where each is: the app serves them at its own
# address, and the page fetches each the first time it is used. So the app's web view
# reads about 13 MB when it starts, not about 62 MB.
#
# --build stamps the build number into the copy (<meta name="ingenium-build">),
# so the app shows which build it is in About, on the welcome card and in the
# footer. The cloud builds pass it; a copy made without it shows the page's date.
import os
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
# the engine's blocks wherever they are, at the end of the page too (Ingenium 6.8.1 carries its larger blocks there)
out, n = re.subn(r'\n?<script id="(?:ing-tail:)?ingenium-engine-(?:js|wasm|compat-worker|compat-wasm)"[^>]*>[\s\S]*?</script>', "", html)
# the kit store (Ingenium's builder) is for computers; the apps leave it out too
out, k = re.subn(r'\n?<script id="(?:ing-tail:)?ingenium-kit-bundle"[^>]*>[\s\S]*?</script>', "", out)
carried = []
for m in reversed(list(re.finditer(r'<script id="ing-tail:([^"]+)"[^>]*>([^<]*)</script>\n?', out))):
    out = out[:m.start()] + out[m.end():]
    carried.append((m.group(1), m.group(2)))
for ident, body in carried:
    name = "carried-%s.txt" % ident
    out, c = re.subn(r'data-defer="#ing-tail:%s"' % re.escape(ident), 'data-defer="%s"' % name, out, count=1)
    if c != 1:
        raise SystemExit("%s has no place in the page; nothing was written" % ident)
    open(os.path.join(os.path.dirname(os.path.abspath(dst)), name), "w", encoding="utf-8").write(body)
out, stamped = re.subn(r'<meta name="ingenium-build" content="[^"]*">', '<meta name="ingenium-build" content="%s">' % build, out, count=1)
if build and not stamped:
    raise SystemExit("the page has no build-number tag to stamp; nothing was written")
if not out.rstrip().endswith("</html>"):
    raise SystemExit("the page did not survive the strip; nothing was written")
open(dst, "w", encoding="utf-8").write(out)
print("app page written to %s (%d engine parts%s left out, %.1f MB%s)" % (dst, n, " and the kit store" if k else "", len(out.encode("utf-8")) / 1e6,
      ", build " + build if build else ""))
if carried:
    print("beside it: %s (%.1f MB)" % (", ".join("carried-%s.txt" % i for i, _ in sorted(carried)), sum(len(b) for _, b in carried) / 1e6))
