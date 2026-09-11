#!/bin/bash
# Spec 10.3 child-process test: open the panel so Mole streams, quit the app, assert no orphan.
set -u
APP="$1"
before=$(pgrep -f "libexec/bin/status-go" | sort)
LOUPE_OPEN_PANEL=1 open -n "$APP"; sleep 10
PID=$(pgrep -n -f "$APP/Contents/MacOS/Loupe"); [ -n "$PID" ] || { echo "app did not start"; exit 1; }
children=$(pgrep -P "$PID" -f status-go || true)
echo "app pid $PID, mole child: ${children:-none}"
[ -n "$children" ] || { echo "childtest: FAIL (Mole child never started while panel open)"; kill "$PID"; exit 1; }
osascript -e 'tell application "Loupe" to quit' 2>/dev/null || kill "$PID"
sleep 4
after=$(pgrep -f "libexec/bin/status-go" | sort)
orphans=$(comm -13 <(echo "$before") <(echo "$after"))
pgrep -q -x Loupe && { echo "childtest: FAIL (app still running)"; exit 1; }
[ -z "$orphans" ] && echo "childtest: PASS (no orphaned status-go)" || { echo "childtest: FAIL orphans: $orphans"; exit 1; }
