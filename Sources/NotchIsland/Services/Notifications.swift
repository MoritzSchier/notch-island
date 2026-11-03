import SQLite3
import AppKit
import SwiftUI
import ApplicationServices

/// Liest Mitteilungs-Banner (WhatsApp, Mail, Chrome, Nachrichten …) über die Bedienungshilfen aus der
/// macOS-Mitteilungszentrale und zeigt sie mit Absender und Text in der Insel.
/// Braucht nur die Bedienungshilfen-Freigabe – keine Datenbank, kein Festplattenvollzugriff.
/// Ein Klick auf den Hinweis öffnet die Mitteilung (wie ein Klick auf das Banner).
final class NotificationBannerMonitor {
    static let shared = NotificationBannerMonitor()
    static let ncBundle = "com.apple.notificationcenterui"

    struct Banner {
        let key: String
        let bundleID: String?
        let appName: String?
        let title: String
        let body: String?
        let element: AXUIElement
    }

    private let queue = DispatchQueue(label: "notch.banners", qos: .userInitiated)
    private var timer: Timer?
    private var busy = false
    private var seen: [String: Date] = [:]
    /// Zuletzt per Banner gemeldete Apps – der Dock-Badge-Hinweis wird dann übersprungen.
    private(set) var recentApps: [String: Date] = [:]
    private var manualAX = false

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Wurde für diese App gerade ein Banner gezeigt?
    func shownRecently(_ bundleID: String, within s: TimeInterval = 20) -> Bool {
        guard let d = recentApps[bundleID] else { return false }
        return Date().timeIntervalSince(d) < s
    }

    private func poll() {
        guard Prefs.on(Prefs.showBanners), !busy, AXIsProcessTrusted(),
              let nc = NSRunningApplication.runningApplications(withBundleIdentifier: Self.ncBundle).first else { return }
        busy = true
        let pid = nc.processIdentifier
        queue.async { [weak self] in
            guard let self else { return }
            let found = Self.scan(pid: pid)
            DispatchQueue.main.async {
                self.busy = false
                self.apply(found)
            }
        }
    }

    private func apply(_ banners: [Banner]) {
        for b in banners {
            deliver(bundleID: b.bundleID, appName: b.appName, title: b.title, subtitle: nil, body: b.body, element: b.element)
        }
    }

