import Foundation
import SQLite3

/// Neue E-Mails direkt aus der Mail-Datenbank („Envelope Index“) lesen.
///
/// Apple Mail schickt längst nicht für jede Mail eine Mitteilung an macOS – je nach Einstellung nur für
/// „Wichtiges“, VIPs oder gar nicht, und bei manchen Accounts kommt trotz richtiger Einstellung nichts an.
/// Darum schaut die Insel selbst nach: jede neue, ungelesene Mail im Posteingang erscheint in der Notch.
/// Braucht wie die Mitteilungsliste den Festplattenvollzugriff; ohne ihn passiert hier nichts.
final class MailMonitor {
    static let shared = MailMonitor()
    static let mailBundle = "com.apple.mail"

    /// true, sobald die Mail-Datenbank gelesen werden kann – dann ignoriert die Insel Mails aus der Mitteilungsliste (sonst doppelt)
    private(set) var active = false

    private var timer: Timer?
    private var lastRow: Int64 = -1
    private var busy = false
    private var failures = 0
    private let queue = DispatchQueue(label: "notch.maildb", qos: .utility)

    /// Neueste ~/Library/Mail/V*/MailData/Envelope Index
    static var path: String? {
        let base = NSHomeDirectory() + "/Library/Mail"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        let versions = dirs.compactMap { d -> (Int, String)? in
            guard d.hasPrefix("V"), let n = Int(d.dropFirst()) else { return nil }
            return (n, "\(base)/\(d)/MailData/Envelope Index")
        }
        return versions.sorted { $0.0 > $1.0 }.map(\.1).first { FileManager.default.isReadableFile(atPath: $0) }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        guard Prefs.on(Prefs.showBanners), Opt.notificationsAllowed(Self.mailBundle), let path = Self.path else {
            active = false
            return
        }
        guard !busy else { return }
        busy = true
        let after = lastRow
        queue.async { [weak self] in
            let rows = Self.read(path: path, after: after)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard let rows else {
                    self.failures += 1
                    if self.failures >= 5 { self.active = false }
                    return
                }
                self.failures = 0
                if !self.active { DevBridge.log("Mail-Datenbank aktiv: \(path)") }
                self.active = true
                if self.lastRow < 0 {
                    self.lastRow = rows.map(\.row).max() ?? 0
                    return
                }
                for r in rows.sorted(by: { $0.row < $1.row }) where r.row > self.lastRow {
                    self.lastRow = r.row
                    guard r.isNew else { continue }
                    DevBridge.log("Neue Mail: \(r.sender) · \(r.subject)")
                    NotificationBannerMonitor.shared.deliver(bundleID: Self.mailBundle, title: r.sender,
                                                              subtitle: r.subject.isEmpty ? nil : r.subject,
                                                              body: r.summary, element: nil)
                }
            }
        }
    }

    struct Row {
        let row: Int64
        let sender: String
        let subject: String
        let summary: String?
        /// ungelesen, im Posteingang, gerade erst angekommen (keine alten Mails beim ersten Abgleich eines Accounts)
        let isNew: Bool
    }

    // MARK: Datenbank

    private static var columnCache: [String: Set<String>] = [:]

    private static func columns(_ db: OpaquePointer?, _ table: String) -> Set<String> {
        if let c = columnCache[table] { return c }
        var st: OpaquePointer?
        var out = Set<String>()
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                if let n = sqlite3_column_text(st, 1) { out.insert(String(cString: n)) }
            }
        }
        sqlite3_finalize(st)
        if !out.isEmpty { columnCache[table] = out }
        return out
    }

    /// nil = nicht lesbar
    private static func read(path: String, after: Int64) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let m = columns(db, "messages")
        guard m.contains("sender"), m.contains("subject"), m.contains("mailbox") else { return nil }
        let summaryJoin = m.contains("summary") && !columns(db, "summaries").isEmpty
        // Gmail: Mails liegen in „[Gmail]/Alle Nachrichten“, der Posteingang ist nur ein Label (Tabelle „labels“)
        let l = columns(db, "labels")
        let hasLabels = l.contains("message_id") && l.contains("mailbox_id")
        let labelInbox = hasLabels
            ? "EXISTS (SELECT 1 FROM labels l JOIN mailboxes lm ON lm.ROWID = l.mailbox_id WHERE l.message_id = m.ROWID AND LOWER(lm.url) LIKE '%/inbox')"
            : "0"
        let sql: String
        if after < 0 {
            sql = "SELECT MAX(ROWID) FROM messages"
        } else {
            sql = """
            SELECT m.ROWID, a.address, a.comment, s.subject, \(summaryJoin ? "su.summary" : "NULL"),
                   \(m.contains("read") ? "m.read" : "0"), \(m.contains("deleted") ? "m.deleted" : "0"),
                   \(m.contains("date_received") ? "m.date_received" : "0"), mb.url, \(labelInbox)
            FROM messages m
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN subjects s ON s.ROWID = m.subject
            \(summaryJoin ? "LEFT JOIN summaries su ON su.ROWID = m.summary" : "")
            LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE m.ROWID > ? ORDER BY m.ROWID LIMIT 30
            """
        }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        if after < 0 {
            guard sqlite3_step(st) == SQLITE_ROW else { return [] }
            return [Row(row: sqlite3_column_int64(st, 0), sender: "", subject: "", summary: nil, isNew: false)]
        }
        sqlite3_bind_int64(st, 1, after)
        func text(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        var rows: [Row] = []
        let now = Date().timeIntervalSince1970
        while sqlite3_step(st) == SQLITE_ROW {
            let address = text(1) ?? ""
            let name = (text(2) ?? "").trimmingCharacters(in: .whitespaces)
            let read = sqlite3_column_int64(st, 5) != 0
            let deleted = sqlite3_column_int64(st, 6) != 0
            var received = sqlite3_column_double(st, 7)
            if received > 0 && received < 1_200_000_000 { received += 978_307_200 }   // Apple-Referenzdatum → Unix
            let url = (text(8) ?? "").lowercased().removingPercentEncoding ?? ""
            let viaLabel = sqlite3_column_int64(st, 9) != 0
            let gmailAll = url.hasSuffix("/alle nachrichten") || url.hasSuffix("/all mail")
            let inbox = viaLabel || url.hasSuffix("/inbox") || url.hasSuffix("/posteingang") || (!hasLabels && gmailAll)
            let fresh = received == 0 || now - received < 15 * 60
            let summary = text(4).map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            rows.append(Row(row: sqlite3_column_int64(st, 0),
                            sender: name.isEmpty ? address : name,
                            subject: text(3) ?? "",
                            summary: summary?.isEmpty == true ? nil : summary,
                            isNew: !read && !deleted && inbox && fresh))
        }
        return rows
    }

    /// Für die Fehlersuche (DevBridge „maildb“): Tabellen, Spalten und die letzten Mails
    static func debugDescription() -> String {
        guard let path else { return "Mail-Datenbank nicht gefunden/lesbar" }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return "open fehlgeschlagen" }
        defer { sqlite3_close(db) }
        var out = ["Pfad: \(path)"]
        for t in ["messages", "addresses", "subjects", "summaries", "mailboxes", "labels"] {
            out.append("\(t): " + columns(db, t).sorted().joined(separator: ","))
        }
        var st: OpaquePointer?
        let sql = "SELECT m.ROWID, a.address, s.subject, m.read, m.date_received, mb.url FROM messages m LEFT JOIN addresses a ON a.ROWID=m.sender LEFT JOIN subjects s ON s.ROWID=m.subject LEFT JOIN mailboxes mb ON mb.ROWID=m.mailbox ORDER BY m.ROWID DESC LIMIT 4"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                let cols = (0..<6).map { i -> String in sqlite3_column_text(st, Int32(i)).map { String(cString: $0) } ?? "-" }
                out.append(cols.joined(separator: " | "))
            }
        } else {
            out.append("Abfrage fehlgeschlagen: " + String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_finalize(st)
        return out.joined(separator: "\n")
    }
}
