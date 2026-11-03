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
            notePreview: true, noteDuration: 6.0, noteStack: true,
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

    static let sounds = ["Glass", "Ping", "Hero", "Funk", "Submarine", "Purr", "Pop", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Tink", "Basso"]
}

/// Einstellungen › Tabs: Sichtbarkeit + aufklappbare Optionen je Tab
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
        Form {
            Section {
                ForEach(model.orderedTabsAll) { t in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(t) }, set: { if $0 { expanded.insert(t) } else { expanded.remove(t) } })) {
                        options(for: t).padding(.leading, 4).padding(.vertical, 2)
                    } label: {
                        Toggle(isOn: Binding(get: { model.isVisible(t) }, set: { model.setVisible(t, $0) })) {
                            Label(t.title, systemImage: t.icon)
                        }
                        .disabled(t == .home)
                    }
                }
            } header: {
                Text("Schalter = Tab anzeigen · Pfeil = Optionen")
            } footer: {
                Text("„Start“ ist immer da. Die Reihenfolge änderst du direkt in der Insel per Drag & Drop.")
            }
            Section {
                Button("Reihenfolge zurücksetzen") { model.resetTabOrder() }
            }
        }
        .formStyle(.grouped)
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
    @AppStorage(Prefs.showBanners) private var showBanners = true
    @AppStorage(Prefs.showBadges) private var showBadges = true
    @AppStorage(Opt.notePreview) private var preview = true
    @AppStorage(Opt.noteDuration) private var duration = 6.0
    @AppStorage(Opt.noteStack) private var stack = true
    @State private var muted = Opt.mutedApps
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
                if Opt.seenApps.isEmpty {
                    Text("Sobald Mitteilungen kommen, kannst du hier einzelne Apps stummschalten.").foregroundStyle(.secondary)
                }
                ForEach(Opt.seenApps, id: \.self) { id in
                    Toggle(isOn: Binding(get: { !muted.contains(id) }, set: { on in
                        if on { muted.remove(id) } else { muted.insert(id) }
                        Opt.mutedApps = muted
                    })) {
                        HStack {
                            if let i = AppInfo.icon(id) { Image(nsImage: i).resizable().frame(width: 18, height: 18) }
                            Text(AppInfo.name(id))
                        }
                    }
                }
            } header: { Text("Apps") }
        }
        .formStyle(.grouped)
    }
}