    /// Gemeinsamer Eingang für Banner und Datenbank – doppelte Meldungen werden zusammengefasst.
    func deliver(bundleID: String?, appName: String? = nil, title rawTitle: String, subtitle: String?, body: String?, element: AXUIElement?) {
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 120 }
        let text = [subtitle, body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let key = (bundleID ?? "") + "|" + rawTitle + "|" + String(text.prefix(60))
        guard seen[key] == nil else { return }
        seen[key] = now
        if let id = bundleID, id == Const.bundleID || AppInfo.frontmost == id { return }
        if let id = bundleID { recentApps[id] = now }
        let name = appName ?? bundleID.map { AppInfo.name($0) } ?? "Mitteilung"
        var sender = rawTitle.isEmpty ? name : rawTitle
        var msg = text
        if sender == name, !msg.isEmpty, subtitle == nil, let b = msg.components(separatedBy: " · ").first, b.count < 40, msg.contains(" · ") {
            sender = b; msg = String(msg.dropFirst(b.count + 3))
        }
        DevBridge.log("Mitteilung: \(bundleID ?? "?") · \(sender) · \(msg)")
        let model = IslandModel.shared
        let tap: () -> Void = {
            // Banner "anklicken" → öffnet den Chat/die Mail direkt; sonst die App
            if let el = element, AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return }
            if let bundleID { AppInfo.activate(bundleID) }
        }
        // Wie am iPhone: weitere Mitteilungen derselben App stapeln sich auf der aktuellen
        var info = MessageInfo(bundleID: bundleID, appName: name, sender: String(sender.prefix(60)), text: String(msg.prefix(220)))
        var toast = Toast(symbol: "bell.badge.fill", tint: .red, title: info.sender, subtitle: msg, duration: 6, onTap: tap)
        if let cur = model.toast, let m = cur.message, m.bundleID == bundleID {
            info.count = m.count + 1
            toast.id = cur.id
        }
        toast.message = info
        model.show(toast)
    }

    // MARK: Auslesen

    private static func scan(pid: pid_t) -> [Banner] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let windows = AX.attr(app, kAXWindowsAttribute as String) as? [AXUIElement], !windows.isEmpty else { return [] }
        var result: [Banner] = []
        // Desktop-Widgets (Wetter, Erinnerungen …) gehören auch zur Mitteilungszentrale – überspringen
        var stack = windows.filter { !isWidgetWindow($0) }
        var visited = 0
        while let el = stack.popLast(), visited < 600 {
            visited += 1
            if isBanner(el) {
                if let b = parse(el) { result.append(b) }
                continue
            }
            stack.append(contentsOf: AX.children(el))
        }
        return result
    }

    private static func isWidgetWindow(_ w: AXUIElement) -> Bool {
        for c in AX.children(w) {
            for g in AX.children(c) {
                if let id = AX.string(g, "AXIdentifier"), id.hasPrefix("widget") { return true }
            }
        }
        return false
    }

    private static func isBanner(_ el: AXUIElement) -> Bool {
        let sub = AX.string(el, kAXSubroleAttribute as String) ?? ""
        if sub.contains("NotificationCenterBanner") || sub.contains("NotificationCenterAlert") { return true }
        return stackingID(el) != nil && AX.string(el, kAXRoleAttribute as String) == (kAXGroupRole as String)
    }

    /// z. B. "bundleIdentifier=net.whatsapp.WhatsApp,threadIdentifier=…"
    private static func stackingID(_ el: AXUIElement) -> String? {
        AX.string(el, "AXStackingIdentifier")
    }

    private static func parse(_ el: AXUIElement) -> Banner? {
        var texts: [String] = []
        var stack = [el]
        var visited = 0
        while let e = stack.popLast(), visited < 80 {
            visited += 1
            if AX.string(e, kAXRoleAttribute as String) == (kAXStaticTextRole as String),
               let v = AX.string(e, kAXValueAttribute as String) {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty && !texts.contains(t) { texts.append(t) }
            }
            stack.append(contentsOf: AX.children(e).reversed())
        }
        let desc = AX.string(el, kAXDescriptionAttribute as String) ?? ""
        if texts.isEmpty && !desc.isEmpty {
            texts = desc.components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        guard !texts.isEmpty else { return nil }

        var bundle: String?
        if let s = stackingID(el) {
            for part in s.components(separatedBy: ",") where part.hasPrefix("bundleIdentifier=") {
                bundle = String(part.dropFirst("bundleIdentifier=".count))
            }
        }
        var appName = bundle.map { AppInfo.name($0) }
        if bundle == nil, let first = texts.first,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == first }) {
            bundle = app.bundleIdentifier
            appName = first
        }
        // Zeitangaben ("jetzt", "vor 2 Min.") und den App-Namen aus dem Text entfernen
        let filtered = texts.filter { t in
            let l = t.lowercased()
            return !(l == "jetzt" || l == "now" || l.hasPrefix("vor ") || l.hasSuffix(" ago")) && t != appName
        }
        let parts = filtered.isEmpty ? texts : filtered
        let title = String(parts[0].prefix(80))
        let body = parts.count > 1 ? String(parts.dropFirst().joined(separator: " · ").prefix(160)) : nil
        let key = (bundle ?? "") + "|" + texts.joined(separator: "|")
        return Banner(key: key, bundleID: bundle, appName: appName, title: title, body: body, element: el)
    }

    /// Entwicklungshilfe: Baum der Mitteilungszentrale als Text
    static func dump() -> String {
        guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: ncBundle).first else { return "keine Mitteilungszentrale" }
        return AXDump.tree(AXUIElementCreateApplication(nc.processIdentifier), maxNodes: 400)
    }
}

