#!/bin/bash
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Run by the cloud build on a Mac: build the app for the iPhone simulator,
# start it in a test mode and wait for the page to report back. Ingenium itself
# (app.json "test": "model", with a built-in model) asks its built-in model a
# question; any other app, or one without a built-in model, must load its page.
set -uo pipefail
cd "$(dirname "$0")"
cfg() { python3 -c "import json,sys;print(json.load(open('../app.json')).get(sys.argv[1],sys.argv[2]))" "$1" "$2" 2>/dev/null || echo "$2"; }
APP_ID="$(cfg app_id com.yannieforest.ingenium)"
TEST="$(cfg test model)"
[ -f Ingenium/Models/builtin.json ] || TEST=page
echo "App: $APP_ID (test: $TEST)"
xcodebuild -project Ingenium.xcodeproj -scheme Ingenium -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build -quiet || exit 1
APP=build/Build/Products/Release-iphonesimulator/Ingenium.app
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devs.items():
    if "iOS" not in runtime:
        continue
    for d in items:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            best = d["udid"]
print(best or "")')
[ -n "$UDID" ] || { echo "::error::no iPhone simulator is available on this runner"; exit 1; }
echo "Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP" || { echo "::error::the app did not install in the simulator"; exit 1; }
# R70: the page's own test (ingSelfTest) asks Velox, has Scriba think, tries the
# internet, and ends with a DONE line
if [ "$TEST" = "model" ]; then ARG=-ingenium_selftest; WANT="INGENIUM_SELFTEST DONE"
else ARG=-ingenium_pagetest; WANT="INGENIUM_SELFTEST PAGE"; fi
xcrun simctl launch --console-pty "$UDID" "$APP_ID" "$ARG" > selftest.log 2>&1 &
LAUNCH=$!
for i in $(seq 1 240); do
  if grep -q "$WANT" selftest.log 2>/dev/null; then break; fi
  sleep 4
done
kill $LAUNCH 2>/dev/null || true
xcrun simctl terminate "$UDID" "$APP_ID" 2>/dev/null || true
echo "---------------- what the app said ----------------"
grep -v "^\s*$" selftest.log | tail -60
echo "---------------------------------------------------"
if [ "$TEST" = "page" ]; then
  line=$(grep "INGENIUM_SELFTEST PAGE" selftest.log | tail -1)
  [ -n "$line" ] || { echo "::error::the app's page did not load in the simulator (see the log above)"; exit 1; }
  echo "### iPhone simulator test passed: the page loaded" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "\`${line#*INGENIUM_SELFTEST }\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi
if grep -q "INGENIUM_SELFTEST REPLY" selftest.log; then
  line=$(grep "INGENIUM_SELFTEST REPLY" selftest.log | tail -1)
  echo "### iPhone simulator self-test passed" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "\`${line#*INGENIUM_SELFTEST }\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  echo "$line" | grep -qi "paris" || echo "::warning::the built-in model answered, but not with Paris: $line"
  # R70: Scriba (the thinking model) must think: its thoughts fill the thinking bar
  think=$(grep "INGENIUM_SELFTEST THINK" selftest.log | tail -1)
  if echo "$think" | grep -q "THINK [1-9][0-9]* MODEL"; then
    echo "Scriba thought before answering, as the thinking bar shows: \`${think#*INGENIUM_SELFTEST }\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  elif echo "$think" | grep -q "THINK none"; then
    echo "This app has no thinking model to test." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  else
    echo "::error::the thinking model gave no thinking (${think:-no answer}); the thinking bar would stay empty"
    exit 1
  fi
  net=$(grep "INGENIUM_SELFTEST NET" selftest.log | tail -1)
  if echo "$net" | grep -q "NET 200 native"; then
    echo "The app reached the internet through its own connection (Wikipedia answered)." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  else
    echo "::warning::the app's internet check did not pass: ${net:-no answer}"
  fi
  exit 0
fi
echo "::error::the app did not answer in the simulator (see the log above)"
exit 1
