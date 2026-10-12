#!/bin/bash
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Run by the cloud build inside an Android emulator: install the app, start it
# in a test mode, and wait for the page to report back.
#  * Ingenium itself (app.json "test": "model", with built-in models): the
#    page asks Velox a question and has Scriba think (R70: the test lives in
#    the page, ingSelfTest), which proves the whole chain: page, bridge,
#    native engine, both built-in models and the thinking bar's text.
#  * Any other app (a new app made with Ingenium's builder), or an app without
#    a built-in model: the page must load and report its title.
#   emulator_selftest.sh <app.apk> [<copy without the built-in model.apk>]
set -uo pipefail
APK="$1"
LITE="${2:-}"   # optional: the copy without the built-in model
cfg() { python3 -c "import json,sys;print(json.load(open('app.json')).get(sys.argv[1],sys.argv[2]))" "$1" "$2" 2>/dev/null || echo "$2"; }
APP_ID="$(cfg app_id com.yannieforest.ingenium)"
TEST="$(cfg test model)"
ACTIVITY="$APP_ID/com.yannieforest.ingenium.MainActivity"
# grep -c reads the whole listing: with pipefail, grep -q would end the pipe early
# and the listing's SIGPIPE would read as "no model"
if ! unzip -l "$APK" 2>/dev/null | grep -c "assets/models/builtin.json" > /dev/null; then
  TEST=page; LITE=""   # nothing to ask, and no lighter copy to compare
fi
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

adb wait-for-device
echo "Installing $(du -h "$APK" | cut -f1) app ($APP_ID, test: $TEST)..."
adb install -r "$APK" || { echo "::error::the app did not install on the emulator"; exit 1; }
adb logcat -c
if [ "$TEST" = "model" ]; then
  adb shell am start -n "$ACTIVITY" --ez ingenium_selftest true
  WANT="INGENIUM_SELFTEST DONE"
else
  adb shell am start -n "$ACTIVITY" --ez ingenium_pagetest true
  WANT="INGENIUM_SELFTEST PAGE"
fi
for i in $(seq 1 225); do
  if adb logcat -d -s IngeniumPage:I | grep -c "$WANT" > /dev/null; then break; fi
  sleep 4
done
adb logcat -d -s IngeniumPage:I Ingenium:I IngeniumEngine:W AndroidRuntime:E DEBUG:E > selftest.log 2>&1 || true
echo "---------------- what the app said ----------------"
grep -E "INGENIUM_SELFTEST|Ingenium|AndroidRuntime|FATAL|Error" selftest.log | tail -60
echo "---------------------------------------------------"

if [ "$TEST" = "page" ]; then
  line=$(grep "INGENIUM_SELFTEST PAGE" selftest.log | tail -1)
  if [ -z "$line" ] || ! adb shell pidof "$APP_ID" > /dev/null 2>&1; then
    echo "::error::the app's page did not load on the emulator (see the log above)"
    exit 1
  fi
  echo "### Android emulator test passed: the page loaded" >> "$SUMMARY"
  echo "\`${line#*INGENIUM_SELFTEST }\`" >> "$SUMMARY"
  if grep -q "Uncaught" selftest.log; then
    echo "::warning::the page reported script errors (see the log above); it loaded, so the app was still built"
  fi
  exit 0
fi

if grep -q "INGENIUM_SELFTEST REPLY" selftest.log; then
  line=$(grep "INGENIUM_SELFTEST REPLY" selftest.log | tail -1)
  echo "### Android emulator self-test passed" >> "$SUMMARY"
  echo "\`${line#*INGENIUM_SELFTEST }\`" >> "$SUMMARY"
  echo "$line" | grep -qi "paris" || echo "::warning::the built-in model answered, but not with Paris: $line"
  # R70: Scriba (the thinking model) must think: its thoughts fill the thinking bar
  think=$(grep "INGENIUM_SELFTEST THINK" selftest.log | tail -1)
  if echo "$think" | grep -c "THINK [1-9][0-9]* MODEL" > /dev/null; then
    echo "Scriba thought before answering, as the thinking bar shows: \`${think#*INGENIUM_SELFTEST }\`" >> "$SUMMARY"
  elif echo "$think" | grep -c "THINK none" > /dev/null; then
    echo "This app has no thinking model to test." >> "$SUMMARY"
  else
    echo "::error::the thinking model gave no thinking (${think:-no answer}); the thinking bar would stay empty"
    exit 1
  fi
  net=$(grep "INGENIUM_SELFTEST NET" selftest.log | tail -1)
  if echo "$net" | grep -c "NET 200 native" > /dev/null; then
    echo "The app reached the internet through its own connection (Wikipedia answered)." >> "$SUMMARY"
  else
    echo "::warning::the app's internet check did not pass: ${net:-no answer}"
  fi
  if [ -n "$LITE" ]; then
    # the copy without the built-in model must install over the full app
    # (same key, so the models added to it would stay) and open cleanly
    echo "Installing the copy without the built-in model over the full app..."
    adb install -r "$LITE" || { echo "::error::the copy without the built-in model did not install over the full app"; exit 1; }
    adb logcat -c
    adb shell am start -n "$ACTIVITY"
    sleep 25
    adb logcat -d -s IngeniumPage:E AndroidRuntime:E > lite.log 2>&1 || true
    if adb shell pidof "$APP_ID" > /dev/null 2>&1 && ! grep -q "FATAL EXCEPTION\|Uncaught" lite.log; then
      echo "Without the built-in model: installs over the full app and opens."
      echo "The copy without the built-in model installs over the full app and opens cleanly." >> "$SUMMARY"
    else
      tail -40 lite.log
      echo "::error::the copy without the built-in model did not open cleanly (see the log above)"
      exit 1
    fi
  fi
  exit 0
fi
echo "::error::the app did not answer on the emulator (see the log above)"
exit 1
