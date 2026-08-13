#!/usr/bin/env bash
# Build the app, wrap it in a bundle, and launch it.
#
# A .app bundle rather than a bare executable, because AppKit refuses several things to a
# process with no bundle identity: proper activation, ⌘-shortcuts, appearance handling.
# The bundle is built by hand — four lines — so no Xcode is needed.
#
# The binary is exec'd directly rather than passed to `open`, because `open` launches
# through launchd and environment variables never arrive. The harness *is* those
# variables, so this distinction matters:
#
#   ./run.sh                          the real library
#   DUNES_WORKSPACE=/tmp/w ./run.sh      a different library
#   DUNES_STATE=loading ./run.sh         any harness state — see Harness in DunesApp
#   DUNES_TODAY=2026-08-10 ./run.sh      a pinned clock
#   DUNES_APPEARANCE=dark ./run.sh       force an appearance, this process only
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-debug}"
APP=".build/dunes.app"

swift build -c "$CONFIG" --product dunes-app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/dunes-app" "$APP/Contents/MacOS/dunes-app"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Unsigned bundles get killed on launch on Apple silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Kill a previous run so the loop is one command, not two.
pkill -x dunes-app 2>/dev/null || true
sleep 0.2

"$APP/Contents/MacOS/dunes-app" &
echo "running · pid $! · workspace=${DUNES_WORKSPACE:-default} · state=${DUNES_STATE:-live}"
