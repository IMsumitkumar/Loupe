#!/bin/bash
# Spec 10.3 leak test: run with the panel open for DURATION seconds, sample RSS each minute,
# assert growth under 5 MB between the settled baseline (after 2 min) and the end.
set -u
APP="$1"; DURATION="${2:-3600}"
LOUPE_OPEN_PANEL=1 open -n "$APP"; sleep 8
PID=$(pgrep -n -f "$APP/Contents/MacOS/Loupe"); [ -n "$PID" ] || { echo "app did not start"; exit 1; }
echo "pid $PID, sampling every 60 s for ${DURATION}s"
start=$(date +%s); base=""; last=""
while [ $(( $(date +%s) - start )) -lt "$DURATION" ]; do
  sleep 60
  rss=$(ps -o rss= -p "$PID" | tr -d ' '); [ -n "$rss" ] || { echo "app exited"; exit 1; }
  cpu=$(ps -o cputime= -p "$PID" | tr -d ' ')
  echo "$(( $(date +%s) - start ))s rss=$(( rss / 1024 )) MB cputime=${cpu} (open, whole app incl. Rust threads; Mole child separate)"
  [ $(( $(date +%s) - start )) -ge 120 ] && [ -z "$base" ] && base=$rss
  last=$rss
done
kill "$PID"
[ -n "$base" ] || base=$last
growth=$(( (last - base) / 1024 ))
echo "RSS growth after settling: ${growth} MB"
[ "$growth" -lt 5 ] && echo "leaktest: PASS" || { echo "leaktest: FAIL (>= 5 MB)"; exit 1; }
