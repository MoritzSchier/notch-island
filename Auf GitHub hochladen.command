#!/bin/bash
# Lädt dieses Projekt in ein (leeres) GitHub-Repository hoch.
# Vorher auf github.com › New repository › Name "notch-island" › Public › OHNE README/Lizenz anlegen.
cd "$(dirname "$0")"
read -p "Dein GitHub-Benutzername: " GHUSER
[ -z "$GHUSER" ] && exit 1
URL="https://github.com/$GHUSER/notch-island.git"
git remote remove origin 2>/dev/null
git remote add origin "$URL"
echo "→ Lade hoch nach $URL …"
echo "  (Fragt Git nach einem Passwort: dort einen GitHub-Token einfügen – github.com › Settings › Developer settings › Personal access tokens)"
git push -u origin main && echo "✓ Fertig: https://github.com/$GHUSER/notch-island" || echo "✗ Hochladen fehlgeschlagen – siehe Meldung oben."
read -p "Enter zum Schließen"
