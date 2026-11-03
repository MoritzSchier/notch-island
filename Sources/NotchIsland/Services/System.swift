import AppKit
import SwiftUI
import IOKit
import IOKit.ps
import IOBluetooth
import EventKit
import ApplicationServices

// MARK: - Bedienungshilfen (Accessibility)

enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// MARK: - Akku

final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var level: Double = 1
    @Published private(set) var isCharging = false
    @Published private(set) var onAC = false
    @Published private(set) var hasBattery = false
    @Published private(set) var minutesLeft: Int?
    @Published private(set) var details: BatteryDetails?

    /// Werte direkt vom Akku-Controller (wie coconutBattery)
    struct BatteryDetails: Equatable {
        var watts: Double          // + lädt, − entlädt
        var volts: Double
        var amps: Double
        var currentMAh: Int
        var maxMAh: Int
        var designMAh: Int
        var cycles: Int
        var temperature: Double?   // °C
        var adapterWatts: Int?
        var health: Double { designMAh > 0 ? Double(maxMAh) / Double(designMAh) : 0 }
        /// Minuten bis 80 % (nur beim Laden, solange unter 80 %)
        var minutesTo80: Int? {
            guard amps > 0.05, maxMAh > 0 else { return nil }
            let target = Double(maxMAh) * 0.8
            let missing = target - Double(currentMAh)
            guard missing > 0 else { return nil }
            return Int((missing / (amps * 1000) * 60).rounded(.up))
        }
        var aboveOrAt80: Bool { maxMAh > 0 && Double(currentMAh) >= Double(maxMAh) * 0.8 }
    }

    private var detailTimer: Timer?
    private var source: CFRunLoopSource?
    private var started = false
    private var warned: Set<Int> = []

    func start() {
        read()
        readDetails()
        detailTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.readDetails() }
        started = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.read() }
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    var statusText: String {
        if !hasBattery { return "Netzbetrieb" }
        if onAC && level >= 0.995 { return "Vollständig geladen" }
        if onAC { return isCharging ? (minutesLeft.map { "Lädt · voll in \(Self.hm($0))" } ?? "Lädt") : "Am Netzteil, lädt nicht" }
        return minutesLeft.map { "Noch etwa \(Self.hm($0))" } ?? "Akkubetrieb"
    }

    func readDetails() {
        DispatchQueue.global(qos: .utility).async {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            guard service != 0 else { return }
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any] else { return }
            let bd = d["BatteryData"] as? [String: Any] ?? [:]
            func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue ?? (bd[k] as? NSNumber)?.intValue }
            func bdInt(_ k: String) -> Int? { (bd[k] as? NSNumber)?.intValue }
            let mv = Double(int("Voltage") ?? int("AppleRawBatteryVoltage") ?? 0)
            let rawAmp = (d["InstantAmperage"] as? NSNumber ?? d["Amperage"] as? NSNumber)?.int64Value ?? 0
            let ma = Double(Int16(truncatingIfNeeded: rawAmp))
            // mAh-Werte: ältere Macs direkt, neuere (Apple Silicon) im Unterverzeichnis "BatteryData"
            let cur = int("AppleRawCurrentCapacity") ?? bdInt("RemainingCapacity") ?? 0
            let max = int("AppleRawMaxCapacity") ?? bdInt("FullChargeCapacity") ?? bdInt("NominalChargeCapacity") ?? 0
            let design = (d["DesignCapacity"] as? NSNumber)?.intValue ?? bdInt("DesignCapacity") ?? 0
            let temp = (int("Temperature") ?? int("VirtualTemperature")).flatMap { $0 > 0 ? Double($0) / 100 : nil }
            var adapter: Int?
            if let ad = d["AdapterDetails"] as? [String: Any], let w = (ad["Watts"] as? NSNumber)?.intValue, w > 0 { adapter = w }
            let det = BatteryDetails(watts: mv * ma / 1_000_000, volts: mv / 1000, amps: ma / 1000,
                                     currentMAh: cur, maxMAh: max, designMAh: design, cycles: int("CycleCount") ?? 0,
                                     temperature: temp, adapterWatts: adapter)
            DispatchQueue.main.async { if self.details != det { self.details = det } }
        }
    }

    private static func hm(_ m: Int) -> String { m >= 60 ? "\(m / 60) Std \(m % 60) Min" : "\(m) Min" }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d["Type"] as? String) == "InternalBattery" else { continue }
            let cur = d["Current Capacity"] as? Int ?? 100
            let max = d["Max Capacity"] as? Int ?? 100
            let newLevel = Double(cur) / Double(Swift.max(1, max))
            let newAC = (d["Power Source State"] as? String) == "AC Power"
            let charging = d["Is Charging"] as? Bool ?? false
            let tte = d["Time to Empty"] as? Int ?? -1
            let ttf = d["Time to Full Charge"] as? Int ?? -1
            let wasAC = onAC
            hasBattery = true
            level = newLevel
            isCharging = charging
            onAC = newAC
            let m = newAC ? ttf : tte
            minutesLeft = m > 0 ? m : nil

            guard started, Prefs.on(Prefs.showBattery) else { continue }
            if newAC && !wasAC {
                warned = []
                IslandModel.shared.show(Toast(symbol: "bolt.fill", tint: .green, title: "Lädt",
                                              subtitle: newLevel >= 0.995 ? "Vollständig geladen" : nil,
                                              trailing: .battery(newLevel, charging: true), duration: 3))
            } else if !newAC {
                for threshold in [20, 10, 5] where Int((newLevel * 100).rounded()) <= threshold && !warned.contains(threshold) {
                    warned.insert(threshold)
                    IslandModel.shared.show(Toast(symbol: "battery.25", tint: .red, title: "Akku schwach",
                                                  subtitle: "Noch \(threshold) % verbleibend",
                                                  trailing: .battery(newLevel, charging: false), duration: 5))
                    break
                }
            }
        }
    }
}

