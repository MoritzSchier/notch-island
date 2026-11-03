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

    @ObservedObject private var model = IslandModel.shared
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Updater.autoKey) private var autoUpdate = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var fullDisk = NotificationDBMonitor.path != nil
    @State private var folders = Prefs.folders
    @State private var claudeMessage: String?

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            Form {
            Section("Allgemein") {
                Toggle("Öffnen, wenn die Maus auf die Notch zeigt", isOn: $hoverToOpen)
                Picker("Standard-Tab beim Öffnen", selection: $defaultTab) {
                    Text("Automatisch (passend zur Aktivität)").tag("auto")
                    ForEach(IslandTab.allCases.filter { model.isVisible($0) }) { t in Label(t.title, systemImage: t.icon).tag(t.rawValue) }
                }
                HStack {
                    Text("Tab-Reihenfolge: in der Insel per Drag & Drop ändern")
                    Spacer()
                    Button("Zurücksetzen") { IslandModel.shared.resetTabOrder() }
                }
                Picker("Bildschirm", selection: $screenMode) {
                    Text("Folgt der Maus (mehrere Monitore)").tag("mouse")
                    Text("Immer der Bildschirm mit Notch").tag("notch")
                    Text("Immer der Hauptbildschirm").tag("main")
                }
                Toggle("Haptisches Feedback (Trackpad)", isOn: $haptics)
                Toggle("Bei der Anmeldung starten", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }

            Section("Anzeigen") {
                Toggle("Lautstärke in der Notch", isOn: $showVolumeHUD)
                Toggle("Helligkeit in der Notch", isOn: $showBrightnessHUD)
            }

            Section("Ausprobieren") {
                HStack {
                    Button("Hinweis") {
                        IslandModel.shared.show(Toast(symbol: "airpodspro", tint: .white, title: "AirPods Pro", subtitle: "Verbunden",
                                                      trailing: .ring(0.82), duration: 3))
                    }
                    Button("10-Sek-Timer") { TimerService.shared.start(seconds: 10, label: "Test-Timer") }
                    Button("Laden") {
                        IslandModel.shared.show(Toast(symbol: "bolt.fill", tint: .green, title: "Lädt",
                                                      trailing: .battery(BatteryMonitor.shared.level, charging: true), duration: 3))
                    }
                }
            }
        
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            Form {
            Section("Welche Tabs zeigt die Insel?") {
                ForEach(IslandTab.allCases) { t in
                    Toggle(isOn: Binding(get: { model.isVisible(t) }, set: { model.setVisible(t, $0) })) {
                        Label(t.title, systemImage: t.icon)
                    }
                    .disabled(t == .home)
                }
                Text("„Start“ ist immer da. Die Reihenfolge änderst du direkt in der Insel per Drag & Drop.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reihenfolge zurücksetzen") { IslandModel.shared.resetTabOrder() }
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Tabs", systemImage: "square.grid.2x2") }

            Form {
            Section("Live-Aktivitäten") {
                Toggle("Musik & Videos (Spotify, Musik, YouTube in Chrome)", isOn: $showMedia)
                Toggle("Anrufe (WhatsApp, Discord, FaceTime, Zoom, Teams …)", isOn: $detectCalls)
                Toggle("Claude: Fortschritt & „Antwort bereit“", isOn: $detectClaude)
                Toggle("Nächster Termin (15 Min vorher)", isOn: $showCalendar)
                Toggle("Fällige Erinnerungen (Apple Erinnerungen)", isOn: $showReminders)
                Toggle("Downloads", isOn: $showDownloads)
                Toggle("Mikrofon- & Kamera-Anzeige", isOn: $showPrivacy)
                Toggle("Mitteilungen mit Absender & Text (WhatsApp, Mail, Chrome …)", isOn: $showBanners)
                Toggle("Neue Mitteilungen (Dock-Badges, falls kein Banner kam)", isOn: $showBadges)
                Toggle("Laden, Akku schwach", isOn: $showBattery)
                Toggle("Bluetooth-Geräte (AirPods …)", isOn: $showBluetooth)
            }

            Section("Ablage & Zwischenablage") {
                Toggle("Fertige Downloads automatisch in die Ablage", isOn: $downloadsToShelf)
                Toggle("Zwischenablage-Verlauf (nur im Speicher)", isOn: $clipboardHistory)
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
                Button("Zielordner für Drag & Drop hinzufügen …") { addFolder() }
                    .disabled(folders.count >= 3)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Aktivitäten", systemImage: "bell.badge") }

            Form {
            Section("Claude") {
                Picker("Claude als Haupt-Tab", selection: $claudePrimary) {
                    ForEach(ClaudePrimaryMode.allCases) { m in Text(m.title).tag(m.rawValue) }
                }
                Text("„Bei großen Aufgaben“: Sobald Claude länger arbeitet oder Schritte meldet, öffnet die Insel direkt im Claude-Tab und zeigt Claude zuerst.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Mit Claude Desktop verbinden (MCP-Werkzeug „notch_status“)") { connectClaude() }
                if let claudeMessage { Text(claudeMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("Claude-Code-Hooks in die Zwischenablage kopieren") { copyHooks() }
                Button("Vorschau: Claude-Fortschritt abspielen") { ClaudeService.shared.demo() }
                Button("Vorschau: Erlaubnis-Anfrage in der Notch") { ClaudeService.shared.demoPermission() }
                Button("Vorschau: Rückfrage mit Auswahl") { ClaudeService.shared.demoQuestion() }
                Text("Erlaubnis-Anfragen und Rückfragen von Claude (z. B. „Welchen Weg möchtest du?“) erscheinen immer in der Notch – auch wenn Claude offen ist – mit denselben Antwortmöglichkeiten wie im Chat. Benötigt die Bedienungshilfen-Freigabe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Claude", systemImage: "sparkle") }

            Form {
            Section("Berechtigungen") {
                HStack {
                    Label("Bedienungshilfen", systemImage: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    Spacer()
                    if !axTrusted { Button("Erlauben …") { AX.requestTrust() } }
                }
                Text("Nötig für: Claude-Erkennung & -Rückfragen, Mitteilungen (Absender/Text), Dock-Badges und Medientasten. Mitteilungen erscheinen nur, wenn die App in den Systemeinstellungen › Mitteilungen Banner zeigen darf.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label("Festplattenvollzugriff (optional)", systemImage: fullDisk ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(fullDisk ? .green : .secondary)
                    Spacer()
                    if !fullDisk { Button("Öffnen …") { NotificationDBMonitor.openSettings() } }
                }
                Text("Damit erscheinen Mitteilungen auch im Fokus-/„Nicht stören“-Modus und wenn eine App keine Banner zeigt. Notch Island in die Liste ziehen (aus ~/Programme) und einschalten. Gelesen wird nur die Mitteilungs-Datenbank.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label("Kalender", systemImage: "calendar")
                    Spacer()
                    Button("Zugriff anfragen") { CalendarService.shared.requestAccess() }
                }
                HStack {
                    Label("Erinnerungen", systemImage: "checklist")
                    Spacer()
                    Button("Zugriff anfragen") { RemindersService.shared.requestAccess() }
                }
                Text("Spotify, Musik und Chrome fragen beim ersten Mal einzeln nach („Automation“). Für YouTube in Chrome zusätzlich: Darstellung › Entwickler › „JavaScript von Apple Events erlauben“.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Einrichtungsassistent öffnen …") { SetupWindow.show() }
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Berechtigungen", systemImage: "lock.shield") }

            Form {
            Section("Updates") {
                HStack {
                    Text("Installiert: Version \(updater.currentVersion)")
                    Spacer()
                    switch updater.state {
                    case .checking: ProgressView().controlSize(.small)
                    case .upToDate: Label("Aktuell", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .available(let r): Text("Neu: \(r.version)").foregroundStyle(.blue).bold()
                    case .downloading, .installing: Text("Wird installiert …")
                    case .failed(let e): Text(e).foregroundStyle(.orange).lineLimit(1)
                    case .notConfigured: Text("Kein Repository eingetragen").foregroundStyle(.secondary)
                    case .idle: EmptyView()
                    }
                }
                if let r = updater.available {
                    if !r.notes.isEmpty { Text(r.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6) }
                    HStack {
                        Button("Jetzt installieren") { updater.install() }.buttonStyle(.borderedProminent)
                        Button("Auf GitHub ansehen") { NSWorkspace.shared.open(r.pageURL) }
                    }
                } else {
                    Button("Nach Updates suchen") { updater.check() }
                }
                Toggle("Automatisch nach Updates suchen", isOn: $autoUpdate)
                TextField("GitHub-Repository (besitzer/notch-island)", text: Binding(get: { updater.repository }, set: { updater.repository = $0 }))
                Text("Notch Island fragt dazu nur die öffentliche GitHub-Seite des Projekts ab. Beim Installieren wird die neue Version geladen, die App ausgetauscht und neu gestartet – deine Einstellungen und Freigaben bleiben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .formStyle(.grouped)
            .tabItem { Label("Update", systemImage: "arrow.down.circle") }
        }
        .frame(minWidth: 600, minHeight: 600)
        .onReceive(refresh) { _ in axTrusted = AXIsProcessTrusted(); fullDisk = NotificationDBMonitor.path != nil }
    }

    private var mcpPath: String { Bundle.main.bundlePath + "/Contents/MacOS/notch-mcp" }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Hinzufügen"
        if p.runModal() == .OK, let u = p.url, !folders.contains(u.path) {
            folders.append(u.path)
            Prefs.folders = folders
        }
    }

    private func connectClaude() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: mcpPath)
        task.arguments = ["--install-claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            claudeMessage = out.trimmingCharacters(in: .whitespacesAndNewlines) + "\nClaude Desktop einmal neu starten."
        } catch {
            claudeMessage = "Fehler: \(error.localizedDescription)"
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
        claudeMessage = "Hooks kopiert – in ~/.claude/settings.json einfügen (Claude Code)."
    }
}
