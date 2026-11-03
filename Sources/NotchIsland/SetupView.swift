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
        case welcome, look, accessibility, notifications, calendar, media, claude, done
        var title: String {
            switch self {
            case .welcome: return tr("Willkommen")
            case .look: return tr("Aussehen & Tabs")
            case .accessibility: return tr("Bedienungshilfen")
            case .notifications: return tr("Mitteilungen")
            case .calendar: return tr("Kalender")
            case .media: return tr("Musik")
            case .claude: return tr("Claude")
            case .done: return tr("Fertig")
            }
        }
    }

    @State private var step: Step = .welcome
    @ObservedObject private var model = IslandModel.shared
    @AppStorage(Prefs.simulateNotch) private var simulateNotch = false
    @AppStorage(Prefs.hoverToOpen) private var hoverToOpen = true
    @AppStorage(Loc.key) private var language = "system"
    @State private var didInit = false
    @State private var ax = AXIsProcessTrusted()
    @State private var fullDisk = NotificationDBMonitor.path != nil
    @ObservedObject private var cal = CalendarService.shared
    @ObservedObject private var rem = RemindersService.shared
    // Status direkt aus den Diensten – aktualisiert sich sofort nach dem „Erlauben“ (ohne Neustart)
    private var calendar: Bool { cal.authorized || EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    private var reminders: Bool { rem.authorized || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    @State private var automation: [String: AutomationStatus] = [:]
    @State private var claudeConnected = SetupView.claudeIsConnected()
    @State private var claudeMessage = ""
    @State private var codeConnected = SetupView.claudeCodeIsConnected()
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
                    .id(language)
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if step != .welcome && step != .done {
                    Button(tr("Zurück")) { go(-1) }
                }
                Spacer()
                if step != .welcome && step != .done && !stepDone {
                    Button(tr("Überspringen")) { go(1) }
                }
                Button(step == .done ? tr("Los geht’s") : (step == .welcome ? tr("Einrichtung starten") : tr("Weiter"))) {
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
        // Zuletzt geöffnete Seite merken – nach einem Neustart geht es dort weiter
        .onChange(of: step) { _, s in UserDefaults.standard.set(s.rawValue, forKey: "setupStep") }
    }

    private var stepDone: Bool {
        switch step {
        case .accessibility: return ax
        case .notifications: return fullDisk
        case .calendar: return calendar && reminders
        case .claude: return claudeConnected && (codeConnected || !FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude"))
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
        UserDefaults.standard.set(0, forKey: "setupStep")
        onFinish()
    }

    private func refresh() {
        ax = AXIsProcessTrusted()
        fullDisk = NotificationDBMonitor.path != nil
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if step == .media {
            for a in Self.mediaApps { automation[a.id] = Self.automationStatus(a.id, ask: false) }
        }
    }

    // MARK: Seiten

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome:
            Picker("", selection: $language) {
                Text("Deutsch").tag("de")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .onAppear { if language == "system" { language = Loc.current } }
            header("sparkles", tr("Willkommen bei Notch Island"), tr("Deine Notch wird zur Dynamic Island – wie beim iPhone."))
            bullet("music.note", tr("Musik, Anrufe, Timer und Termine live oben in der Notch"))
            bullet("message.fill", tr("Mitteilungen mit Absender und Text – WhatsApp, Mail, Chrome …"))
            bullet("tray.full.fill", tr("Dateien auf die Notch ziehen: ablegen, teilen, umwandeln, verkleinern"))
            bullet("sparkle", tr("Claude: Fortschritt sehen und Fragen direkt oben beantworten"))
            Text(tr("In den nächsten Schritten erlaubst du, was Notch Island dafür braucht. Jeder Schritt ist erklärt und lässt sich überspringen – du kannst alles später in den Einstellungen nachholen."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        case .look:
            header("rectangle.topthird.inset.filled", tr("Aussehen & Tabs"), tr("Wie soll deine Insel aussehen, und was soll sie zeigen?"))
            Text(tr("Notch")).font(.headline)
            if Self.anyScreenWithoutNotch {
                Toggle(isOn: $simulateNotch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Schwarze Notch dauerhaft anzeigen"))
                        Text(Self.anyScreenWithNotch
                             ? tr("Für Bildschirme ohne Notch (z. B. externer Monitor): oben in der Mitte sitzt dann immer eine kleine schwarze Notch. Aus: Die Insel erscheint dort nur, wenn etwas passiert oder die Maus oben ist.")
                             : tr("Dein Mac hat keine Notch. An: Oben in der Mitte sitzt immer eine kleine schwarze Notch wie bei neueren MacBooks. Aus: Die Insel erscheint nur, wenn etwas passiert oder die Maus oben ist."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Label("Dein Mac hat eine Notch – die Insel nutzt sie direkt.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(tr("Tabs")).font(.headline).padding(.top, 6)
            Text(tr("Häkchen = Tab wird angezeigt. Reihenfolge: Zeile an ☰ ziehen oder Pfeile nutzen – die oberste steht in der Insel ganz links. Später änderbar unter Einstellungen › Tabs oder direkt in der Insel per Drag & Drop."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TabOrderList()
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Toggle(tr("Öffnen, sobald die Maus auf die Notch zeigt"), isOn: $hoverToOpen).padding(.top, 6)

        case .accessibility:
            header("hand.raised.fill", tr("Bedienungshilfen erlauben"), tr("Die wichtigste Freigabe – ohne sie bleibt die Insel ziemlich still."))
            Text(tr("Damit kann Notch Island:")).font(.headline)
            bullet("message", tr("Mitteilungen mit Absender und Text anzeigen"))
            bullet("sparkle", tr("erkennen, wann Claude arbeitet, und Fragen in der Notch beantworten"))
            bullet("app.badge", tr("neue Nachrichten in Apps erkennen (rote Zähler im Dock)"))
            status(ax, tr("Erlaubt"), tr("Noch nicht erlaubt"))
            if !ax {
                instructions([
                    tr("Klicke unten auf „Freigabe anfragen“."),
                    tr("Klicke im Hinweis auf „Systemeinstellungen öffnen“."),
                    tr("Schalte „Notch Island“ ein (evtl. mit Passwort/Touch ID bestätigen)."),
                ])
                HStack {
                    Button(tr("Freigabe anfragen")) { AX.requestTrust() }.buttonStyle(.borderedProminent)
                    Button(tr("Einstellungen öffnen")) { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
                }
                note(tr("Heißt bei neueren macOS-Versionen „Gerätesteuerung und Datenzugriff“."))
            }

        case .notifications:
            header("bell.badge.fill", tr("Mitteilungen auch im Fokus-Modus"), tr("Optional, aber empfohlen."))
            Text(tr("Ohne diese Freigabe sieht Notch Island Mitteilungen nur, wenn macOS ein Banner zeigt. Mit „Festplattenvollzugriff“ erscheinen sie immer – auch bei „Nicht stören“, Fokus oder ausgeschalteten Bannern. Gelesen wird nur die Mitteilungsliste, keine anderen Dateien."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            status(fullDisk, tr("Erlaubt – Mitteilungen kommen immer an"), tr("Noch nicht erlaubt"))
            if !fullDisk {
                instructions([
                    tr("Klicke auf „Einstellungen öffnen“ – es öffnet sich „Festplattenvollzugriff“."),
                    tr("Klicke unten auf „+“ und wähle „Notch Island“ (Knopf „App im Finder zeigen“ hilft) – oder ziehe die App in die Liste."),
                    tr("Schalte den Schalter neben „Notch Island“ ein."),
                    tr("Danach hier auf „Neu starten“ klicken – erst dann wirkt die Freigabe."),
                ])
                HStack {
                    Button(tr("Einstellungen öffnen")) { NotificationDBMonitor.openSettings() }.buttonStyle(.borderedProminent)
                    Button(tr("App im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    Button(tr("Neu starten")) { SetupView.relaunch() }
                }
                note(tr("Die Freigabe wirkt erst nach einem Neustart von Notch Island."))
            }

        case .calendar:
            header("calendar", tr("Kalender & Erinnerungen"), tr("Für „Als Nächstes“: dein nächster Termin und fällige Erinnerungen."))
            permissionRow(tr("Kalender"), "calendar", calendar) { CalendarService.shared.requestAccess() }
            permissionRow(tr("Erinnerungen"), "checklist", reminders) { RemindersService.shared.requestAccess() }
            note(tr("macOS fragt einmal nach – einfach „Erlauben“ bzw. „Vollzugriff erlauben“ wählen."))

        case .media:
            header("music.note", tr("Musik & Videos"), tr("Damit die Insel zeigt, was läuft – und du es steuern kannst."))
            Text(tr("Für jede App fragt macOS einmal „Notch Island möchte … steuern“. Bitte mit „Erlauben“ bestätigen. Die App muss dafür geöffnet sein."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.mediaApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }, id: \.id) { a in
                HStack {
                    if let i = AppInfo.icon(a.id) { Image(nsImage: i).resizable().frame(width: 22, height: 22) }
                    Text(a.name)
                    Spacer()
                    switch automation[a.id] ?? .unknown {
                    case .granted: Label("Erlaubt", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button(tr("In Einstellungen ändern")) { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") }
                    case .notRunning:
                        Button(tr("\(a.name) öffnen")) { AppInfo.activate(a.id) }
                    case .unknown:
                        Button(tr("Erlauben")) { automation[a.id] = Self.automationStatus(a.id, ask: true) }
                    }
                }
            }
            note(tr("YouTube in Chrome: zusätzlich in Chrome › Darstellung › Entwickler › „JavaScript von Apple Events erlauben“ anhaken."))

        case .claude:
            header("sparkle", tr("Mit Claude verbinden"), tr("Optional – nur wenn du die Claude-App nutzt."))
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: Const.claudeBundle) == nil {
                Text(tr("Claude Desktop ist nicht installiert – diesen Schritt einfach überspringen.")).foregroundStyle(.secondary)
            } else {
                Text(tr("Notch Island zeigt dann, woran Claude arbeitet (mit Schritten und Fortschritt), meldet „Antwort bereit“ und lässt dich Erlaubnis-Anfragen und Rückfragen direkt in der Notch beantworten."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status(claudeConnected, tr("Verbunden"), tr("Noch nicht verbunden"))
                if !claudeConnected {
                    Button(tr("Mit Claude verbinden")) { connectClaude() }.buttonStyle(.borderedProminent)
                }
                if !claudeMessage.isEmpty { note(claudeMessage) }
                note(tr("Danach Claude einmal ganz beenden (⌘Q) und neu öffnen. Für Rückfragen in der Notch braucht es außerdem die Bedienungshilfen (Schritt 2)."))
            }
            if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude") {
                Divider().padding(.vertical, 4)
                Text(tr("Claude Code (Terminal)")).font(.headline)
                Text(tr("Zeigt Fortschritt aller Claude-Code-Sitzungen und lässt dich Erlaubnis-Anfragen – auch von mehreren Agenten gleichzeitig – in der Notch beantworten."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                status(codeConnected, tr("Verbunden"), tr("Noch nicht verbunden"))
                if !codeConnected {
                    Button(tr("Mit Claude Code verbinden")) { connectClaudeCode() }
                }
            }

        case .done:
            header("checkmark.seal.fill", tr("Fertig!"), tr("Zeige mit der Maus auf die Notch – die Insel klappt auf."))
            bullet("hand.point.up.left.fill", tr("Tabs per Drag & Drop sortieren, Zahnrad oben rechts für Einstellungen"))
            bullet("eye", tr("Welche Tabs du siehst, stellst du in den Einstellungen › Tabs ein"))
            bullet("arrow.down.circle", tr("Updates werden automatisch angeboten"))
            Toggle(tr("Bei der Anmeldung automatisch starten"), isOn: Binding(get: { launchAtLogin }, set: { on in
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
            else { Button(tr("Erlauben"), action: ask) }
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
            claudeMessage = claudeConnected ? tr("Eingetragen. Jetzt Claude neu starten.") :
                (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? tr("Fehler"))
        } catch { claudeMessage = tr("Fehler: \(error.localizedDescription)") }
    }

    private func connectClaudeCode() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/MacOS/notch-mcp")
        p.arguments = ["--install-claude-code"]
        try? p.run(); p.waitUntilExit()
        codeConnected = Self.claudeCodeIsConnected()
    }

    // MARK: Hilfen

    static func claudeCodeIsConnected() -> Bool {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        return ((try? String(contentsOf: u, encoding: .utf8)) ?? "").contains("notch-mcp --hook permission")
    }

    static var anyScreenWithNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } }
    static var anyScreenWithoutNotch: Bool { NSScreen.screens.contains { $0.safeAreaInsets.top == 0 } }

    static func claudeIsConnected() -> Bool {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        guard let d = try? Data(contentsOf: u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = o["mcpServers"] as? [String: Any] else { return false }
        return s["notch-island"] != nil
    }

    struct MediaApp { let id: String; let name: String }
    static var mediaApps: [MediaApp] { [MediaApp(id: Const.spotify, name: tr("Spotify")), MediaApp(id: Const.music, name: tr("Musik")),
                            MediaApp(id: Const.chrome, name: tr("Google Chrome"))] }

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
        UserDefaults.standard.set(true, forKey: "setupResume")
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// Fenster für den Assistenten
enum SetupWindow {
    private static var window: NSWindow?

    static var savedStep: SetupView.Step {
        SetupView.Step(rawValue: UserDefaults.standard.integer(forKey: "setupStep")) ?? .welcome
    }

    static func show(at step: SetupView.Step? = nil) {
        if let step, window != nil { close() }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = tr("Notch Island einrichten")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(onFinish: { SetupWindow.close() }, initialStep: step ?? savedStep))
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
        let resume = UserDefaults.standard.bool(forKey: "setupResume")
        UserDefaults.standard.set(false, forKey: "setupResume")
        if resume || !UserDefaults.standard.bool(forKey: "setupDone") { show(at: savedStep) }
    }
}
