import SwiftUI
import AppKit

/// Feineinstellungen pro Tab und für Mitteilungen (Schlüssel in UserDefaults).
enum Opt {
    // Start
    static let homeMedia = "opt.home.media"
    static let homeVolume = "opt.home.volume"
    static let homeUpNext = "opt.home.upnext"
    // Timer
    static let timerSound = "opt.timer.sound"
    static let timerAlarmSeconds = "opt.timer.alarmSeconds"
    static let timerPresets = "opt.timer.presets"
    // Claude
    static let claudeUsage = "opt.claude.usage"
    static let claudeSound = "opt.claude.sound"
    // Farben
    static let colorHex = "opt.colors.hex"
    static let colorRGB = "opt.colors.rgb"
    static let colorBin = "opt.colors.bin"
    static let colorHSL = "opt.colors.hsl"
    static let colorSwiftUI = "opt.colors.swiftui"
    // System-Widget
    static let sysBattery = "opt.sys.battery"
    static let sysBluetooth = "opt.sys.bluetooth"
    static let sysSliders = "opt.sys.sliders"
    // Ablage
    static let shelfMax = "opt.shelf.max"
    // Mitteilungen
    static let notePreview = "opt.note.preview"
    static let noteDuration = "opt.note.duration"
    static let noteStack = "opt.note.stack"
    static let noteMuted = "opt.note.muted"
    static let noteSeen = "opt.note.seenApps"
    static let noteOnlyImportant = "opt.note.onlyImportant"
    static let noteExtra = "opt.note.extraApps"
    // Insel
    static let hoverDelay = "opt.hoverDelay"

    static func register() {
        UserDefaults.standard.register(defaults: [
            homeMedia: true, homeVolume: true, homeUpNext: true,
            timerSound: "Glass", timerAlarmSeconds: 25.0, timerPresets: "1,3,5,10,15,25,45,60",
            claudeUsage: true, claudeSound: true,
            colorHex: true, colorRGB: true, colorBin: true, colorHSL: true, colorSwiftUI: true,
            sysBattery: true, sysBluetooth: true, sysSliders: true,
            shelfMax: 60,
            notePreview: true, noteDuration: 6.0, noteStack: true, noteOnlyImportant: true,
            hoverDelay: 0.16,
        ])
    }

    static func on(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func double(_ k: String) -> Double { UserDefaults.standard.double(forKey: k) }

    /// Timer-Schnellwahl in Minuten
    static var timerPresetMinutes: [Int] {
        let raw = UserDefaults.standard.string(forKey: timerPresets) ?? ""
        let v = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 && $0 <= 600 }
        return v.isEmpty ? [1, 3, 5, 10, 15, 25, 45, 60] : Array(v.prefix(8))
    }

