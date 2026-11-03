# Notch Island

**Die Dynamic Island für den Mac.** Notch Island macht die MacBook-Notch (oder die Mitte der Menüleiste bei Macs ohne Notch) zu einer lebendigen Insel – mit Live-Aktivitäten, Mitteilungen, einer Dropzone für Dateien und direkter Claude-Anbindung.

[English below](#english)

---

## Funktionen

| | |
|---|---|
| 🎵 **Musik & Videos** | Spotify, Apple Music, YouTube in Chrome – Cover, Titel, Fortschritt, Steuerung, Lautstärke, Klangwellen |
| 📞 **Anrufe** | WhatsApp, Discord, FaceTime/iPhone, Zoom, Teams, Slack, Telegram, Browser-Calls – mit Dauer und Stummschalten |
| 💬 **Mitteilungen** | wie am iPhone: Absender + erste Zeilen, gestapelt pro App – WhatsApp, Mail, Chrome, Nachrichten …; auch im Fokus-Modus |
| ✨ **Claude** | Live-Fortschritt mit Schritten, „Antwort bereit“, **Erlaubnis-Anfragen und Rückfragen direkt in der Insel beantworten**, Nutzungslimit |
| ⏱ **Timer & Stoppuhr** | mit Alarm, +1 Min, Stopp |
| 📂 **Ablage (Dropzone)** | Dateien auf die Notch ziehen → ablegen, teilen, AirDrop, ZIP, **konvertieren** (PDF, DOCX, JPEG, PNG, HEIC, MP4, MOV, MP3 …) und **verkleinern** |
| 📅 **Als Nächstes** | nächster Termin (mit Beitreten-Knopf) und fällige Erinnerungen |
| 🎨 **Farben** | Pipette mit Verlauf, HEX/RGB/HSL/SwiftUI per Klick kopieren |
| 🔊 **Audio** | Ein- und Ausgabegerät wechseln |
| 🔋 **System** | Akku (Watt, Zeit bis 80 %, Zustand, Zyklen), Bluetooth/AirPods, Downloads, Kamera/Mikrofon-Anzeige |
| 🌐 **Websites, Spiegel, Zwischenablage-Verlauf, Notiz** | |

Tabs lassen sich per Drag & Drop sortieren und in den Einstellungen › Tabs ein- und ausblenden; dort hat jeder Tab aufklappbare Optionen (z. B. Start-Karten, Alarm-Ton und Timer-Schnellwahl, Farbformate, Nutzungsanzeige). Mitteilungen lassen sich pro App stummschalten, mit oder ohne Textvorschau. Ein **Einrichtungsassistent** führt beim ersten Start durch alle Freigaben, und **Updates** werden automatisch angeboten (ein Klick lädt die neue Version von GitHub und startet neu). Die Insel klappt automatisch zu, sobald die Maus weg ist.

> Konvertieren von Office-Dateien nutzt das, was installiert ist: Word/PowerPoint oder Pages/Keynote/Numbers. MP3 braucht zusätzlich `lame` (`brew install lame`). Alles andere funktioniert ohne Zusatzprogramme.

## Voraussetzungen

- **macOS 14 (Sonoma) oder neuer**
- **Jeder Mac:** mit Notch (MacBook Pro/Air ab 2021) oder ohne (Insel sitzt dann oben in der Mitte) – Apple Silicon und Intel, auch mit externen Monitoren
- Zum Selberbauen: die **Xcode Command Line Tools** (`xcode-select --install`) – Xcode selbst ist nicht nötig

## Installieren

### Variante A – selbst bauen (empfohlen)

```bash
git clone https://github.com/<DEIN-NAME>/notch-island.git
cd notch-island
./build.sh
```

Oder im Finder einfach **`Installieren.command`** doppelklicken. Die App landet in `~/Applications/Notch Island.app` und startet automatisch (auch nach jeder Anmeldung – abschaltbar in den Einstellungen).

Aktualisieren: `git pull && ./build.sh` – deine Freigaben bleiben erhalten.

### Variante B – fertige App (Releases)

`NotchIsland-x.y.z.zip` aus den [Releases](../../releases) laden, entpacken, nach *Programme* ziehen.
Die App ist nicht von Apple beglaubigt. Beim ersten Start daher: **Rechtsklick › Öffnen › Öffnen** (oder einmal im Terminal `xattr -cr "/Applications/Notch Island.app"`).

## Berechtigungen

Beim ersten Start öffnet sich der **Einrichtungsassistent** und fragt alles Schritt für Schritt an (jederzeit wieder über das Menüleisten-Symbol › „Einrichtung …“). Notch Island fragt nur, was es für eine Funktion wirklich braucht:

| Freigabe | wofür |
|---|---|
| **Bedienungshilfen** (wichtigste) | Claude-Erkennung & -Antworten, Mitteilungs-Banner, Dock-Badges, Medientasten |
| Festplattenvollzugriff (optional) | Mitteilungen immer anzeigen – auch bei Fokus/„Nicht stören“ (liest nur die Mitteilungsliste) |
| Automation (Spotify, Musik, Chrome) | was gerade läuft + Steuerung – wird beim ersten Mal einzeln abgefragt |
| Kalender, Erinnerungen | nächster Termin, fällige Erinnerungen |
| Kamera | nur für den Spiegel-Tab, solange er offen ist |
| Bluetooth | AirPods & Co. verbunden |

Für **YouTube in Chrome**: Chrome › Darstellung › Entwickler › „JavaScript von Apple Events erlauben“.
Mitteilungen erscheinen nur, wenn die jeweilige App in *Systemeinstellungen › Mitteilungen* Banner zeigen darf.

## Claude

- **Claude Desktop** wird automatisch erkannt (Bedienungshilfen nötig): Fortschritt, „Claude ist fertig“, Erlaubnis-Anfragen und **Rückfragen mit Auswahl** („Welchen Weg möchtest du?“) erscheinen in der Insel – beantworten per Klick, auch wenn Claude im Vordergrund ist.
- **MCP-Werkzeuge** `notch_status`, `notch_toast`, `notch_timer`: `build.sh` trägt sie in Claude Desktop ein (Claude danach einmal neu starten). Claude kann damit Schritte und Fortschritt live melden.
- **Claude Code:** Einstellungen › „Claude-Code-Hooks kopieren“ und in `~/.claude/settings.json` einfügen.
- **Nutzungslimit:** im Claude-Tab auf „Anmelden“ klicken und sich einmal im kleinen Fenster bei claude.ai anmelden. Die App sieht dabei kein Passwort und speichert keine Zugangsdaten; sie liest nur die Nutzungswerte (inoffizielle Schnittstelle – kann sich ändern).
- Eigene Skripte: `open "notchisland://claude?state=running&title=Build&progress=0.4"` (state: running, waiting, done, error)

## Datenschutz

Alles läuft lokal auf deinem Mac. Es gibt keine Analyse, kein Konto, keinen Server. Netzwerkzugriffe nur für: Website-Symbole (Google-Favicon-Dienst), YouTube-Vorschaubilder und – falls du dich anmeldest – die Claude-Nutzungsanzeige. Der Zwischenablage-Verlauf liegt nur im Arbeitsspeicher.

## Probleme?

- **Insel reagiert nicht / nichts wird erkannt:** Systemeinstellungen › Datenschutz & Sicherheit › Bedienungshilfen › „Notch Island“ aus- und wieder einschalten.
- **Mission Control öffnet beim Ziehen:** Prüfe *Systemeinstellungen › Schreibtisch & Dock › Aktive Ecken*.
- **Baufehler:** Details stehen in `build.log`. Meist hilft `xcode-select --install`.

## Updates veröffentlichen

1. In `build.sh` die `VERSION` erhöhen (z. B. `1.1.0`).
2. `./build.sh --package` → erzeugt `dist/NotchIsland-1.1.0.zip` (Apple Silicon + Intel).
3. Auf GitHub › Releases › „Draft a new release“ › Tag `v1.1.0` › die ZIP anhängen › veröffentlichen.

Alle installierten Apps zeigen dann „Update verfügbar“. Die Update-Quelle wird beim Bauen automatisch aus dem Git-Remote (`origin`) übernommen; sonst in den Einstellungen › Update eintragen.

## Entwickeln

`Entwicklung.command` baut bei jeder Änderung automatisch neu (Auslöser: Datei `.rebuild`).
Optional `local.env` anlegen (wird nicht hochgeladen), z. B. `BUNDLE_ID=com.deinname.notchisland`.
`./build.sh --package` erzeugt eine Universal-App (Apple Silicon + Intel) als ZIP in `dist/`.

## Lizenz

MIT – siehe [LICENSE](LICENSE). Nicht mit Apple oder Anthropic verbunden.

---

<a name="english"></a>
# English

**Notch Island turns your Mac's notch into a Dynamic Island** – live activities, notifications, a file dropzone and Claude integration. On Macs without a notch it sits at the top center of the menu bar.

**Features:** media (Spotify, Music, YouTube in Chrome), calls (WhatsApp, Discord, FaceTime, Zoom, Teams …), notifications with sender and text, Claude progress + answering Claude's permission requests and multiple-choice questions right from the island, usage limits, timers, dropzone with conversion (PDF, DOCX, JPEG, PNG, HEIC, MP4, MOV, MP3 …) and compression, next event & reminders, color picker, audio device switching, battery details, Bluetooth, downloads, mirror, clipboard history, quick note. The UI is in German.

**Requirements:** macOS 14 Sonoma or later, any Mac (Apple Silicon or Intel, with or without notch, external displays supported). To build: Xcode Command Line Tools (`xcode-select --install`).

**Install:**
```bash
git clone https://github.com/<YOUR-NAME>/notch-island.git
cd notch-island && ./build.sh
```
Or double-click `Installieren.command`. The app is installed to `~/Applications` and launches at login (can be disabled). Prebuilt zips in Releases are not notarized: right-click › Open on first launch.

**Permissions:** Accessibility (notifications, Claude, dock badges, media keys), Automation for Spotify/Music/Chrome, Calendar, Reminders, Camera (mirror only), Bluetooth. For YouTube in Chrome enable *View › Developer › Allow JavaScript from Apple Events*.

**Privacy:** everything runs locally – no analytics, no account, no server. Network is only used for website favicons, YouTube thumbnails and (if you sign in) the Claude usage display, which reads an unofficial claude.ai endpoint and never sees your password.

**License:** MIT. Not affiliated with Apple or Anthropic.
