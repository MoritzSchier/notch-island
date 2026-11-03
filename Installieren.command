#!/bin/bash
# Doppelklick: baut Notch Island und installiert es nach ~/Applications.
cd "$(dirname "$0")"
if ./build.sh; then
  echo ""
  echo "✓ Fertig. Notch Island läuft – zeige mit der Maus auf die Notch."
  echo "  Tipp: Erlaube in Systemeinstellungen › Datenschutz & Sicherheit › Bedienungshilfen „Notch Island“."
else
  echo ""
  echo "✗ Etwas hat nicht geklappt. Details stehen in build.log."
fi
echo "Du kannst dieses Fenster schließen."
