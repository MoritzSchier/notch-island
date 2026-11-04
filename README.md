# Notch Island

I wanted the iPhone's Dynamic Island on my Mac, so I built it. Notch Island turns the MacBook notch into a small live area that shows what's going on – music, calls, timers, messages – and opens into a little control center when you hover over it. On Macs without a notch it sits at the top center of the screen.

It also works nicely with Claude: you can follow what Claude is doing and answer its permission requests and questions right from the notch, without switching to the chat.

The app is available in English and German.

## What it does

- **Music and videos** – Spotify, Apple Music and YouTube in Chrome, with cover art and controls
- **Calls** – WhatsApp, FaceTime, Discord, Zoom, Teams and others, with call timer and mute
- **Notifications** – sender and the first lines of the message, stacked per app like on iPhone. By default only apps that matter show up (messengers, mail, Slack, Teams, calendar …); you can add others in settings
- **Claude** – live progress, "reply ready", permission requests and multiple-choice questions you can answer in the notch, plus your usage limit. Works with Claude Desktop and Claude Code. If you run several agents in parallel, the Claude tab shows all sessions at a glance – which one is working, which one is waiting for you – and a click takes you there
- **Shelf** – drag files onto the notch to keep them, share them, zip them, convert them (PDF, DOCX, JPEG, PNG, MP4, MP3 …) or make them smaller
- **Timers and stopwatch**, your **next event** with a join button, and due **reminders**
- **Color picker**, **audio device switching**, **battery details**, a camera **mirror**, **clipboard history** and a quick note

You can reorder and hide tabs, change what each tab shows, and turn on a permanent black notch for screens that don't have one.

## Install

1. Download `NotchIsland-x.y.z.zip` from [Releases](../../releases/latest) and unzip it.
2. Move **Notch Island** to your Applications folder.
3. The app isn't notarized by Apple, so the first time you open it, **right-click it and choose Open**. If macOS still refuses, go to System Settings › Privacy & Security and click "Open Anyway".
4. A short setup assistant walks you through the permissions.

Updates show up in the notch when a new version is released – one click installs it.

**Requirements:** macOS 14 (Sonoma) or later, Apple Silicon or Intel.

### Build it yourself

You need the Xcode Command Line Tools (`xcode-select --install`), not full Xcode.

```bash
git clone https://github.com/MoritzSchier/notch-island.git
cd notch-island
./build.sh
```

Or just double-click `Install.command`. The app ends up in `~/Applications`. To update later: `git pull && ./build.sh`.

## Permissions

The setup assistant asks for these one at a time. Only Accessibility is really needed; everything else is optional.

- **Accessibility** – Claude detection and answers, notification banners, media keys
- **Full Disk Access** (optional) – lets notifications come through even in Focus / Do Not Disturb. Only the notification list is read
- **Automation** – for Spotify, Music and Chrome, asked once per app
- **Calendar and Reminders** – for "up next"
- **Camera** – only for the mirror tab, only while it's open

For YouTube in Chrome, also enable *View › Developer › Allow JavaScript from Apple Events* in Chrome.

## Claude

- **Claude Desktop** is detected automatically once Accessibility is allowed.
- **Claude Code**: connect it in the setup assistant or under Settings › Claude. Then:
  - **One traffic light per session**: a dot per running Claude Code session next to the notch (grey ready, yellow working, red waiting for you, green done). Hover or click the dots to open the Claude tab, which lists every session in two columns with its status, current tool, running subagents and latest prompt. Clicking a session brings its terminal to the front.
  - **Permissions** from all sessions show up in the notch with the session name: Allow, Always allow (saves the rule Claude Code suggests, shown on the card), Deny or "In Terminal".
  - **Questions** (`AskUserQuestion`) can be answered in the notch: options, multiple choice, several questions in a row and a free-text answer.
  - The terminal waits while the notch asks. "In Terminal" hands a request back; if Notch Island isn't running, Claude Code asks in the terminal right away, and after 10 minutes without an answer it falls back to the terminal too.
- **Usage limit**: easiest without any login: let your Claude Code status line write the limits for the notch. Add this to your status line script (it receives Claude Code's JSON on stdin as `$input`):
  ```bash
  rl=$(echo "$input" | jq -c '.rate_limits // empty')
  [ -n "$rl" ] && printf '%s' "$rl" > ~/.claude/notch/usage.json
  ```
  Otherwise click "Sign in" in the Claude tab and log in to claude.ai once. The app never sees your password; it only reads your usage numbers from an unofficial endpoint, so this may break if Anthropic changes it.
- From your own scripts: `open "notchisland://claude?state=running&title=Build&progress=0.4"`

## Privacy

Everything stays on your Mac. There's no account, no server and no analytics. The app only goes online for website icons, YouTube thumbnails, update checks on this repo and, if you sign in, the Claude usage display. Clipboard history is kept in memory only.

## Troubleshooting

- **Nothing gets detected:** in System Settings › Privacy & Security › Accessibility, turn Notch Island off and on again.
- **Mission Control opens while dragging files:** check your Hot Corners in System Settings › Desktop & Dock.
- **Converting Office files** uses whatever you have installed (Word/PowerPoint or Pages/Keynote/Numbers). MP3 needs `lame` (`brew install lame`).
- **Build errors:** see `build.log`.

## Releasing a new version

1. Bump `VERSION` in `build.sh`.
2. Run `./build.sh --release` – this creates `dist/NotchIsland-<version>.zip` for Apple Silicon and Intel without installing anything.
   Use `./build.sh --dmg` instead to additionally get `dist/NotchIsland-<version>.dmg` (drag-to-Applications disk image).
3. Create a GitHub release with the tag `v<version>` and attach the zip (and the dmg).

## License

MIT – see [LICENSE](LICENSE). Not affiliated with Apple or Anthropic.
