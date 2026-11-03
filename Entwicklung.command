#!/bin/bash
# Entwicklungsmodus: baut bei jeder Änderung neu (Auslöser: Datei .rebuild anfassen, z. B. `touch .rebuild`).
cd "$(dirname "$0")"
touch .rebuild
LAST=""
echo "Notch Island – Entwicklungsmodus. Fenster offen lassen; 'touch .rebuild' baut neu."
while true; do
  CUR="$(stat -f %m .rebuild 2>/dev/null)"
  if [ "$CUR" != "$LAST" ]; then
    LAST="$CUR"
    echo "→ Baue ($(date '+%H:%M:%S')) …"
    ./build.sh && echo "✓ fertig" || echo "✗ Fehler (siehe build.log)"
  fi
  sleep 1
done
