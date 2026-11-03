import SwiftUI
import AppKit
import ServiceManagement
import EventKit

struct SettingsView: View {
    @AppStorage(Prefs.hoverToOpen) private var hoverToOpen = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.showMedia) private var showMedia = true
    @AppStorage(Prefs.showVolumeHUD) private var showVolumeHUD = true
    @AppStorage(Prefs.showBrightnessHUD) private var showBrightnessHUD = true
    @AppStorage(Prefs.showBattery) private var showBattery = true
    @AppStorage(Prefs.showBluetooth) private var showBluetooth = true
    @AppStorage(Prefs.showCalendar) private var showCalendar = true
    @AppStorage(Prefs.detectCalls) private var detectCalls = true
    @AppStorage(Prefs.detectClaude) private var detectClaude = true
    @AppStorage(Prefs.showDownloads) private var showDownloads = true
    @AppStorage(Prefs.showBadges) private var showBadges = true
    @AppStorage(Prefs.clipboardHistory) private var clipboardHistory = true
    @AppStorage(Prefs.downloadsToShelf) private var downloadsToShelf = false
    @AppStorage(Prefs.showPrivacy) private var showPrivacy = true
    @AppStorage(Prefs.defaultTab) private var defaultTab = "auto"
    @AppStorage(Prefs.claudePrimary) private var claudePrimary = "auto"
    @AppStorage(Prefs.showReminders) private var showReminders = true
    @AppStorage(Prefs.showBanners) private var showBanners = true
    @AppStorage(Prefs.screenMode) private var screenMode = "mouse"
    @AppStorage(Prefs.simulateNotch) private var simulateNotch = false
    @AppStorage(Loc.key) private var language = "system"

    @ObservedObject private var model = IslandModel.shared
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Updater.autoKey) private var autoUpdate = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var fullDisk = NotificationDBMonitor.path != nil
    @State private var folders = Prefs.folders
    @State private var claudeMessage: String?

    @AppStorage("settingsPage") private var page = 0
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(page) }, set: { if let v = $0 { page = v } })) {
                ForEach(Array(Self.pages.enumerated()), id: \.offset) { i, p in
                    Label(p.0, systemImage: p.1).tag(i)
                }
                .id(language)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                switch page {
                case 0: page0
                case 1: page1
                case 2: page6
                case 3: page2
                case 4: page3
                case 5: page4
                case 6: page5
                default: page0
                }
            }
            .navigationTitle(Self.pages[min(page, Self.pages.count - 1)].0)
            .id(language)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onReceive(refresh) { _ in axTrusted = AXIsProcessTrusted(); fullDisk = NotificationDBMonitor.path != nil }
    }

    static var pages: [(String, String)] { [
        (tr("Allgemein"), "gearshape"),
        (tr("Tabs"), "square.grid.2x2"),
        (tr("Mitteilungen"), "message.badge"),
        (tr("Aktivitäten"), "bell.badge"),
        (tr("Claude"), "sparkle"),
        (tr("Berechtigungen"), "lock.shield"),
        (tr("Update"), "arrow.down.circle")
    ] }

    @ViewBuilder private var page0: some View {
            Form {
            Section(tr("Allgemein")) {
                Picker("Sprache / Language", selection: $language) {
                    Text(tr("Wie das System")).tag("system")
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                }
                Toggle(tr("Öffnen, wenn die Maus auf die Notch zeigt"), isOn: $hoverToOpen)
                Picker(tr("Standard-Tab beim Öffnen"), selection: $defaultTab) {
                    Text("Automatisch (passend zur Aktivität)").tag("auto")
                    ForEach(IslandTab.allCases.filter { model.isVisible($0) }) { t in Label(t.title, systemImage: t.icon).tag(t.rawValue) }
                }
                HStack {
                    Text(tr("Tab-Reihenfolge: in der Insel per Drag & Drop ändern"))
                    Spacer()
                    Button(tr("Zurücksetzen")) { IslandModel.shared.resetTabOrder() }
                }
                Toggle(tr("Schwarze Notch simulieren (Macs/Monitore ohne Notch)"), isOn: $simulateNotch)
                Picker(tr("Bildschirm"), selection: $screenMode) {
                    Text("Folgt der Maus (mehrere Monitore)").tag("mouse")
                    Text("Immer der Bildschirm mit Notch").tag("notch")
                    Text("Immer der Hauptbildschirm").tag("main")
                }
                Toggle(tr("Haptisches Feedback (Trackpad)"), isOn: $haptics)
                Toggle(tr("Bei der Anmeldung starten"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }

            Section(tr("Anzeigen")) {
                Toggle(tr("Lautstärke in der Notch"), isOn: $showVolumeHUD)
                Toggle(tr("Helligkeit in der Notch"), isOn: $showBrightnessHUD)
            }

            Section(tr("Ausprobieren")) {
                HStack {
                    Button(tr("Hinweis")) {
                        IslandModel.shared.show(Toast(symbol: "airpodspro", tint: .white, title: tr("AirPods Pro"), subtitle: tr("Verbunden"),
                                                      trailing: .ring(0.82), duration: 3))
                    }
                    Button(tr("10-Sek-Timer")) { TimerService.shared.start(seconds: 10, label: tr("Test-Timer")) }
                    Button(tr("Laden")) {
                        IslandModel.shared.show(Toast(symbol: "bolt.fill", tint: .green, title: tr("Lädt"),
                                                      trailing: .battery(BatteryMonitor.shared.level, charging: true), duration: 3))
                    }
                }
            }
        
            }
            .formStyle(.grouped)
    }

    @ViewBuilder private var page1: some View { TabOptionsView() }

    @ViewBuilder private var page6: some View { NotificationOptionsView() }

    @ViewBuilder private var page2: some View {
            Form {
            Section(tr("Live-Aktivitäten")) {
                Toggle(tr("Musik & Videos (Spotify, Musik, YouTube in Chrome)"), isOn: $showMedia)
                Toggle(tr("Anrufe (WhatsApp, Discord, FaceTime, Zoom, Teams …)"), isOn: $detectCalls)
                Toggle(tr("Claude: Fortschritt & „Antwort bereit“"), isOn: $detectClaude)
                Toggle(tr("Nächster Termin (15 Min vorher)"), isOn: $showCalendar)
                Toggle(tr("Fällige Erinnerungen (Apple Erinnerungen)"), isOn: $showReminders)
                Toggle(tr("Downloads"), isOn: $showDownloads)
                Toggle(tr("Mikrofon- & Kamera-Anzeige"), isOn: $showPrivacy)
                Toggle(tr("Laden, Akku schwach"), isOn: $showBattery)
                Toggle(tr("Bluetooth-Geräte (AirPods …)"), isOn: $showBluetooth)
            }

            Section(tr("Ablage & Zwischenablage")) {
                Toggle(tr("Fertige Downloads automatisch in die Ablage"), isOn: $downloadsToShelf)
                Toggle(tr("Zwischenablage-Verlauf (nur im Speicher)"), isOn: $clipboardHistory)
                ForEach(folders, id: \.self) { f in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.cyan)
                        Text((f as NSString).lastPathComponent)
                        Text(f).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) {
                            folders.removeAll { $0 == f }
                            Prefs.folders = folders
                        } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                }
                Button(tr("Zielordner für Drag & Drop hinzufügen …")) { addFolder() }
                    .disabled(folders.count >= 3)
            }
            }
            .formStyle(.grouped)
    }

    @ViewBuilder private var page3: some View {
            Form {
            Section(tr("Claude")) {
                Picker(tr("Claude als Haupt-Tab"), selection: $claudePrimary) {
                    ForEach(ClaudePrimaryMode.allCases) { m in Text(m.title).tag(m.rawValue) }
                }
                Text(tr("„Bei großen Aufgaben“: Sobald Claude länger arbeitet oder Schritte meldet, öffnet die Insel direkt im Claude-Tab und zeigt Claude zuerst."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(tr("Mit Claude Desktop verbinden (MCP-Werkzeug „notch_status“)")) { connectClaude() }
                if let claudeMessage { Text(claudeMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button(tr("Mit Claude Code verbinden (Terminal: Fortschritt & Erlaubnisse in der Notch)")) { connectClaude(code: true) }
                Button(tr("Vorschau: Claude-Fortschritt abspielen")) { ClaudeService.shared.demo() }
                Button(tr("Vorschau: Erlaubnis-Anfrage in der Notch")) { ClaudeService.shared.demoPermission() }
                Button(tr("Vorschau: Rückfrage mit Auswahl")) { ClaudeService.shared.demoQuestion() }
                Text(tr("Erlaubnis-Anfragen und Rückfragen von Claude (z. B. „Welchen Weg möchtest du?“) erscheinen immer in der Notch – auch wenn Claude offen ist – mit denselben Antwortmöglichkeiten wie im Chat. Benötigt die Bedienungshilfen-Freigabe."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
    }

    @ViewBuilder private var page4: some View {
            Form {
            Section(tr("Berechtigungen")) {
                HStack {
                    Label(tr("Bedienungshilfen"), systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Spacer()
                    if !axTrusted { Button(tr("Erlauben …")) { AX.requestTrust() } }
                }
                Text(tr("Nötig für: Claude-Erkennung & -Rückfragen, Mitteilungen (Absender/Text), Dock-Badges und Medientasten. Mitteilungen erscheinen nur, wenn die App in den Systemeinstellungen › Mitteilungen Banner zeigen darf."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(tr("Festplattenvollzugriff (optional)"), systemImage: fullDisk ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(fullDisk ? .green : .secondary)
                    Spacer()
                    if !fullDisk { Button(tr("Öffnen …")) { NotificationDBMonitor.openSettings() } }
                }
                Text(tr("Damit erscheinen Mitteilungen auch im Fokus-/„Nicht stören“-Modus und wenn eine App keine Banner zeigt. Notch Island in die Liste ziehen (aus ~/Programme) und einschalten. Gelesen wird nur die Mitteilungs-Datenbank."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label("Kalender", systemImage: "calendar")
                    Spacer()
                    Button(tr("Zugriff anfragen")) { CalendarService.shared.requestAccess() }
                }
                HStack {
                    Label("Erinnerungen", systemImage: "checklist")
                    Spacer()
                    Button(tr("Zugriff anfragen")) { RemindersService.shared.requestAccess() }
                }
                Text(tr("Spotify, Musik und Chrome fragen beim ersten Mal einzeln nach („Automation“). Für YouTube in Chrome zusätzlich: Darstellung › Entwickler › „JavaScript von Apple Events erlauben“."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button(tr("Einrichtungsassistent öffnen …")) { SetupWindow.show(at: .welcome) }
            }
            }
            .formStyle(.grouped)
    }

    @ViewBuilder private var page5: some View {
            Form {
            Section(tr("Updates")) {
                HStack {
                    Text(tr("Installiert: Version \(updater.currentVersion)"))
                    Spacer()
                    switch updater.state {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Label("Aktuell", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .available(let r): Text(tr("Neu: \(r.version)")).foregroundStyle(.blue).bold()
                    case .downloading, .installing: Text(tr("Wird installiert …"))
                    case .failed(let e): Text(e).foregroundStyle(.orange).lineLimit(1)
                    case .notConfigured: Text(tr("Kein Repository eingetragen")).foregroundStyle(.secondary)
                    case .idle: EmptyView()
                    }
                }
                if let r = updater.available {
                    if !r.notes.isEmpty { Text(r.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6) }
                    HStack {
                        Button(tr("Jetzt installieren")) { updater.install() }.buttonStyle(.borderedProminent)
                        Button(tr("Auf GitHub ansehen")) { NSWorkspace.shared.open(r.pageURL) }
                    }
                } else {
                    Button(tr("Nach Updates suchen")) { updater.check() }
                }
                Toggle(tr("Automatisch nach Updates suchen"), isOn: $autoUpdate)
                TextField(tr("GitHub-Repository (besitzer/notch-island)"), text: Binding(get: { updater.repository }, set: { updater.repository = $0 }))
                Text(tr("Notch Island fragt dazu nur die öffentliche GitHub-Seite des Projekts ab. Beim Installieren wird die neue Version geladen, die App ausgetauscht und neu gestartet – deine Einstellungen und Freigaben bleiben."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
    }

    private var mcpPath: String { Bundle.main.bundlePath + "/Contents/MacOS/notch-mcp" }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = tr("Hinzufügen")
        if p.runModal() == .OK, let u = p.url, !folders.contains(u.path) {
            folders.append(u.path)
            Prefs.folders = folders
        }
    }

    private func connectClaude(code: Bool = false) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: mcpPath)
        task.arguments = [code ? "--install-claude-code" : "--install-claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            claudeMessage = out.trimmingCharacters(in: .whitespacesAndNewlines) + (code ? "\nNeue Claude-Code-Sitzungen nutzen es automatisch." : "\nClaude Desktop einmal neu starten.")
        } catch {
            claudeMessage = tr("Fehler: \(error.localizedDescription)")
        }
    }

    private func copyHooks() {
        let cmd = mcpPath.replacingOccurrences(of: " ", with: "\\ ")
        let json = """
        {
          "hooks": {
            "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "\(cmd) --hook running" }] }],
            "Notification":     [{ "hooks": [{ "type": "command", "command": "\(cmd) --hook waiting" }] }],
            "Stop":             [{ "hooks": [{ "type": "command", "command": "\(cmd) --hook done" }] }]
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
        claudeMessage = tr("Hooks kopiert – in ~/.claude/settings.json einfügen (Claude Code).")
    }
}
