#!/bin/bash
# INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
# NO LICENCE IS GRANTED. See LICENCE.txt.
#
# Puts finished apps on the repository's Releases page, under the one release
# "<app name> (latest build)", replacing the older copies of the same files.
#   tools/publish_release.sh <file> <name on the Releases page> [<file> <name> ...]
# The app's name comes from APP_NAME (the workflows read it from app.json).
set -euo pipefail
if [ $# -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
  echo "usage: publish_release.sh <file> <name> [<file> <name> ...]" >&2
  exit 2
fi
TAG="latest"
APP="${APP_NAME:-Ingenium}"
TITLE="$APP (latest build)"
NOTES_FILE="$RUNNER_TEMP/notes.md"
# 6.8: every branch publishes to this one release, so a build never replaces a newer one of the same platform: an older
# branch's build (its version is lower) is kept with its own run only. (The Forge's Fire APK was replaced so, 25 October 2026.)
HAVE="$(gh release view "$TAG" --json body --jq .body 2>/dev/null | grep -F "(${INGENIUM_PLATFORM:-?})" | sed -n 's/^\* Build \*\*\([^*]*\)\*\*.*/\1/p' | head -n 1 || true)"
if [ -n "$HAVE" ] && [ -n "${INGENIUM_BUILD:-}" ] && [ "$HAVE" != "${INGENIUM_BUILD:-}" ] && [ "$(printf '%s\n%s\n' "$HAVE" "${INGENIUM_BUILD:-}" | sort -V | tail -n 1)" = "$HAVE" ]; then
  echo "::warning::The Releases page already has build $HAVE for ${INGENIUM_PLATFORM:-this platform}, newer than this build (${INGENIUM_BUILD:-}). It stays there; this build is kept with its run only."
  exit 0
fi

# move the tag to this build, then make sure the release exists
git tag -f "$TAG" "$GITHUB_SHA"
if ! git push -f origin "refs/tags/$TAG"; then
  echo "(the tag could not be moved, so the release stays where it is; the files are still replaced)"
  git tag -d "$TAG" > /dev/null 2>&1 || true
fi
if ! gh release view "$TAG" > /dev/null 2>&1; then
  gh release create "$TAG" --title "$TITLE" --notes "Building..." --latest \
    || { git fetch -q origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true; gh release view "$TAG" > /dev/null 2>&1; } \
    || { echo "::error::the release '$TAG' could not be made"; exit 1; }
fi
echo "### Published to Releases" >> "$GITHUB_STEP_SUMMARY"
THIS_RUN=""
while [ $# -gt 0 ]; do
  FILE="$1"; NAME="$2"; shift 2
  cp "$FILE" "$RUNNER_TEMP/$NAME"
  ok=0
  for i in 1 2 3 4; do
    if gh release upload "$TAG" "$RUNNER_TEMP/$NAME" --clobber; then ok=1; break; fi
    echo "upload attempt $i failed; trying again"; sleep $((i * 20))
  done
  [ "$ok" = 1 ] || { echo "::error::$NAME could not be uploaded"; exit 1; }
  THIS_RUN="$THIS_RUN$NAME"$'\n'
  URL="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/${NAME}"
  echo "Published: $URL"
  echo "* [$NAME]($URL)" >> "$GITHUB_STEP_SUMMARY"
done

# each workflow's build number (INGENIUM_BUILD, INGENIUM_PLATFORM), kept for the other workflow too
PREV="$(gh release view "$TAG" --json body --jq .body 2>/dev/null || true)"
BUILDS="$(printf '%s\n' "$PREV" | grep '^\* Build ' | grep -v -F "(${INGENIUM_PLATFORM:-?})" || true)"
if [ -n "${INGENIUM_BUILD:-}" ]; then
  BUILDS="$(printf '%s\n%s\n' "$BUILDS" "* Build **${INGENIUM_BUILD}** (${INGENIUM_PLATFORM:-?}), from \`${GITHUB_SHA:0:7}\`" | sed '/^$/d' | sort)"
fi
# the description lists every file the release now holds (this build's and the other workflow's)
ALL="$( (gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null || true; printf '%s' "$THIS_RUN") | sed '/^$/d' | sort -u)"
{
  echo "$APP, built from \`${GITHUB_SHA:0:7}\` on branch \`${GITHUB_REF_NAME}\`."
  echo
  if [ -n "$BUILDS" ]; then
    echo "The build number each app shows in About:"
    echo
    printf '%s\n' "$BUILDS"
    echo
  fi
  echo "| File | For | How to install |"
  echo "| --- | --- | --- |"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in
      *-Android-Fire-no-model.apk) echo "| $n | The same Android app without the built-in model | Optional. Install it over the full app to free the built-in model's space; the models you added stay. |" ;;
      *-Android-Fire.apk) echo "| **$n** | Fire tablets and Android phones and tablets | Open it on the tablet and tap Install (allow \"Apps from Unknown Sources\" once). |" ;;
      *-iPhone-iPad-no-model-unsigned.ipa) echo "| $n | The same iPhone and iPad app without the built-in model | Optional. Install it with the same tool and Apple ID, over the full app. |" ;;
      *-iPhone-iPad-unsigned.ipa) echo "| **$n** | iPhone and iPad | Install from a computer with Sideloadly or AltStore, signing in with your Apple ID. |" ;;
      *) echo "| $n | | |" ;;
    esac
  done <<< "$ALL"
  echo
  echo "Each app works with no connection. The full steps are in INSTALL_MOBILE.md in the repository."
} > "$NOTES_FILE"
gh release edit "$TAG" --title "$TITLE" --notes-file "$NOTES_FILE" --latest
