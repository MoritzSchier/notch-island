import SwiftUI
import AppKit
import EventKit
import ServiceManagement

/// Einrichtungs-Assistent: erscheint beim ersten Start (und jederzeit über das Menü „Einrichtung …“).
/// Fragt Schritt für Schritt alle Freigaben an – jeweils mit kurzer, verständlicher Erklärung – und verbindet Claude.
struct SetupView: View {
    var onFinish: () -> Void
    var initialStep: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome, accessibility, notifications, calendar, media, claude, done
        var title: String {
            switch self {
            case .welcome: return "Willkommen"
            case .accessibility: return "Bedienungshilfen"
            case .notifications: return "Mitteilungen"
            case .calendar: return "Kalender"
            case .media: return "Musik"
            case .claude: return "Claude"
            case .done: return "Fertig"
            }
        }
    }

    @State private var step: Step = .welcome
    @State private var didInit = false
    @State private var ax = AXIsProcessTrusted()
    @State private var fullDisk = NotificationDBMonitor.path != nil
    @State private var calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @State private var reminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    @State private var automation: [String: AutomationStatus] = [:]
    @State private var claudeConnected = SetupView.claudeIsConnected()
    @State private var claudeMessage = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Fortschritt
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 28).padding(.top, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) { page }
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if step != .welcome && step != .done {
                    Button("Zurück") { go(-1) }
                }
                Spacer()
                if step != .welcome && step != .done && !stepDone {
                    Button("Überspringen") { go(1) }
                }
                Button(step == .done ? "Los geht’s" : (step == .welcome ? "Einrichtung starten" : "Weiter")) {
                    if step == .done { finish() } else { go(1) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560, height: 560)
        .onReceive(tick) { _ in refresh() }
        .onAppear {
            if !didInit { didInit = true; step = initialStep }
            refresh()
        }
    }

    private var stepDone: Bool {
        switch step {
        case .accessibility: return ax
        case .notifications: return fullDisk
        case .calendar: return calendar && reminders
        case .claude: return claudeConnected
        default: return false
        }
    }

    private func go(_ d: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            step = Step(rawValue: max(0, min(Step.allCases.count - 1, step.rawValue + d))) ?? step
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "setupDone")
        onFinish()
    }

    private func refresh() {
        ax = AXIsProcessTrusted()
        fullDisk = NotificationDBMonitor.path != nil
        calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        reminders = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if step == .media {
            for a in Self.mediaApps { automation[a.id] = Self.automationStatus(a.id, ask: false) }
        }
    }

    // MARK: Seiten

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            header("sparkles", "Willkommen bei Notch Island", "Deine Notch wird zur Dynamic Island – wie beim iPhone.")
            bullet("music.note", "Musik, Anrufe, Timer und Termine live oben in der Notch")
            bullet("message.fill", "Mitteilungen mit Absender und Text – WhatsApp, Mail, Chrome …")
            bullet("tray.full.fill", "Dateien auf die Notch ziehen: ablegen, teilen, umwandeln, verkleinern")
            bullet("sparkle", "Claude: Fortschritt sehen und Fragen direkt oben beantworten")
            Text("In den nächsten Schritten erlaubst du, was Notch Island dafür braucht. Jeder Schritt ist erklärt und lässt sich überspringen – du kannst alles später in den Einstellungen nachholen.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        case .accessibility:
            header("hand.raised.fill", "Bedienungshilfen erlauben", "Die wichtigste Freigabe – ohne sie bleibt die Insel ziemlich still.")
            Text("Damit kann Notch Island:").font(.headline)
            bullet("message", "Mitteilungen mit Absender und Text anzeigen")
            bullet("sparkle", "erkennen, wann Claude arbeitet, und Fragen in der Notch beantworten")
            bullet("app.badge", "neue Nachrichten in Apps erkennen (rote Zähler im Dock)")
            status(ax, "Erlaubt", "Noch nicht erlaubt")
            if !ax {
                instructions([
                    "Klicke unten auf „Freigabe anfragen“.",
                    "Klicke im Hinweis auf „Systemeinstellungen öffnen“.",
                    "Schalte „Notch Island“ ein (evtl. mit Passwort/Touch ID bestätigen).",
                ])
                HStack {
                    Button("Freigabe anfragen") { AX.requestTrust() }.buttonStyle(.borderedProminent)
                    Button("Einstellungen öffnen") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
                }
                note("Heißt bei neueren macOS-Versionen „Gerätesteuerung und Datenzugriff“.")
            }

        case .notifications:
            header("bell.badge.fill", "Mitteilungen auch im Fokus-Modus", "Optional, aber empfohlen.")
            Text("Ohne diese Freigabe sieht Notch Island Mitteilungen nur, wenn macOS ein Banner zeigt. Mit „Festplattenvollzugriff“ erscheinen sie immer – auch bei „Nicht stören“, Fokus oder ausgeschalteten Bannern. Gelesen wird nur die Mitteilungsliste, keine anderen Dateien.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            status(fullDisk, "Erlaubt – Mitteilungen kommen immer an", "Noch nicht erlaubt")
            if !fullDisk {
                instructions([
                    "Klicke auf „Einstellungen öffnen“ – es öffnet sich „Festplattenvollzugriff“.",
                    "Klicke unten auf „+“ und wähle „Notch Island“ (Knopf „App im Finder zeigen“ hilft) – oder ziehe die App in die Liste.",
                    "Schalte den Schalter neben „Notch Island“ ein.",
                    "Danach hier auf „Neu starten“ klicken – erst dann wirkt die Freigabe.",
                ])
                HStack {
                    Button("Einstellungen öffnen") { NotificationDBMonitor.openSettings() }.buttonStyle(.borderedProminent)
                    Button("App im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    Button("Neu starten") { SetupView.relaunch() }
                }
                note("Die Freigabe wirkt erst nach einem Neustart von Notch Island.")
            }

        case .calendar:
            header("calendar", "Kalender & Erinnerungen", "Für „Als Nächstes“: dein nächster Termin und fällige Erinnerungen.")
            permissionRow("Kalender", "calendar", calendar) { CalendarService.shared.requestAccess() }
            permissionRow("Erinnerungen", "checklist", reminders) { RemindersService.shared.requestAccess() }
            note("macOS fragt einmal nach – einfach „Erlauben“ bzw. „Vollzugriff erlauben“ wählen.")

        case .media:
            header("music.note", "Musik & Videos", "Damit die Insel zeigt, was läuft – und du es steuern kannst.")
            Text("Für jede App fragt macOS einmal „Notch Island möchte … steuern“. Bitte mit „Erlauben“ bestätigen. Die App muss dafür geöffnet sein.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.mediaApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }, id: \.id) { a in
                HStack {
                    if let i = AppInfo.icon(a.id) { Image(nsImage: i).resizable().frame(width: 22, height: 22) }
                    Text(a.name)
                    Spacer()
                    switch automation[a.id] ?? .unknown {
                    case .granted: Label("Erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button("In Einstellungen ändern") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") }
                    case .notRunning:
                        Button("\(a.name) öffnen") { AppInfo.activate(a.id) }
                    case .unknown:
                        Button("Erlauben") { automation[a.id] = Self.automationStatus(a.id, ask: true) }
                    }
                }
            }
            note("YouTube in Chrome: zusätzlich in Chrome › Darstellung › Entwickler › „JavaScript von Apple Events erlauben“ anhaken.")

        case .claude:
            header("sparkle", "Mit Claude verbinden", "Optional – nur wenn du die Claude-App nutzt.")
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: Const.claudeBundle) == nil {
                Text("Claude Desktop ist nicht installiert – diesen Schritt einfach überspringen.").foregroundStyle(.secondary)
            } else {
                Text("Notch Island zeigt dann, woran Claude arbeitet (mit Schritten und Fortschritt), meldet „Antwort bereit“ und lässt dich Erlaubnis-Anfragen und Rückfragen direkt in der Notch beantworten.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status(claudeConnected, "Verbunden", "Noch nicht verbunden")
                if !claudeConnected {
                    Button("Mit Claude verbinden") { connectClaude() }.buttonStyle(.borderedProminent)
                }
                if !claudeMessage.isEmpty { note(claudeMessage) }
                note("Danach Claude einmal ganz beenden (⌘Q) und neu öffnen. Für Rückfragen in der Notch braucht es außerdem die Bedienungshilfen (Schritt 2).")
            }

        case .done:
            header("checkmark.seal.fill", "Fertig!", "Zeige mit der Maus auf die Notch – die Insel klappt auf.")
            bullet("hand.point.up.left.fill", "Tabs per Drag & Drop sortieren, Zahnrad oben rechts für Einstellungen")
            bullet("eye", "Welche Tabs du siehst, stellst du in den Einstellungen › Tabs ein")
            bullet("arrow.down.circle", "Updates werden automatisch angeboten")
            Toggle("Bei der Anmeldung automatisch starten", isOn: Binding(get: { launchAtLogin }, set: { on in
                do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }))
            .padding(.top, 6)
        }
    }

    // MARK: Bausteine

    private func header(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.bold())
                Text(sub).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
        }
    }

    private func status(_ ok: Bool, _ yes: String, _ no: String) -> some View {
        Label(ok ? yes : no, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ok ? .green : .orange).font(.headline)
    }

    private func instructions(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)").font(.caption.bold()).frame(width: 18, height: 18)
                        .background(Circle().fill(Color.accentColor.opacity(0.18)))
                    Text(s).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(_ title: String, _ symbol: String, _ ok: Bool, ask: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if ok { Label("Erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            else { Button("Erlauben", action: ask) }
        }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    private func connectClaude() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/notch-mcp")
        p.arguments = ["--install-claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run(); p.waitUntilExit()
            claudeConnected = Self.claudeIsConnected()
            claudeMessage = claudeConnected ? "Eingetragen. Jetzt Claude neu starten." :
                (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Fehler")
        } catch { claudeMessage = "Fehler: \(error.localizedDescription)" }
    }

    // MARK: Hilfen

    static func claudeIsConnected() -> Bool {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = o["mcpServers"] as? [String: Any] else { return false }
        return s["notch-island"] != nil
    }

    struct MediaApp { let id: String; let name: String }
    static let mediaApps = [MediaApp(id: Const.spotify, name: "Spotify"), MediaApp(id: Const.music, name: "Musik"),
                            MediaApp(id: Const.chrome, name: "Google Chrome")]

    enum AutomationStatus { case unknown, granted, denied, notRunning }

    static func automationStatus(_ bundleID: String, ask: Bool) -> AutomationStatus {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let r = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch r {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Fenster für den Assistenten
enum SetupWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Notch Island einrichten"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(onFinish: { SetupWindow.close() }))
            w.center()
            window = w
        }
        IslandModel.shared.collapse()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }

    /// Beim ersten Start automatisch zeigen
    static func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: "setupDone") { show() }
    }
}
