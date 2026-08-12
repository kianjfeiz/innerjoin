#!/usr/bin/env bash
# Render a state, photograph it, quit — with the app capturing its own window, so the
# harness needs no Screen Recording permission and the image is identical whatever else
# is on screen.
#
# Building UI without looking at it is guessing; one command per state means every state
# gets looked at, not just the happy one.
#
#   ./shot.sh                        the live library (point IJ_WORKSPACE at one)
#   ./shot.sh live loading failed    several states, one file each
#   IJ_APPEARANCE=dark ./shot.sh     the other theme, this process only
#
# Writes to .build/shots/<state>[-dark].png and prints the paths.
set -euo pipefail
cd "$(dirname "$0")"

STATES=("$@")
[ ${#STATES[@]} -eq 0 ] && STATES=("live")

OUT="$PWD/.build/shots"
mkdir -p "$OUT"

# Pinned so a shot taken today matches one taken next month.
export IJ_TODAY="${IJ_TODAY:-2026-08-12}"

CONFIG="${CONFIG:-debug}"
APP=".build/Innerjoin.app"

swift build -c "$CONFIG" --product Innerjoin
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/Innerjoin" "$APP/Contents/MacOS/Innerjoin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

SUFFIX=""
[ "${IJ_APPEARANCE:-}" = "dark" ] && SUFFIX="-dark"

for state in "${STATES[@]}"; do
  pkill -x Innerjoin 2>/dev/null || true
  sleep 0.3

  FILE="$OUT/${state}${SUFFIX}.png"
  rm -f "$FILE"
  IJ_STATE="$state" IJ_SHOT="$FILE" "$APP/Contents/MacOS/Innerjoin" &

  # The app writes the file and exits on its own; wait for the file, cap at 15s.
  for _ in $(seq 1 100); do
    [ -s "$FILE" ] && break
    sleep 0.15
  done

  if [ -s "$FILE" ]; then
    echo "$FILE"
  else
    echo "no shot for state '$state'" >&2
  fi
done

pkill -x Innerjoin 2>/dev/null || true
exit 0
