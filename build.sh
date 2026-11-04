#!/bin/bash
# Notch Island bauen, installieren und starten.
#
#   ./build.sh               baut für diesen Mac, installiert nach ~/Applications und startet
#   ./build.sh --universal   baut für Apple Silicon UND Intel (eine App für alle Macs)
#   ./build.sh --package     wie --universal, legt zusätzlich dist/NotchIsland-<Version>.zip an
#   ./build.sh --release     nur die ZIP für GitHub bauen (installiert nichts)
#   ./build.sh --dmg         wie --release, legt zusätzlich dist/NotchIsland-<Version>.dmg an
#
# Optionale Einstellungen in einer Datei "local.env" (wird nicht mit hochgeladen), z. B.:
#   BUNDLE_ID=com.deinname.notchisland
#   INSTALL_DIR="/Applications"
set -uo pipefail
cd "$(dirname "$0")"

VERSION="1.1.0"
BUNDLE_ID="io.github.notchisland"
GITHUB_REPO=""          # z. B. "deinname/notch-island" – dort sucht die App nach Updates
INSTALL_DIR="$HOME/Applications"
[ -f local.env ] && source ./local.env   # darf auch UNIVERSAL=1 / PACKAGE=1 setzen
# Update-Quelle automatisch aus dem Git-Remote ableiten (github.com/<besitzer>/<repo>)
if [ -z "$GITHUB_REPO" ] && command -v git >/dev/null 2>&1; then
  ORIGIN="$(git remote get-url origin 2>/dev/null || true)"
  GITHUB_REPO="$(printf '%s' "$ORIGIN" | sed -nE 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#p')"
fi

UNIVERSAL="${UNIVERSAL:-0}"; PACKAGE="${PACKAGE:-0}"; RELEASE_ONLY="${RELEASE_ONLY:-0}"; DMG="${DMG:-0}"
[ "$PACKAGE" = 1 ] && UNIVERSAL=1
for a in "$@"; do
  case "$a" in
    --universal) UNIVERSAL=1 ;;
    --package) UNIVERSAL=1; PACKAGE=1 ;;
    --release) UNIVERSAL=1; PACKAGE=1; RELEASE_ONLY=1 ;;
    --dmg) UNIVERSAL=1; PACKAGE=1; RELEASE_ONLY=1; DMG=1 ;;
  esac
done

# Nur Entwicklung: Diagnose-Skript, falls vorhanden und neu
if [ -f .devbridge ] && [ -x ./diag.sh ] && { [ ! -f diag.log ] || [ diag.sh -nt diag.log ]; }; then ./diag.sh; exit 0; fi

LOG="$(pwd)/build.log"
say() { echo "$1"; echo "$1" >> "$LOG"; }
fail() { echo "✗ $1" >&2; echo "✗ $1" >> "$LOG"; echo "== ENDE (Fehler) ==" >> "$LOG"; exit 1; }
echo "== Baue Notch Island $VERSION ($(date '+%H:%M:%S')) ==" > "$LOG"

# Voraussetzungen
OSV="$(sw_vers -productVersion 2>/dev/null || echo 0)"
[ "${OSV%%.*}" -ge 14 ] 2>/dev/null || fail "Notch Island braucht macOS 14 (Sonoma) oder neuer – gefunden: $OSV"
command -v swift >/dev/null 2>&1 || fail "Swift fehlt. Bitte einmal im Terminal ausführen:  xcode-select --install"

NATIVE="$(uname -m)"
build_arch() {
  swift build -c release --arch "$1" >>"$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -30; fail "Bauen fehlgeschlagen (Details: build.log)"; }
  # Neuere Swift-Versionen legen alle Architekturen im selben Ordner ab –
  # daher die Binaries je Architektur sichern, bevor der nächste Build sie überschreibt.
  local SRC; SRC="$(swift build -c release --arch "$1" --show-bin-path)"
  local DST=".build/arch-$1"; mkdir -p "$DST"
  cp "$SRC/NotchIsland" "$SRC/notch-mcp" "$DST/" || fail "Binaries für $1 nicht gefunden"
  echo "$DST"
}

say "→ Baue für $([ $UNIVERSAL = 1 ] && echo 'Apple Silicon + Intel' || echo "$NATIVE") …"
if [ $UNIVERSAL = 1 ]; then
  ARM="$(build_arch arm64)" || exit 1; X86="$(build_arch x86_64)" || exit 1
  OUT=".build/universal"; mkdir -p "$OUT"
  for b in NotchIsland notch-mcp; do lipo -create "$ARM/$b" "$X86/$b" -output "$OUT/$b" || fail "lipo $b"; done
  BIN="$OUT"
else
  BIN="$(build_arch "$NATIVE")" || exit 1
fi

APP="$INSTALL_DIR/Notch Island.app"
mkdir -p "$INSTALL_DIR"
PLIST="$(sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__VERSION__/$VERSION/g" -e "s#__REPO__#$GITHUB_REPO#g" Resources/Info.plist)"
STAMP=".build/.installed"