    static var mutedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: noteMuted) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: noteMuted) }
    }

    /// Apps, von denen schon Mitteilungen kamen (für die Stummschalten-Liste)
    static var seenApps: [String] {
        get { UserDefaults.standard.stringArray(forKey: noteSeen) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(30)), forKey: noteSeen) }
    }

    static func noteSeenApp(_ id: String) {
        var s = seenApps
        if !s.contains(id) { s.append(id); seenApps = s }
    }

    /// Wichtige Apps für Mitteilungen (Nachrichten, Mail, Arbeit, Anrufe, Kalender). Alles andere nur auf Wunsch.
    struct KnownApp { let ids: [String]; let name: String; let group: String }
    static let importantApps: [KnownApp] = [
        // Nachrichten
        KnownApp(ids: ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "WhatsApp"], name: "WhatsApp", group: "Nachrichten"),
        KnownApp(ids: ["com.apple.MobileSMS"], name: "Nachrichten (iMessage/SMS)", group: "Nachrichten"),
        KnownApp(ids: ["ru.keepcoder.Telegram", "org.telegram.desktop"], name: "Telegram", group: "Nachrichten"),
        KnownApp(ids: ["org.whispersystems.signal-desktop"], name: "Signal", group: "Nachrichten"),
        KnownApp(ids: ["ch.threema.threema-desktop", "ch.threema.work-desktop"], name: "Threema", group: "Nachrichten"),
        KnownApp(ids: ["com.facebook.archon", "com.facebook.archon.developerID"], name: "Messenger", group: "Nachrichten"),
        KnownApp(ids: ["com.hnc.Discord"], name: "Discord", group: "Nachrichten"),
        // Arbeit
        KnownApp(ids: ["com.tinyspeck.slackmacgap"], name: "Slack", group: "Arbeit"),
        KnownApp(ids: ["com.microsoft.teams2", "com.microsoft.teams"], name: "Microsoft Teams", group: "Arbeit"),
        KnownApp(ids: ["us.zoom.xos"], name: "Zoom", group: "Arbeit"),
        KnownApp(ids: ["Cisco-Systems.Spark"], name: "Webex", group: "Arbeit"),
        KnownApp(ids: ["com.google.Chrome"], name: "Google Chrome (Gmail, Meet …)", group: "Arbeit"),
        KnownApp(ids: ["com.apple.Safari"], name: "Safari (Web-Mitteilungen)", group: "Arbeit"),
        // Mail
        KnownApp(ids: ["com.apple.mail"], name: "Mail", group: "Mail"),
        KnownApp(ids: ["com.microsoft.Outlook"], name: "Outlook", group: "Mail"),
        KnownApp(ids: ["com.readdle.SparkDesktop", "com.readdle.smartemail-Mac"], name: "Spark", group: "Mail"),
        KnownApp(ids: ["it.bloop.airmail2"], name: "Airmail", group: "Mail"),
        KnownApp(ids: ["org.mozilla.thunderbird"], name: "Thunderbird", group: "Mail"),
        KnownApp(ids: ["com.mimestream.Mimestream"], name: "Mimestream", group: "Mail"),
        KnownApp(ids: ["io.canarymail.mac", "io.canarymail.android"], name: "Canary Mail", group: "Mail"),
        KnownApp(ids: ["ch.protonmail.desktop"], name: "Proton Mail", group: "Mail"),
        KnownApp(ids: ["com.superhuman.electron"], name: "Superhuman", group: "Mail"),
        // Anrufe & Termine
        KnownApp(ids: ["com.apple.FaceTime"], name: "FaceTime", group: "Anrufe & Termine"),
        KnownApp(ids: ["com.apple.iCal"], name: "Kalender", group: "Anrufe & Termine"),
        KnownApp(ids: ["com.flexibits.fantastical2.mac"], name: "Fantastical", group: "Anrufe & Termine"),
        KnownApp(ids: ["com.apple.reminders"], name: "Erinnerungen", group: "Anrufe & Termine"),
    ]

    static func knownApp(for id: String) -> KnownApp? {
        let l = id.lowercased()
        return importantApps.first { $0.ids.contains { $0.lowercased() == l } }
    }

    static var extraApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: noteExtra) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: noteExtra) }
    }

    /// Soll eine Mitteilung dieser App in der Insel erscheinen?
    static func notificationsAllowed(_ id: String) -> Bool {
        let l = id.lowercased()
        if mutedApps.contains(where: { $0.lowercased() == l }) { return false }
        if knownApp(for: id) != nil { return true }
        if extraApps.contains(where: { $0.lowercased() == l }) { return true }
        return !on(noteOnlyImportant)
    }

    static let sounds = ["Glass", "Ping", "Hero", "Funk", "Submarine", "Purr", "Pop", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Tink", "Basso"]
}

/// Einstellungen › Tabs: Sichtbarkeit + aufklappbare Optionen je Tab
/// Sortierbare Tab-Liste: ziehen (Drag & Drop) oder Pfeile; Schalter blendet Tabs ein/aus.
struct TabOrderList: View {
    @ObservedObject private var model = IslandModel.shared
    var showOptions: ((IslandTab) -> AnyView)? = nil
    @State private var expanded: Set<IslandTab> = []

    var body: some View {
        List {
            ForEach(model.orderedTabsAll) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Ziehen zum Sortieren")
                        Toggle(isOn: Binding(get: { model.isVisible(t) }, set: { model.setVisible(t, $0) })) {
                            Label(t.title, systemImage: t.icon)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(t == .home)
                        Spacer()
                        if showOptions != nil {
                            Button { toggleExpanded(t) } label: {
                                Label("Optionen", systemImage: expanded.contains(t) ? "chevron.up" : "slider.horizontal.3")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderless).help("Optionen für diesen Tab")
                        }
                        Button { withAnimation { model.moveTab(t, by: -1) } } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless).disabled(model.orderedTabsAll.first == t).help("Nach vorne")
                        Button { withAnimation { model.moveTab(t, by: 1) } } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless).disabled(model.orderedTabsAll.last == t).help("Nach hinten")
                    }
                    if expanded.contains(t), let opts = showOptions {
                        opts(t).padding(.leading, 30).padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 2)
            }
            .onMove { from, to in withAnimation { model.moveTabs(fromOffsets: from, toOffset: to) } }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func toggleExpanded(_ t: IslandTab) {
        withAnimation { if expanded.contains(t) { expanded.remove(t) } else { expanded.insert(t) } }
    }
}