// MARK: - Bluetooth (AirPods & Co.)

struct BTDevice: Identifiable, Equatable {
    var id: String
    var name: String
    var battery: Int?
    var symbol: String
}

final class BluetoothMonitor: NSObject, ObservableObject {
    static let shared = BluetoothMonitor()
    @Published private(set) var devices: [BTDevice] = []
    private var connectNote: IOBluetoothUserNotification?
    private var startedAt = Date()

    func start() {
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
        refresh()
    }

    /// Wann pro Gerät zuletzt ein Hinweis kam bzw. es getrennt wurde – gegen Mehrfach-Meldungen
    /// (AirPods melden sich oft 3× hintereinander, manche Geräte verbinden sich alle paar Minuten kurz neu).
    private var lastShown: [String: Date] = [:]
    private var lastDisconnect: [String: Date] = [:]

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        refresh()
        guard Date().timeIntervalSince(startedAt) > 4, Prefs.on(Prefs.showBluetooth) else { return }
        // Geräte ohne Namen (z. B. Hintergrund-Verbindungen) nicht melden
        guard let name = device.name, !name.isEmpty else { return }
        let id = device.addressString ?? name
        let now = Date()
        // Gleiches Gerät: höchstens alle 10 Minuten, und nur wenn es wirklich länger als 30 s weg war
        if let l = lastShown[id], now.timeIntervalSince(l) < 600 { return }
        if let d = lastDisconnect[id], now.timeIntervalSince(d) < 30 { return }
        lastShown[id] = now
        // Akkustand braucht kurz, bis er gemeldet wird
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, device.isConnected() else { return }
            self.refresh()
            let d = Self.make(device)
            IslandModel.shared.show(Toast(symbol: d.symbol, tint: .white, title: d.name, subtitle: "Verbunden",
                                          trailing: d.battery.map { .ring(Double($0) / 100) } ?? .check, duration: 3.5))
        }
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        lastDisconnect[device.addressString ?? device.name ?? "?"] = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
    }

    func refresh() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let list = paired.filter { $0.isConnected() }.map(Self.make)
        if list != devices { devices = list }
    }

    static func make(_ d: IOBluetoothDevice) -> BTDevice {
        let name = d.name ?? "Bluetooth-Gerät"
        return BTDevice(id: d.addressString ?? name, name: name, battery: battery(d), symbol: symbol(for: name))
    }

    private static func battery(_ d: IOBluetoothDevice) -> Int? {
        for key in ["batteryPercentCombined", "batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight"] {
            if d.responds(to: NSSelectorFromString(key)), let n = d.value(forKey: key) as? NSNumber, n.intValue > 0 {
                return n.intValue
            }
        }
        return nil
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("keyboard") || n.contains("tastatur") { return "keyboard" }
        if n.contains("mouse") || n.contains("maus") { return "magicmouse" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller.fill" }
        if n.contains("speaker") || n.contains("box") || n.contains("boom") || n.contains("jbl") { return "hifispeaker.fill" }
        return "headphones"
    }
}

