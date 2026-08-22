#!/bin/bash
# Regenerates the screenshots in assets/.
#
#   make screenshots
#
# Posts each notification, captures the Notification Center window, crops it to
# the banner and writes a PNG. Needs Screen Recording permission for whichever
# terminal you run it from: System Settings > Privacy & Security > Screen
# Recording. Grant it, restart the terminal, and run this again.
#
# Action buttons and reply fields are only drawn when the notification style is
# Alerts, so this checks that first and tells you what to change.

set -u

cd "$(dirname "$0")/.."

APP="build/terminal-notifier.app"
BIN="$APP/Contents/MacOS/terminal-notifier"
GRAB="build/grab"
OUT="assets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else G=; R=; Y=; B=; Z=; fi

fail() { printf "${R}%s${Z}\n" "$1" >&2; exit 1; }

[ -x "$BIN" ] || fail "no $BIN — run: make app"

# The capture helper.
clang -fobjc-arc -O2 -framework Foundation -framework CoreGraphics \
      -framework ImageIO -o "$GRAB" tools/grab.m || fail "could not build tools/grab.m"

# --- preflight ---------------------------------------------------------------
diag="$("$BIN" -diagnose 2>/dev/null)"
case "$diag" in
  *"authorization       authorized"*|*"authorization       provisional"*) ;;
  *) fail "notifications are not authorized — run: $BIN -diagnose" ;;
esac

ALERTS=0
case "$diag" in *"alert style         alerts"*) ALERTS=1 ;; esac
if [ "$ALERTS" = 0 ]; then
  printf "${Y}Note:${Z} notification style is Banners, so action buttons and reply\n"
  printf "      fields will not be drawn. To capture those too, set\n"
  printf "      System Settings > Notifications > terminal-notifier > Alerts,\n"
  printf "      then run this again.\n\n"
fi

# Screen Recording permission, checked once and clearly.
"$BIN" -message 'checking screen recording permission' -group shotcheck >/dev/null 2>&1
sleep 2
wid="$("$GRAB" --window-id 2>/dev/null)"
if [ -n "$wid" ] && ! screencapture -x -o -l "$wid" "$TMP/permcheck.png" 2>/dev/null; then
  "$BIN" -remove shotcheck >/dev/null 2>&1
  fail "screencapture cannot read the display.
Give this terminal Screen Recording permission in
System Settings > Privacy & Security > Screen Recording,
then restart the terminal and run this again."
fi
"$BIN" -remove shotcheck >/dev/null 2>&1
sleep 1

# --- capture -----------------------------------------------------------------
TAKEN=0
SKIPPED=0

# shot <output name> <description> -- <terminal-notifier args...>
shot() {
  local name="$1" desc="$2"; shift 3   # drop the literal --
  printf "  %-22s %s\n" "$name" "$desc"

  "$BIN" -remove ALL >/dev/null 2>&1
  sleep 1
  "$BIN" "$@" >/dev/null 2>&1 &
  local poster=$!
  sleep 2

  local id
  id="$("$GRAB" --window-id 2>/dev/null)"
  if [ -z "$id" ]; then
    printf "        ${Y}skipped${Z} — no notification on screen\n"
    SKIPPED=$((SKIPPED + 1))
    kill "$poster" 2>/dev/null; wait "$poster" 2>/dev/null
    return
  fi

  if ! screencapture -x -o -l "$id" "$TMP/$name.raw.png" 2>/dev/null; then
    printf "        ${R}failed${Z} — screencapture refused\n"
    SKIPPED=$((SKIPPED + 1))
    kill "$poster" 2>/dev/null; wait "$poster" 2>/dev/null
    return
  fi

  if "$GRAB" --crop "$TMP/$name.raw.png" "$OUT/$name.png"; then
    TAKEN=$((TAKEN + 1))
  else
    SKIPPED=$((SKIPPED + 1))
  fi

  kill "$poster" 2>/dev/null; wait "$poster" 2>/dev/null
  "$BIN" -remove ALL >/dev/null 2>&1
}

printf "${B}Capturing${Z}\n"

shot message      "-message on its own" -- \
  -message 'Finished in 42s'

shot title        "-title and -message" -- \
  -title 'Build' -message 'Finished in 42s'

shot subtitle     "-title, -subtitle and -message" -- \
  -title 'ProjectX' -subtitle 'new tag detected' -message 'v3.0.0 is ready'

# A small image to attach, built from a system icon so the repo carries nothing.
sips -s format png --resampleHeightWidth 256 256 \
  /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
  --out "$TMP/attach.png" >/dev/null 2>&1
shot contentImage "-contentImage attachment" -- \
  -title 'Report' -subtitle 'weekly summary' -message 'Chart attached' \
  -contentImage "$TMP/attach.png"

if [ "$ALERTS" = 1 ]; then
  shot action "-action buttons" -- \
    -title 'Deploy' -message 'Deploy to production?' -action 'Yes,No' -timeout 20
  shot reply  "-reply text field" -- \
    -title 'Standup' -message "What did you do yesterday?" -reply 'type your answer' -timeout 20
else
  printf "  %-22s ${Y}skipped${Z} — needs the Alerts style\n" "action"
  printf "  %-22s ${Y}skipped${Z} — needs the Alerts style\n" "reply"
  SKIPPED=$((SKIPPED + 2))
fi

# Its own source image: the attachment one may have been consumed by the
# notification store, and in any case the two are unrelated.
sips -s format png --resampleHeightWidth 512 512 \
  /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
  --out "$TMP/icon-source.png" >/dev/null 2>&1

# The custom icon shot needs its own bundle, which is the whole point of it.
printf "\n${B}Custom icon${Z}\n"
if make icon ICON="$TMP/icon-source.png" APP_NAME=custom-icon >"$TMP/icon.log" 2>&1; then
  ICON_BIN="build/custom-icon.app/Contents/MacOS/terminal-notifier"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "build/custom-icon.app" 2>/dev/null
  sleep 1
  "$ICON_BIN" -title 'custom-icon' -message 'Built with make icon' >/dev/null 2>&1 &
  poster=$!
  sleep 2
  id="$("$GRAB" --window-id 2>/dev/null)"
  if [ -n "$id" ] && screencapture -x -o -l "$id" "$TMP/icon.raw.png" 2>/dev/null \
     && "$GRAB" --crop "$TMP/icon.raw.png" "$OUT/custom-icon.png"; then
    TAKEN=$((TAKEN + 1))
  else
    printf "  %-22s ${Y}skipped${Z} — the copy needs its own notification permission\n" "custom-icon"
    printf "                         run it once by hand, allow the prompt, then retry\n"
    SKIPPED=$((SKIPPED + 1))
  fi
  kill "$poster" 2>/dev/null; wait "$poster" 2>/dev/null
  "$ICON_BIN" -remove ALL >/dev/null 2>&1
else
  printf "  %-22s ${Y}skipped${Z} — make icon failed\n" "custom-icon"
  sed "s/^/      /" "$TMP/icon.log" >&2
  SKIPPED=$((SKIPPED + 1))
fi

"$BIN" -remove ALL >/dev/null 2>&1

printf "\n${B}Done${Z}\n"
printf "  ${G}%d captured${Z}" "$TAKEN"
[ "$SKIPPED" -gt 0 ] && printf ", ${Y}%d skipped${Z}" "$SKIPPED"
printf "\n"
[ "$TAKEN" -gt 0 ] && printf "  written to %s/\n" "$OUT"
exit 0