struct TabOptionsView: View {
    @ObservedObject private var model = IslandModel.shared
    @AppStorage(Opt.homeMedia) private var homeMedia = true
    @AppStorage(Opt.homeVolume) private var homeVolume = true
    @AppStorage(Opt.homeUpNext) private var homeUpNext = true
    @AppStorage(Opt.timerSound) private var timerSound = "Glass"
    @AppStorage(Opt.timerAlarmSeconds) private var alarmSeconds = 25.0
    @AppStorage(Opt.timerPresets) private var presets = "1,3,5,10,15,25,45,60"
    @AppStorage(Opt.claudeUsage) private var claudeUsage = true
    @AppStorage(Opt.claudeSound) private var claudeSound = true
    @AppStorage(Prefs.claudePrimary) private var claudePrimary = "auto"
    @AppStorage(Opt.colorHex) private var cHex = true
    @AppStorage(Opt.colorRGB) private var cRGB = true
    @AppStorage(Opt.colorBin) private var cBin = true
    @AppStorage(Opt.colorHSL) private var cHSL = true
    @AppStorage(Opt.colorSwiftUI) private var cSwift = true
    @AppStorage(Opt.sysBattery) private var sysBattery = true
    @AppStorage(Opt.sysBluetooth) private var sysBluetooth = true
    @AppStorage(Opt.sysSliders) private var sysSliders = true
    @AppStorage(Opt.shelfMax) private var shelfMax = 60
    @AppStorage(Prefs.downloadsToShelf) private var downloadsToShelf = false
    @AppStorage(Prefs.clipboardHistory) private var clipboardHistory = true
    @State private var expanded: Set<IslandTab> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.draw.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tabs sortieren, ein- und ausblenden").font(.headline)
                    Text("Zeilen mit der Maus an ☰ nach oben oder unten ziehen – oder die Pfeile nutzen. Häkchen = Tab wird angezeigt, Regler-Symbol = Optionen. Tipp: Auch direkt in der Insel kannst du Tabs per Drag & Drop verschieben.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16)
            TabOrderList(showOptions: { t in AnyView(VStack(alignment: .leading, spacing: 6) { options(for: t) }) })
            HStack {
                Spacer()
                Button("Reihenfolge zurücksetzen") { withAnimation { model.resetTabOrder() } }
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
        }
    }