// MARK: - Kalender

final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    let store = EKEventStore()
    @Published private(set) var authorized = false
    @Published private(set) var events: [EKEvent] = []
    private var timer: Timer?

    func start() {
        guard Prefs.on(Prefs.showCalendar) else { return }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess {
            authorized = true
            refresh()
        } else if status == .notDetermined {
            requestAccess()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.authorized = granted
                self.refresh()
                if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func refresh() {
        guard authorized else { return }
        let now = Date()
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(36 * 3600), calendars: nil)
        let list = store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        events = list
    }

    var next: EKEvent? { events.first }

    var soon: EKEvent? {
        guard let e = next else { return nil }
        let dt = e.startDate.timeIntervalSinceNow
        return (dt < 15 * 60 && dt > -5 * 60) ? e : nil
    }

    static func shortCountdown(to d: Date, now: Date) -> String {
        let m = Int((d.timeIntervalSince(now) / 60).rounded(.up))
        if m <= 0 { return "Jetzt" }
        return "in \(m) Min"
    }

    static func describe(_ e: EKEvent, now: Date) -> String {
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "de_DE")
        tf.dateFormat = "HH:mm"
        let start = tf.string(from: e.startDate), end = tf.string(from: e.endDate)
        if e.startDate <= now { return "Läuft · bis \(end)" }
        let cal = Calendar.current
        let day = cal.isDateInToday(e.startDate) ? "Heute" : (cal.isDateInTomorrow(e.startDate) ? "Morgen" : "")
        let mins = Int(e.startDate.timeIntervalSince(now) / 60)
        let rel = mins < 60 ? " · in \(Swift.max(1, mins)) Min" : ""
        return "\(day) \(start)–\(end)\(rel)".trimmingCharacters(in: .whitespaces)
    }

    static func joinURL(_ e: EKEvent) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "whereby.com", "discord.gg"]
        let texts = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for t in texts {
            for m in det.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                if let u = m.url, let h = u.host, hosts.contains(where: { h.contains($0) }) { return u }
            }
        }
        return nil
    }
}

// MARK: - Downloads