/// Bedienungshilfen-Baum als lesbarer Text (nur für Entwicklung/Fehlersuche).
enum AXDump {
    static func tree(_ root: AXUIElement, maxNodes: Int = 1500) -> String {
        var out: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var n = 0
        while let (el, depth) = stack.popLast(), n < maxNodes {
            n += 1
            var parts = [AX.string(el, kAXRoleAttribute as String) ?? "?"]
            if let s = AX.string(el, kAXSubroleAttribute as String) { parts.append("sub=\(s)") }
            for (k, a) in [("t", kAXTitleAttribute as String), ("d", kAXDescriptionAttribute as String),
                           ("v", kAXValueAttribute as String), ("id", "AXIdentifier"), ("dom", "AXDOMClassList"),
                           ("stack", "AXStackingIdentifier")] {
                if let v = AX.attr(el, a) {
                    let s: String
                    if let str = v as? String { s = str } else if let arr = v as? [String] { s = arr.joined(separator: ".") } else { continue }
                    if !s.isEmpty { parts.append("\(k)=\"\(s.prefix(90).replacingOccurrences(of: "\n", with: "⏎"))\"") }
                }
            }
            out.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            for c in AX.children(el).reversed() { stack.append((c, depth + 1)) }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Mitteilungs-Datenbank (optional, braucht „Festplattenvollzugriff“)


/// Liest neue Mitteilungen direkt aus der Datenbank der Mitteilungszentrale.
/// Vorteil gegenüber den Bannern: funktioniert auch im Fokus-/„Nicht stören“-Modus und
/// wenn eine App nur Badges oder die Mitteilungszentrale nutzt. Nur aktiv, wenn der Nutzer
/// Notch Island den Festplattenvollzugriff gibt – sonst passiert hier nichts.
final class NotificationDBMonitor {
    static let shared = NotificationDBMonitor()

    private var timer: Timer?
    private var lastRec: Int64 = -1
    private let queue = DispatchQueue(label: "notch.notedb", qos: .utility)
    private(set) var available = false

    static var candidatePaths: [String] {
        var p = [NSHomeDirectory() + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 {
            p.append(String(cString: buf) + "com.apple.notificationcenter/db2/db")
        }
        return p
    }

    static var path: String? {
        candidatePaths.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        guard Prefs.on(Prefs.showBanners), let path = Self.path else {
            available = false
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let rows = Self.read(path: path, after: self.lastRec)
            DispatchQueue.main.async {
                let wasAvailable = self.available
                self.available = rows != nil
                guard let rows else { return }
                if !rows.isEmpty { DevBridge.log("Mitteilungs-DB: \(rows.count) neu (nach \(self.lastRec))") }
                if self.lastRec < 0 || !wasAvailable {
                    // Beim Start nur den Stand merken, alte Mitteilungen nicht zeigen
                    self.lastRec = rows.map(\.rec).max() ?? max(self.lastRec, 0)
                    return
                }
                for r in rows.sorted(by: { $0.rec < $1.rec }) {
                    self.lastRec = max(self.lastRec, r.rec)
                    NotificationBannerMonitor.shared.deliver(bundleID: Self.properBundleID(r.app), title: r.title, subtitle: r.subtitle, body: r.body, element: nil)
                }
            }
        }
    }

    struct Row { let rec: Int64; let app: String; let title: String; let subtitle: String?; let body: String? }

    /// nil = Datenbank nicht lesbar
    private static func read(path: String, after: Int64) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let sql = after < 0
            ? "SELECT record.rec_id, app.identifier, record.data FROM record JOIN app ON app.app_id = record.app_id ORDER BY record.rec_id DESC LIMIT 1"
            : "SELECT record.rec_id, app.identifier, record.data FROM record JOIN app ON app.app_id = record.app_id WHERE record.rec_id > ? ORDER BY record.rec_id LIMIT 20"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        if after >= 0 { sqlite3_bind_int64(st, 1, after) }
        var rows: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let rec = sqlite3_column_int64(st, 0)
            let app = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            var title = "", sub: String?, body: String?
            if let blob = sqlite3_column_blob(st, 2) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(st, 2)))
                if let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let req = pl["req"] as? [String: Any] {
                    title = (req["titl"] as? String) ?? ""
                    sub = req["subt"] as? String
                    body = req["body"] as? String
                }
            }
            rows.append(Row(rec: rec, app: app, title: title, subtitle: sub, body: body))
        }
        return rows
    }

    /// Die Datenbank speichert Bundle-IDs klein geschrieben – echte Schreibweise über LaunchServices holen
    private static var idCache: [String: String] = [:]
    static func properBundleID(_ s: String) -> String {
        if let c = idCache[s] { return c }
        var r = s
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s), let id = Bundle(url: u)?.bundleIdentifier { r = id }
        idCache[s] = r
        return r
    }

    /// Entwicklung: Tabellen und letzte Einträge beschreiben
    static func debugDescription() -> String {
        guard let path else { return "keine DB" }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "open fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))" }
        defer { sqlite3_close(db) }
        var out: [String] = []
        func q(_ sql: String, _ cols: Int) {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { out.append("ERR \(sql): \(String(cString: sqlite3_errmsg(db)))"); return }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW {
                var row: [String] = []
                for i in 0..<Int32(cols) {
                    if sqlite3_column_type(st, i) == SQLITE_BLOB {
                        let d = Data(bytes: sqlite3_column_blob(st, i), count: Int(sqlite3_column_bytes(st, i)))
                        if let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                            let req = pl["req"] as? [String: Any] ?? [:]
                            row.append("keys=\(pl.keys.sorted()) req=\(req.keys.sorted()) titl=\(req["titl"] ?? "-")")
                        } else { row.append("blob \(d.count)") }
                    } else {
                        row.append(sqlite3_column_text(st, i).map { String(cString: $0) } ?? "nil")
                    }
                }
                out.append(row.joined(separator: " | "))
            }
        }
        q("SELECT name FROM sqlite_master WHERE type='table'", 1)
        q("SELECT record.rec_id, app.identifier, record.delivered_date, record.data FROM record JOIN app ON app.app_id = record.app_id ORDER BY record.rec_id DESC LIMIT 3", 4)
        return out.joined(separator: "\n")
    }

    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }
}