# Unverändert? Dann nur neu starten – so bleiben Signatur und Freigaben gleich.
if [ $PACKAGE = 0 ] && [ -f "$APP/Contents/MacOS/NotchIsland" ] && cmp -s "$BIN/NotchIsland" "$STAMP" \
   && [ "$PLIST" = "$(cat "$APP/Contents/Info.plist" 2>/dev/null)" ]; then
  pkill -x NotchIsland 2>/dev/null || true; sleep 0.5
  open "$APP"; sleep 2
  pgrep -x NotchIsland >/dev/null && say "✓ Notch Island läuft (unverändert, nur neu gestartet)"
  echo "== FERTIG ==" >> "$LOG"; exit 0
fi

# App-Paket zusammenstellen und ad-hoc signieren:  make_app <Ziel.app> <Bundle-ID>
make_app() {
  local A="$1" ID="$2"
  rm -rf "$A"
  mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
  cp "$BIN/NotchIsland" "$BIN/notch-mcp" "$A/Contents/MacOS/"
  # Debug-Infos entfernen (enthalten sonst lokale Pfade wie /Users/<Name>/…)
  strip -S -x "$A/Contents/MacOS/NotchIsland" "$A/Contents/MacOS/notch-mcp" 2>>"$LOG" || true
  sed -e "s/__BUNDLE_ID__/$ID/g" -e "s/__VERSION__/$VERSION/g" -e "s#__REPO__#$GITHUB_REPO#g" Resources/Info.plist > "$A/Contents/Info.plist"
  iconutil -c icns Resources/AppIcon.iconset -o "$A/Contents/Resources/AppIcon.icns" >>"$LOG" 2>&1 || true
  xattr -cr "$A" 2>/dev/null || true
  # Feste Anforderung "identifier" → Freigaben (Bedienungshilfen usw.) bleiben nach Updates erhalten
  codesign --force --sign - --identifier "$ID.mcp" -r="designated => identifier \"$ID.mcp\"" "$A/Contents/MacOS/notch-mcp" >>"$LOG" 2>&1
  codesign --force --sign - --identifier "$ID" -r="designated => identifier \"$ID\"" "$A" >>"$LOG" 2>&1 || fail "Signieren fehlgeschlagen"
}

if [ $PACKAGE = 1 ]; then
  # Veröffentlichungs-Paket immer mit der neutralen Standard-ID (unabhängig von local.env)
  # Zusammenstellen in einem temporären Ordner: in iCloud-synchronisierten Ordnern (z. B. ~/Documents)
  # hängt macOS dem Bundle Finder-Attribute an, an denen codesign scheitert.
  mkdir -p dist
  PKG="$(mktemp -d)"
  make_app "$PKG/Notch Island.app" "io.github.notchisland"
  ZIP="dist/NotchIsland-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$PKG/Notch Island.app" "$ZIP" && say "✓ Paket: $ZIP"
  if [ "$DMG" = 1 ]; then
    # Disk-Image mit Verknüpfung zu /Applications – App einfach hinüberziehen
    DMGFILE="dist/NotchIsland-$VERSION.dmg"
    STAGE="$PKG/dmg"
    rm -f "$DMGFILE"; mkdir -p "$STAGE"
    ditto --norsrc --noextattr --noacl "$PKG/Notch Island.app" "$STAGE/Notch Island.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Notch Island" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMGFILE" >>"$LOG" 2>&1 \
      || fail "DMG erstellen fehlgeschlagen (Details: build.log)"
    say "✓ Disk-Image: $DMGFILE"
  fi
  rm -rf "$PKG"
  if [ "$RELEASE_ONLY" = 1 ]; then
    say "→ Jetzt auf GitHub › Releases › neues Release mit Tag v$VERSION anlegen und $ZIP$([ "$DMG" = 1 ] && echo " + $DMGFILE") anhängen."
    echo "== FERTIG ==" >> "$LOG"; exit 0
  fi
fi

pkill -x NotchIsland 2>/dev/null || true
sleep 0.3
make_app "$APP" "$BUNDLE_ID"
cp "$BIN/NotchIsland" "$STAMP"
say "✓ Installiert: $APP"

# Claude wird im Einrichtungsassistenten (erster Start) verbunden – nicht automatisch.

# Nur Entwicklung: Entwicklungs-Brücke einschalten (Datei .devbridge im Projektordner)
if [ -f .devbridge ]; then defaults write "$BUNDLE_ID" devBridgeDir "$(pwd)"; else defaults delete "$BUNDLE_ID" devBridgeDir 2>/dev/null || true; fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >>"$LOG" 2>&1
open "$APP"
sleep 3
if pgrep -x NotchIsland >/dev/null; then
  say "✓ Notch Island läuft (pid $(pgrep -x NotchIsland))"
else
  say "✗ Notch Island startet nicht"
  CR="$(ls -t "$HOME/Library/Logs/DiagnosticReports"/NotchIsland* 2>/dev/null | head -1)"
  [ -n "$CR" ] && cp "$CR" ./last-crash.ips && say "  Absturzbericht: $CR"
fi
echo "== FERTIG ==" >> "$LOG"
