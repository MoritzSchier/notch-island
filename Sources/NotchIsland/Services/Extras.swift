import EventKit
import AppKit
import SwiftUI

// MARK: - Lieblings-Websites

struct WebFavorite: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: String

    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

final class WebFavorites: ObservableObject {
    static let shared = WebFavorites()
    private let key = "webFavorites"

    @Published private(set) var items: [WebFavorite] = []
    @Published var adding = false
    @Published private(set) var icons: [String: NSImage] = [:]

    static let perRow = 8
    var rows: Int { adding ? 2 : Int(ceil(Double(items.count + 1) / Double(Self.perRow))) }

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([WebFavorite].self, from: d) {
            items = list
        } else {
            items = [
                WebFavorite(title: "Claude", url: "https://claude.ai"),
                WebFavorite(title: "YouTube", url: "https://www.youtube.com"),
                WebFavorite(title: "ChatGPT", url: "https://chatgpt.com"),
                WebFavorite(title: "Google", url: "https://www.google.com"),
            ]
        }
        items.forEach(loadIcon)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u.absoluteString
    }

    static func defaultTitle(for url: String) -> String {
        let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
        let base = host.components(separatedBy: ".").dropLast().last ?? host
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    @discardableResult
    func add(_ raw: String, title: String? = nil) -> Bool {
        guard let u = Self.normalize(raw) else { return false }
        let t = (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : String($0.prefix(24)) } ?? Self.defaultTitle(for: u)
        let f = WebFavorite(title: t, url: u)
        items.append(f)
        save()
        loadIcon(f)
        return true
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(items.count - 1, i + delta))
        items.swapAt(i, j)
        save()
    }

    func open(_ f: WebFavorite) {
        if let u = URL(string: f.url) { NSWorkspace.shared.open(u) }
    }

    /// Übernimmt die gerade geöffnete Seite aus Chrome oder Safari.
    func addCurrentBrowserTab() {
        DispatchQueue.global(qos: .userInitiated).async {
            var scripts: [String] = []
            if AppInfo.isRunning(Const.chrome) {
                scripts.append("tell application id \"com.google.Chrome\" to return {URL of active tab of front window, title of active tab of front window}")
            }
            if AppInfo.isRunning("com.apple.Safari") {
                scripts.append("tell application id \"com.apple.Safari\" to return {URL of current tab of front window, name of current tab of front window}")
            }
            for src in scripts {
                var err: NSDictionary?
                guard let d = NSAppleScript(source: src)?.executeAndReturnError(&err), err == nil, d.numberOfItems >= 2,
                      let url = d.atIndex(1)?.stringValue else { continue }
                let title = d.atIndex(2)?.stringValue
                DispatchQueue.main.async {
                    let short = title.map { MediaController.cleanTitle($0).components(separatedBy: " - ").first ?? $0 }
                    if self.add(url, title: short) {
                        IslandModel.shared.show(Toast(symbol: "globe", tint: .blue, title: "Website hinzugefügt", subtitle: short ?? url, duration: 2))
                    }
                }
                return
            }
            showToast(Toast(symbol: "globe", tint: .orange, title: "Kein Browser-Tab gefunden", subtitle: "Chrome oder Safari öffnen", duration: 2.5))
        }
    }

    private func loadIcon(_ f: WebFavorite) {
        let host = f.host
        guard icons[host] == nil, let u = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.icons[host] = img }
        }.resume()
    }
}

// MARK: - Erinnerungen (Apple Erinnerungen: fällige Aufgaben & Fristen)

final class RemindersService: ObservableObject {
    struct Due: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date
        let list: String?
        let color: Color
        let flagged: Bool
    }

    static let shared = RemindersService()
    static let appBundle = "com.apple.reminders"
    @Published private(set) var upcoming: [Due] = []
    @Published private(set) var authorized = false
    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        guard Prefs.on(Prefs.showReminders) else { return }
        authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.load()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.load() }
        load()
    }

    func requestAccess() {
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                self.authorized = granted
                self.load()
                if !granted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    func load() {
        guard authorized, Prefs.on(Prefs.showReminders) else { if !upcoming.isEmpty { upcoming = [] }; return }
        let now = Date()
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: now.addingTimeInterval(-7 * 24 * 3600),
                                                         ending: now.addingTimeInterval(14 * 24 * 3600), calendars: nil)
        store.fetchReminders(matching: pred) { [weak self] rems in
            let list: [Due] = (rems ?? []).compactMap { r in
                guard let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps) else { return nil }
                return Due(id: r.calendarItemIdentifier, title: r.title ?? "Erinnerung", due: due,
                           list: r.calendar?.title, color: Color(nsColor: r.calendar?.color ?? .systemBlue),
                           flagged: r.priority > 0 && r.priority <= 4)
            }.sorted { $0.due < $1.due }
            let top = Array(list.prefix(5))
            DispatchQueue.main.async { if top != self?.upcoming { self?.upcoming = top } }
        }
    }

    static func relative(_ d: Date, now: Date = Date()) -> String {
        let s = d.timeIntervalSince(now)
        if s < 0 { return "überfällig" }
        let h = Int(s / 3600)
        if h < 1 { return "in \(max(1, Int(s / 60))) Min" }
        if h < 24 { return "in \(h) Std" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now),
                                                   to: Calendar.current.startOfDay(for: d)).day ?? 0
        return days == 1 ? "morgen" : "in \(days) Tagen"
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x4F7CFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