final class DownloadMonitor: ObservableObject {
    struct DL: Identifiable, Equatable {
        let id: String
        let name: String
        var bytes: Int64
        var total: Int64?
        var progress: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(bytes) / Double(total))
        }
    }

    static let shared = DownloadMonitor()
    @Published private(set) var active: [DL] = []
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private var timer: Timer?
    private let queue = DispatchQueue(label: "notch.downloads", qos: .utility)
    private var busy = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard Prefs.on(Prefs.showDownloads) else {
            if !active.isEmpty { active = [] }
            return
        }
        guard !busy else { return }
        busy = true
        let dir = self.dir
        queue.async { [weak self] in
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            var found: [DL] = []
            for n in names where !n.hasPrefix(".") {
                let url = dir.appendingPathComponent(n)
                switch url.pathExtension.lowercased() {
                case "crdownload", "part", "partial":
                    let attrs = try? fm.attributesOfItem(atPath: url.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    var name = url.deletingPathExtension().lastPathComponent
                    if name.hasPrefix("Unconfirmed ") { name = "Download" }
                    found.append(DL(id: url.path, name: name, bytes: size, total: nil))
                case "download":
                    let plist = url.appendingPathComponent("Info.plist")
                    var bytes: Int64 = 0
                    var total: Int64?
                    var name = url.deletingPathExtension().lastPathComponent
                    if let d = NSDictionary(contentsOf: plist) {
                        bytes = (d["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
                        total = (d["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value
                        if let p = d["DownloadEntryPath"] as? String { name = (p as NSString).lastPathComponent }
                    }
                    found.append(DL(id: url.path, name: name, bytes: bytes, total: total))
                default:
                    continue
                }
            }
            DispatchQueue.main.async { self?.apply(found) }
        }
    }

    private func apply(_ found: [DL]) {
        busy = false
        let finished = active.filter { old in !found.contains { $0.id == old.id } }
        if found != active { active = found }
        for f in finished {
            let final = dir.appendingPathComponent(f.name)
            guard FileManager.default.fileExists(atPath: final.path) else { continue }
            if Prefs.on(Prefs.downloadsToShelf) { ShelfStore.shared.importCopies([final]) }
            IslandModel.shared.show(Toast(image: NSWorkspace.shared.icon(forFile: final.path), tint: .blue,
                                          title: "Download abgeschlossen", subtitle: f.name, trailing: .check, duration: 4,
                                          onTap: { NSWorkspace.shared.activateFileViewerSelecting([final]) }))
        }
    }
}

// MARK: - Zwischenablage-Verlauf

final class ClipboardHistory: ObservableObject {
    struct Clip: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var date: Date
    }

    static let shared = ClipboardHistory()
    @Published private(set) var items: [Clip] = []
    private var lastCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard Prefs.on(Prefs.clipboardHistory) else { return }
        let types = pb.types ?? []
        if types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let i = items.firstIndex(where: { $0.text == s }) {
            var c = items.remove(at: i)
            c.date = Date()
            items.insert(c, at: 0)
        } else {
            items.insert(Clip(text: s, date: Date()), at: 0)
        }
        if items.count > 30 { items.removeLast(items.count - 30) }
    }

    /// Text in die Zwischenablage legen, ohne einen neuen Verlaufseintrag zu erzeugen.
    func copy(_ c: Clip) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.text, forType: .string)
        lastCount = pb.changeCount
    }

    func update(_ id: UUID, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items[i].text = text
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func clear() { items.removeAll() }
}

// MARK: - Mitteilungs-Badges im Dock (WhatsApp, Discord, Mail …)

final class DockBadgeMonitor: ObservableObject {
    struct Badge: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let label: String
    }

    static let shared = DockBadgeMonitor()
    @Published private(set) var badges: [Badge] = []
    private var last: [String: Int] = [:]
    private var first = true
    private var timer: Timer?
    private let queue = DispatchQueue(label: "notch.badges", qos: .utility)

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard Prefs.on(Prefs.showBadges), AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let pid = dock.processIdentifier
        queue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            var result: [Badge] = []
            for list in AX.children(app) where AX.string(list, kAXRoleAttribute as String) == "AXList" {
                for item in AX.children(list) {
                    guard let label = AX.string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                    var name = AX.string(item, kAXTitleAttribute as String) ?? ""
                    var bundle = name
                    if let u = AX.attr(item, "AXURL") as? URL, let b = Bundle(url: u)?.bundleIdentifier { bundle = b }
                    if name.isEmpty || AppInfo.looksLikeBundleID(name) { name = AppInfo.humanize(bundle) }
                    // Badge-Text säubern (unsichtbare Steuerzeichen entfernen)
                    let clean = label.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
                    result.append(Badge(bundleID: bundle, name: name, label: String(String.UnicodeScalarView(clean))))
                }
            }
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    private func apply(_ result: [Badge]) {
        if result != badges { badges = result }
        var counts: [String: Int] = [:]
        for b in result { counts[b.bundleID] = Int(b.label) ?? 1 }
        defer { last = counts; first = false }
        guard !first else { return }
        for b in result {
            let now = counts[b.bundleID] ?? 0
            let before = last[b.bundleID] ?? 0
            guard now > before, AppInfo.frontmost != b.bundleID else { continue }
            // Schon als Banner mit Absender/Text gezeigt → nicht noch einmal
            if NotificationBannerMonitor.shared.shownRecently(b.bundleID) { continue }
            let diff = now - before
            IslandModel.shared.show(Toast(image: AppInfo.icon(b.bundleID), tint: .red, title: b.name,
                                          subtitle: diff == 1 ? "Neue Mitteilung" : "\(diff) neue Mitteilungen",
                                          trailing: .text(b.label), duration: 4,
                                          onTap: { AppInfo.activate(b.bundleID) }))
        }
    }
}
