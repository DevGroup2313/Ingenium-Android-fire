#!/bin/bash
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Run by the cloud build after simulator_selftest.sh (which builds the app for
# the simulator): starts the app in iPhone and iPad simulators, lets the page
# show one view after another, and photographs each.
#   bash ingenium_ios_project/simulator_shots.sh <folder for the pictures>
# The cloud build keeps the pictures with the run (Actions, the run, Artifacts).
set -uo pipefail
cd "$(dirname "$0")"
OUT="${1:-shots}"
mkdir -p "$OUT"
APP=build/Build/Products/Release-iphonesimulator/Ingenium.app
[ -d "$APP" ] || { echo "::warning::no simulator build to photograph (simulator_selftest.sh builds it)"; exit 0; }
APP_ID="$(python3 -c "import json;print(json.load(open('../app.json')).get('app_id','com.yannieforest.ingenium'))" 2>/dev/null || echo com.yannieforest.ingenium)"

# runs a command, giving up after N seconds (macOS has no timeout command), so a
# simulator that never finishes booting cannot hold the build
within() {
  local n=$1; shift
  # the command runs in a process group of its own, so giving up stops its helpers too
  set -m
  "$@" & local p=$!
  set +m
  ( sleep "$n"; kill -TERM -- "-$p" 2>/dev/null || kill "$p" 2>/dev/null ) > /dev/null 2>&1 < /dev/null & local w=$!
  wait "$p"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# Which simulators: first the iPhone the self-test has already booted (ready at
# once), then an iPad of the same iOS version. A simulator that boots for the
# first time can take minutes (an iPhone 16 Pro took nine), so the iPad gets a
# time limit and is skipped if it runs out.
DEVICES="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
booted, runtime = None, None
for rt, items in data.items():
    if "iOS" not in rt:
        continue
    for d in items:
        if d.get("state") == "Booted" and d["name"].startswith("iPhone"):
            booted, runtime = d, rt
if runtime is None:
    for rt, items in data.items():
        if "iOS" in rt and any(d["name"].startswith("iPhone") for d in items):
            runtime = rt
items = [d for d in data.get(runtime, []) if d.get("isAvailable")]
def first(*wishes):
    for w in wishes:
        for d in items:
            if d["name"].startswith(w) and (booted is None or d["udid"] != booted["udid"]):
                return d
out = []
if booted:
    out.append(("iphone_ready", booted))
ipad = first("iPad Air 11-inch", "iPad (10th generation)", "iPad (A16)", "iPad Pro 11-inch", "iPad")
if ipad:
    out.append(("ipad", ipad))
for tag, d in out:
    print(tag + "|" + d["udid"] + "|" + d["name"])
')"
echo "$DEVICES"

# the list is read on its own channel, so no command in the loop can swallow it
while IFS='|' read -r tag udid name <&3; do
  [ -n "$udid" ] || continue
  echo "== $tag: $name ($udid), $(date -u +%T)"
  within 30 xcrun simctl boot "$udid" 2>/dev/null || true
  within 180 xcrun simctl bootstatus "$udid" -b > /dev/null || { echo "the $tag did not finish booting in time; skipped"; within 60 xcrun simctl shutdown "$udid"; continue; }
  within 30 xcrun simctl status_bar "$udid" override --time 9:41 2>/dev/null || true
  within 120 xcrun simctl install "$udid" "$APP" || { echo "the app did not install on the $tag"; within 60 xcrun simctl shutdown "$udid"; continue; }
  echo "booted and installed, $(date -u +%T)"
  LOG="$OUT/$tag.log"
  xcrun simctl launch --console-pty "$udid" "$APP_ID" -ingenium_shots > "$LOG" 2>&1 < /dev/null &
  L=$!
  seen=" "
  for i in $(seq 1 360); do
    for s in $(grep -o "INGENIUM_SHOT [a-z_]*" "$LOG" 2>/dev/null | awk '{print $2}'); do
      case "$seen" in *" $s "*) continue ;; esac
      seen="$seen$s "
      [ "$s" = done ] && continue
      if within 60 xcrun simctl io "$udid" screenshot "$OUT/${tag}_${s}.png" > /dev/null 2>&1; then
        # a smaller copy at once, so a time limit later never loses the pictures already taken
        sips -Z 1000 -s format jpeg -s formatOptions 72 "$OUT/${tag}_${s}.png" --out "$OUT/${tag}_${s}.jpg" > /dev/null 2>&1
        echo "photographed $tag $s"
      fi
    done
    case "$seen" in *" done "*) break ;; esac
    sleep 0.5
  done
  kill $L 2>/dev/null || true
  within 30 xcrun simctl terminate "$udid" "$APP_ID" 2>/dev/null || true
  within 60 xcrun simctl shutdown "$udid" 2>/dev/null || true
  echo "done with the $tag, $(date -u +%T)"
done 3<<< "$DEVICES"
ls -la "$OUT"
n=$(ls "$OUT"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "### Screenshots: $n pictures (Artifacts: ios-screens)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
exit 0