    @ViewBuilder private func options(for t: IslandTab) -> some View {
        switch t {
        case .home:
            Toggle("Musik-Karte", isOn: $homeMedia)
            Toggle("Lautstärke-Regler", isOn: $homeVolume)
            Toggle("„Als Nächstes“ (Termin & Erinnerung)", isOn: $homeUpNext)
        case .shelf:
            Stepper("Höchstens \(shelfMax) Dateien behalten", value: $shelfMax, in: 10...300, step: 10)
            Toggle("Fertige Downloads automatisch in die Ablage", isOn: $downloadsToShelf)
        case .timer:
            Picker("Alarm-Ton", selection: $timerSound) {
                ForEach(Opt.sounds, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: timerSound) { _, s in NSSound(named: s)?.play() }
            HStack {
                Text("Alarm klingelt höchstens")
                Slider(value: $alarmSeconds, in: 5...120, step: 5)
                Text("\(Int(alarmSeconds)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            TextField("Schnellwahl (Minuten, mit Komma)", text: $presets)
            Text("Bis zu 8 Werte, z. B. 1, 5, 10, 25, 60").font(.caption).foregroundStyle(.secondary)
        case .claude:
            Picker("Claude als Haupt-Tab", selection: $claudePrimary) {
                ForEach(ClaudePrimaryMode.allCases) { m in Text(m.title).tag(m.rawValue) }
            }
            Toggle("Nutzungslimit anzeigen", isOn: $claudeUsage)
            Toggle("Ton, wenn Claude fertig ist", isOn: $claudeSound)
        case .colors:
            Toggle("HEX", isOn: $cHex)
            Toggle("RGB", isOn: $cRGB)
            Toggle("Binär", isOn: $cBin)
            Toggle("HSL", isOn: $cHSL)
            Toggle("SwiftUI", isOn: $cSwift)
        case .widgets:
            Toggle("System: Akku-Details", isOn: $sysBattery)
            Toggle("System: Bluetooth-Geräte", isOn: $sysBluetooth)
            Toggle("System: Lautstärke & Helligkeit", isOn: $sysSliders)
            Toggle("Zwischenablage-Verlauf aufzeichnen", isOn: $clipboardHistory)
        case .web:
            Text("Websites fügst du direkt im Tab mit „+“ hinzu (auch den aktuellen Browser-Tab).").font(.caption).foregroundStyle(.secondary)
        case .mirror:
            Text("Die Kamera läuft nur, solange der Tab offen ist.").font(.caption).foregroundStyle(.secondary)
        case .audio:
            Text("Zeigt alle Ein- und Ausgabegeräte zum schnellen Wechseln.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Einstellungen › Mitteilungen
struct NotificationOptionsView: View {
    private func appLabel(_ id: String, _ name: String) -> some View {
        HStack {
            if let i = AppInfo.icon(id) { Image(nsImage: i).resizable().frame(width: 18, height: 18) }
            Text(name)
        }
    }

    @AppStorage(Prefs.showBanners) private var showBanners = true
    @AppStorage(Prefs.showBadges) private var showBadges = true
    @AppStorage(Opt.notePreview) private var preview = true
    @AppStorage(Opt.noteDuration) private var duration = 6.0
    @AppStorage(Opt.noteStack) private var stack = true
    @State private var muted = Opt.mutedApps
    @State private var extra = Opt.extraApps
    @AppStorage(Opt.noteOnlyImportant) private var onlyImportant = true
    @State private var fullDisk = NotificationDBMonitor.path != nil

    var body: some View {
        Form {
            Section {
                Toggle("Mitteilungen in der Insel zeigen", isOn: $showBanners)
                Toggle("Nachrichtentext anzeigen (sonst nur Absender)", isOn: $preview)
                Toggle("Mehrere Mitteilungen einer App stapeln", isOn: $stack)
                HStack {
                    Text("Anzeigedauer")
                    Slider(value: $duration, in: 3...15, step: 1)
                    Text("\(Int(duration)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                Toggle("Rote Zähler im Dock melden, wenn keine Mitteilung lesbar ist", isOn: $showBadges)
            }
            Section("Auch im Fokus-Modus") {
                HStack {
                    Label(fullDisk ? "Aktiv – Mitteilungen kommen immer an" : "Nur sichtbare Banner",
                          systemImage: fullDisk ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(fullDisk ? .green : .orange)
                    Spacer()
                    if !fullDisk { Button("Einrichten …") { SetupWindow.show(at: .notifications) } }
                }
            }
            Section {
                Toggle("Nur wichtige Apps (Nachrichten, Mail, Arbeit, Termine)", isOn: $onlyImportant)
            } footer: {
                Text("So landet keine Werbung oder App-Spam (z. B. Shopping- oder Kleinanzeigen-Apps) in der Insel. Weitere Apps kannst du unten einzeln dazuschalten.")
            }
            ForEach(["Nachrichten", "Arbeit", "Mail", "Anrufe & Termine"], id: \.self) { group in
                let apps = Opt.importantApps.filter { $0.group == group }.compactMap { k -> (String, Opt.KnownApp)? in
                    guard let id = k.ids.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }) else { return nil }
                    return (id, k)
                }
                if !apps.isEmpty {
                    Section(group) {
                        ForEach(apps, id: \.0) { id, k in
                            Toggle(isOn: Binding(get: { !muted.contains(id) }, set: { on in
                                if on { muted.remove(id) } else { muted.insert(id) }
                                Opt.mutedApps = muted
                            })) { appLabel(id, k.name) }
                        }
                    }
                }
            }
            let others = Opt.seenApps.filter { Opt.knownApp(for: $0) == nil && $0.lowercased() != Const.claudeBundle.lowercased() }
            Section {
                if others.isEmpty {
                    Text("Sobald andere Apps Mitteilungen schicken, erscheinen sie hier.").foregroundStyle(.secondary)
                }
                ForEach(others, id: \.self) { id in
                    Toggle(isOn: Binding(get: { onlyImportant ? extra.contains(id) : !muted.contains(id) }, set: { on in
                        if onlyImportant {
                            if on { extra.insert(id) } else { extra.remove(id) }
                            Opt.extraApps = extra
                        } else {
                            if on { muted.remove(id) } else { muted.insert(id) }
                            Opt.mutedApps = muted
                        }
                    })) { appLabel(id, AppInfo.name(id)) }
                }
            } header: { Text("Andere Apps") }
        }
        .formStyle(.grouped)
    }
}
